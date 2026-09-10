import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient
@testable import ShellControlBroker

final class StreamAndEnrollmentTests: XCTestCase {
    // MARK: Change stream

    func testSnapshotThenChangesGivesTheCurrentState() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))

        let snapshot = try await harness.store.snapshot(principal: device.principal)
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.approvals.count, 1)

        var reconciler = InboxReconciler()
        var accumulator = InboxReconciler.SnapshotAccumulator(firstPage: snapshot)
        try reconciler.applyCompletedSnapshot(accumulator, at: snapshot.serverTime)

        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        _ = try await harness.decide(.reject, device: device, record: current)

        let page = try await harness.store.changes(principal: device.principal, cursor: snapshot.cursor)
        XCTAssertFalse(page.events.isEmpty)
        _ = reconciler.apply(page)
        XCTAssertEqual(reconciler.state.approvals[record.spec.requestID]?.projection.resolution, .rejected)
        _ = accumulator
    }

    func testSnapshotPaginatesAndSharesOneToken() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        for _ in 0..<3 {
            _ = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        }
        let first = try await harness.store.snapshot(principal: device.principal, limit: 2)
        XCTAssertEqual(first.approvals.count, 2)
        let nextToken = try XCTUnwrap(first.nextPageToken)
        let second = try await harness.store.snapshot(principal: device.principal, pageToken: nextToken)
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(second.snapshotToken, first.snapshotToken)
        XCTAssertEqual(second.cursor, first.cursor)
    }

    func testCursorFromAnotherPrincipalIsRefused() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let other = try await harness.enrollDevice()
        let snapshot = try await harness.store.snapshot(principal: device.principal)
        await assertControlError(.cursorExpired) {
            _ = try await harness.store.changes(principal: other.principal, cursor: snapshot.cursor)
        }
    }

    func testOriginSeesOnlyItsOwnEvents() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        _ = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let otherOriginID = try await harness.store.enrollOrigin(accountID: harness.accountID, label: "other", secret: "another-secret")
        let otherPrincipal = Principal.origin(originID: otherOriginID, accountID: harness.accountID)
        let snapshot = try await harness.store.snapshot(principal: otherPrincipal)
        XCTAssertTrue(snapshot.approvals.isEmpty)
    }

    // MARK: Notifications and push

    func testNotificationIsIdempotentByEventIDAndBodyHash() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let eventID = ControlID.random()
        let event = try InformationalEvent(
            eventID: eventID,
            originID: harness.originID,
            kind: .jobCompleted,
            title: "Build finished",
            body: "",
            occurredAt: harness.timestamp
        )
        _ = try await harness.store.createNotification(principal: harness.originPrincipal, event: event)
        _ = try await harness.store.createNotification(principal: harness.originPrincipal, event: event)
        let changed = try InformationalEvent(
            eventID: eventID,
            originID: harness.originID,
            kind: .jobFailed,
            title: "Build failed",
            body: "",
            occurredAt: harness.timestamp
        )
        await assertControlError(.idempotencyConflict) {
            _ = try await harness.store.createNotification(principal: harness.originPrincipal, event: changed)
        }
    }

    func testApprovalPushGoesToEveryInstalledDestination() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let watch = try await harness.enrollDevice()
        try await harness.store.registerPush(
            principal: watch.principal,
            registration: try PushRegistration(
                token: String(repeating: "ab", count: 32),
                platform: .watchOS,
                environment: .development,
                topic: "dev.chr33s.shell.watchkitapp"
            ),
            allowedTopics: ["dev.chr33s.shell.watchkitapp", "dev.chr33s.shell"]
        )
        let phoneKey = InMemoryDeviceKey()
        let phoneID = try await harness.store.enrollDevice(
            accountID: harness.accountID,
            publicJWK: phoneKey.publicJWK,
            platform: .iOS,
            label: "iPhone"
        )
        let phone = try await harness.store.authenticateDevice(phoneID)
        try await harness.store.registerPush(
            principal: phone,
            registration: try PushRegistration(
                token: String(repeating: "cd", count: 32),
                platform: .iOS,
                environment: .development,
                topic: "dev.chr33s.shell"
            ),
            allowedTopics: ["dev.chr33s.shell.watchkitapp", "dev.chr33s.shell"]
        )
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))

        let sender = RecordingPushSender()
        await OutboxWorker(store: harness.store, sender: sender).drainOnce()
        let delivered = await sender.delivered
        XCTAssertEqual(Set(delivered.map(\.headers.topic)), ["dev.chr33s.shell.watchkitapp", "dev.chr33s.shell"])
        for entry in delivered {
            XCTAssertEqual(entry.headers.collapseID, "approval.\(record.spec.requestID.rawValue)")
            XCTAssertLessThanOrEqual(entry.headers.expiration, Int64(record.spec.expiresAt.date.timeIntervalSince1970))
            XCTAssertLessThan(entry.payload.count, 4096)
        }
    }

    func testUnconfiguredTopicIsRejected() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        await assertControlError(.notAuthorized) {
            try await harness.store.registerPush(
                principal: device.principal,
                registration: try PushRegistration(
                    token: String(repeating: "ab", count: 32),
                    platform: .watchOS,
                    environment: .production,
                    topic: "com.example.other"
                ),
                allowedTopics: ["dev.chr33s.shell.watchkitapp"]
            )
        }
    }

    // MARK: Enrollment

    func testIndependentEnrollmentWithoutAPhone() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        let authorization = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "https://example.test/activate"
        )
        let deviceCode = try XCTUnwrap(authorization["device_code"]?.stringValue)
        let userCode = try XCTUnwrap(authorization["user_code"]?.stringValue)

        // Before confirmation, polling is pending.
        do {
            _ = try await harness.store.pollDeviceToken(deviceCode: deviceCode)
            XCTFail("expected authorization_pending")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .authorizationPending)
        }
        // Polling faster than the interval earns slow_down.
        do {
            _ = try await harness.store.pollDeviceToken(deviceCode: deviceCode)
            XCTFail("expected slow_down")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .slowDown)
        }

        // The confirmation page shows what is being granted.
        let described = try await harness.store.describeUserCode(userCode)
        XCTAssertEqual(described["label"]?.stringValue, "Watch")
        XCTAssertEqual(described["key_fingerprint"]?.stringValue, try key.publicJWK.displayFingerprint())

        // Ordinary decision credentials cannot confirm an enrollment.
        let stranger = Principal.device(deviceID: .random(), accountID: harness.accountID, grants: DeviceGrant.watchDefault)
        await assertControlError(.notAuthorized) {
            try await harness.store.approveDeviceAuthorization(userCode: userCode, principal: stranger)
        }
        try await harness.store.approveDeviceAuthorization(
            userCode: userCode,
            principal: .admin(accountID: harness.accountID)
        )

        harness.clock.advance(10)
        let token = try await harness.store.pollDeviceToken(deviceCode: deviceCode)
        let accessToken = try XCTUnwrap(token["access_token"]?.stringValue)

        let signature = try key.signature(for: try XCTUnwrap(Base64URL.decode(enrollment.challenge)))
        let session = try await harness.store.completeEnrollment(
            enrollmentID: enrollment.enrollmentID,
            enrollmentToken: accessToken,
            challengeSignature: Base64URL.encode(signature)
        )
        XCTAssertEqual(session.accountID, harness.accountID)
        XCTAssertTrue(session.grants.contains(.approvalsDecide))
        XCTAssertEqual(session.audience, "shell-control:\(harness.accountID.rawValue)")

        // One-use: a second completion is refused.
        await assertControlError(.invalidToken) {
            _ = try await harness.store.completeEnrollment(
                enrollmentID: enrollment.enrollmentID,
                enrollmentToken: accessToken,
                challengeSignature: Base64URL.encode(signature)
            )
        }

        // The issued session authenticates, and a rotated refresh spends itself.
        let principal = try await harness.store.authenticate(bearer: session.accessToken)
        XCTAssertEqual(principal.accountID, harness.accountID)
        let refreshed = try await harness.store.refreshSession(refreshToken: session.refreshToken)
        XCTAssertNotEqual(refreshed.refreshToken, session.refreshToken)
        await assertControlError(.invalidToken) {
            _ = try await harness.store.refreshSession(refreshToken: session.refreshToken)
        }
    }

    func testEnrollmentHonorsAdministratorGrantRestrictions() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        let authorization = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "https://example.test/activate"
        )
        try await harness.store.approveDeviceAuthorization(
            userCode: try XCTUnwrap(authorization["user_code"]?.stringValue),
            principal: .admin(accountID: harness.accountID),
            grants: [.notificationsRead]
        )
        let token = try await harness.store.pollDeviceToken(
            deviceCode: try XCTUnwrap(authorization["device_code"]?.stringValue)
        )
        let signature = try key.signature(for: try XCTUnwrap(Base64URL.decode(enrollment.challenge)))
        let session = try await harness.store.completeEnrollment(
            enrollmentID: enrollment.enrollmentID,
            enrollmentToken: try XCTUnwrap(token["access_token"]?.stringValue),
            challengeSignature: Base64URL.encode(signature)
        )
        XCTAssertEqual(session.grants, [.notificationsRead])
        XCTAssertFalse(session.grants.contains(.approvalsDecide))
    }

    func testDeviceAuthorizationIsUniquePerEnrollment() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        let scope = "control.enroll:\(enrollment.enrollmentID.rawValue)"
        let first = try await harness.store.startDeviceAuthorization(
            scope: scope,
            verificationURI: "https://example.test/activate"
        )
        let second = try await harness.store.startDeviceAuthorization(
            scope: scope,
            verificationURI: "https://example.test/activate"
        )
        XCTAssertEqual(first["device_code"]?.stringValue, second["device_code"]?.stringValue)
        XCTAssertEqual(first["user_code"]?.stringValue, second["user_code"]?.stringValue)
        let count = await harness.store.liveDeviceAuthorizationCount(for: enrollment.enrollmentID)
        XCTAssertEqual(count, 1)

        try await harness.store.approveDeviceAuthorization(
            userCode: try XCTUnwrap(first["user_code"]?.stringValue),
            principal: .admin(accountID: harness.accountID),
            grants: [.notificationsRead]
        )
        let token = try await harness.store.pollDeviceToken(
            deviceCode: try XCTUnwrap(first["device_code"]?.stringValue)
        )
        let signature = try key.signature(for: try XCTUnwrap(Base64URL.decode(enrollment.challenge)))
        let session = try await harness.store.completeEnrollment(
            enrollmentID: enrollment.enrollmentID,
            enrollmentToken: try XCTUnwrap(token["access_token"]?.stringValue),
            challengeSignature: Base64URL.encode(signature)
        )
        XCTAssertEqual(session.grants, [.notificationsRead])
    }

    func testDecoyDeviceAuthorizationCannotEscalateGrants() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        let authorization = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "https://example.test/activate"
        )
        let deviceCode = try XCTUnwrap(authorization["device_code"]?.stringValue)
        let userCode = try XCTUnwrap(authorization["user_code"]?.stringValue)

        // Insert a decoy that would win an unbound `values.first` lookup and
        // carry watchDefault, including approvals.decide.
        let decoy = DeviceAuthorizationRecord(
            deviceCode: "0-decoy-\(UUID().uuidString)",
            userCode: "DECO-Y000",
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            enrollmentID: enrollment.enrollmentID,
            expiresAt: enrollment.expiresAt,
            interval: 5
        )
        XCTAssertTrue(decoy.grants.contains(.approvalsDecide))
        await harness.store.insertDeviceAuthorization(decoy)

        try await harness.store.approveDeviceAuthorization(
            userCode: userCode,
            principal: .admin(accountID: harness.accountID),
            grants: [.notificationsRead]
        )
        let token = try await harness.store.pollDeviceToken(deviceCode: deviceCode)
        let signature = try key.signature(for: try XCTUnwrap(Base64URL.decode(enrollment.challenge)))
        let session = try await harness.store.completeEnrollment(
            enrollmentID: enrollment.enrollmentID,
            enrollmentToken: try XCTUnwrap(token["access_token"]?.stringValue),
            challengeSignature: Base64URL.encode(signature)
        )
        XCTAssertEqual(session.grants, [.notificationsRead])
        XCTAssertFalse(session.grants.contains(.approvalsDecide))
    }

    func testCompleteEnrollmentFailsClosedWithoutBoundAuthorization() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        let authorization = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "https://example.test/activate"
        )
        let deviceCode = try XCTUnwrap(authorization["device_code"]?.stringValue)
        try await harness.store.approveDeviceAuthorization(
            userCode: try XCTUnwrap(authorization["user_code"]?.stringValue),
            principal: .admin(accountID: harness.accountID)
        )
        let token = try await harness.store.pollDeviceToken(deviceCode: deviceCode)
        await harness.store.removeDeviceAuthorization(deviceCode)
        let signature = try key.signature(for: try XCTUnwrap(Base64URL.decode(enrollment.challenge)))
        await assertControlError(.notAuthorized) {
            _ = try await harness.store.completeEnrollment(
                enrollmentID: enrollment.enrollmentID,
                enrollmentToken: try XCTUnwrap(token["access_token"]?.stringValue),
                challengeSignature: Base64URL.encode(signature)
            )
        }
    }

    func testWrongChallengeSignatureIsRefused() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        let authorization = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "https://example.test/activate"
        )
        let deviceCode = try XCTUnwrap(authorization["device_code"]?.stringValue)
        try await harness.store.approveDeviceAuthorization(
            userCode: try XCTUnwrap(authorization["user_code"]?.stringValue),
            principal: .admin(accountID: harness.accountID)
        )
        let token = try await harness.store.pollDeviceToken(deviceCode: deviceCode)
        let other = InMemoryDeviceKey()
        let wrong = try other.signature(for: try XCTUnwrap(Base64URL.decode(enrollment.challenge)))
        await assertControlError(.notAuthorized) {
            _ = try await harness.store.completeEnrollment(
                enrollmentID: enrollment.enrollmentID,
                enrollmentToken: try XCTUnwrap(token["access_token"]?.stringValue),
                challengeSignature: Base64URL.encode(wrong)
            )
        }
    }

    // MARK: Durability

    func testRestoredDatabaseCannotReactivateOldAuthority() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-control-tests-\(UUID().uuidString)")
            .appendingPathComponent("broker.json")
        let persistence = try FileBrokerPersistence(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let harness = BrokerHarness(persistence: persistence)
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let outcome = try await harness.decide(.approve, device: device, record: current)
        let decisionID = try XCTUnwrap(outcome.result.decisionID)
        _ = try await harness.store.consumeApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            request: ConsumeRequest(consumeID: .random(), decisionID: decisionID, requestHash: record.requestHash, runID: runID)
        )

        // Restore into a fresh store: the claim and the decision come back.
        let clock = harness.clock
        let restored = BrokerStore(
            serviceIdentity: "test-broker",
            cursorSecret: Data(repeating: 7, count: 32),
            persistence: persistence,
            now: { clock.now }
        )
        try await restored.restore()
        let restoredPrincipal = try await restored.authenticateDevice(device.id)
        let restoredRecord = try await restored.approval(record.spec.requestID, principal: restoredPrincipal)
        XCTAssertEqual(restoredRecord.projection.resolution, .approved)
        XCTAssertEqual(restoredRecord.projection.dispatch, .claimed)
        // A second consume ID cannot obtain another grant after the restore.
        await assertControlError(.alreadyClaimed) {
            _ = try await restored.consumeApproval(
                principal: .origin(originID: harness.originID, accountID: harness.accountID),
                requestID: record.spec.requestID,
                request: ConsumeRequest(consumeID: .random(), decisionID: decisionID, requestHash: record.requestHash, runID: runID)
            )
        }
    }

    func testRestoredEnrollmentTokenKeepsAuthorizationBinding() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-control-tests-\(UUID().uuidString)")
            .appendingPathComponent("broker.json")
        let persistence = try FileBrokerPersistence(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let harness = BrokerHarness(persistence: persistence)
        try await harness.bootstrap()
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Watch")
        let authorization = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "https://example.test/activate"
        )
        try await harness.store.approveDeviceAuthorization(
            userCode: try XCTUnwrap(authorization["user_code"]?.stringValue),
            principal: .admin(accountID: harness.accountID),
            grants: [.notificationsRead]
        )
        let token = try await harness.store.pollDeviceToken(
            deviceCode: try XCTUnwrap(authorization["device_code"]?.stringValue)
        )

        let clock = harness.clock
        let restored = BrokerStore(
            serviceIdentity: "test-broker",
            cursorSecret: Data(repeating: 7, count: 32),
            persistence: persistence,
            now: { clock.now }
        )
        try await restored.restore()
        let signature = try key.signature(for: try XCTUnwrap(Base64URL.decode(enrollment.challenge)))
        let session = try await restored.completeEnrollment(
            enrollmentID: enrollment.enrollmentID,
            enrollmentToken: try XCTUnwrap(token["access_token"]?.stringValue),
            challengeSignature: Base64URL.encode(signature)
        )
        XCTAssertEqual(session.grants, [.notificationsRead])
        XCTAssertFalse(session.grants.contains(.approvalsDecide))
    }

    // MARK: Acknowledgement

    func testAcknowledgingIsNotApproving() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let event = try InformationalEvent(
            eventID: .random(),
            originID: harness.originID,
            kind: .attention,
            title: "Needs a look",
            body: "",
            occurredAt: harness.timestamp
        )
        _ = try await harness.store.createNotification(principal: harness.originPrincipal, event: event)
        let commandID = ControlID.random()
        let command = try NotificationAckCommand(
            envelope: try ControlCommandEnvelope(
                type: .notificationAck,
                commandID: commandID,
                deviceID: device.id,
                audience: "shell-control:\(harness.accountID.rawValue)",
                issuedAt: harness.timestamp,
                notAfter: harness.timestamp.adding(60)
            ),
            notificationID: event.eventID
        )
        let outcome = try await harness.store.submitCommand(
            principal: device.principal,
            signedCommand: try ControlJWS.sign(payload: command.json, deviceID: device.id, key: device.key),
            idempotencyKey: commandID
        )
        XCTAssertTrue(outcome.result.recorded)
        // No approval state came into existence from an acknowledgement.
        XCTAssertNil(outcome.result.decisionID)
        let snapshot = try await harness.store.snapshot(principal: device.principal)
        XCTAssertNotNil(snapshot.notifications.first?.acknowledgedAt)
    }
}
