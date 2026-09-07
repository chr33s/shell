import Foundation

/// `GET /v1/capabilities`. Discovery is not itself authorization
/// (spec.watch.md section 8).
public struct ServiceCapabilities: Sendable, Hashable {
    public static let protocolName = "shell-control/1"

    public let protocolVersions: [String]
    public let commandTypes: [String]
    public let operationSchemas: [String]
    public let requiredFeatures: [String]
    public let limits: Limits
    public let serviceIdentity: String
    public let serverTime: ControlTimestamp

    public struct Limits: Sendable, Hashable {
        public var maxDocumentBytes: Int
        public var maxSnapshotItems: Int
        public var maxChangeEvents: Int
        public var challengeTTLSeconds: Int
        public var maxApprovalLifetimeSeconds: Int
        public var minPollIntervalSeconds: Int

        public init(
            maxDocumentBytes: Int = JSONLimits.maxDocumentBytes,
            maxSnapshotItems: Int = SnapshotPage.maximumItems,
            maxChangeEvents: Int = ChangePage.maximumEvents,
            challengeTTLSeconds: Int = Int(ApprovalPolicy.challengeLifetime),
            maxApprovalLifetimeSeconds: Int = Int(ApprovalPolicy.maximumLifetime),
            minPollIntervalSeconds: Int = Int(ApprovalPolicy.minimumPollInterval)
        ) {
            self.maxDocumentBytes = maxDocumentBytes
            self.maxSnapshotItems = maxSnapshotItems
            self.maxChangeEvents = maxChangeEvents
            self.challengeTTLSeconds = challengeTTLSeconds
            self.maxApprovalLifetimeSeconds = maxApprovalLifetimeSeconds
            self.minPollIntervalSeconds = minPollIntervalSeconds
        }

        public var json: JSONValue {
            .object([
                "max_document_bytes": .number(.int(Int64(maxDocumentBytes))),
                "max_snapshot_items": .number(.int(Int64(maxSnapshotItems))),
                "max_change_events": .number(.int(Int64(maxChangeEvents))),
                "challenge_ttl_seconds": .number(.int(Int64(challengeTTLSeconds))),
                "max_approval_lifetime_seconds": .number(.int(Int64(maxApprovalLifetimeSeconds))),
                "min_poll_interval_seconds": .number(.int(Int64(minPollIntervalSeconds))),
            ])
        }

        public init(json: JSONValue) throws {
            var reader = try JSONReader(json)
            maxDocumentBytes = Int(try reader.integer("max_document_bytes"))
            maxSnapshotItems = Int(try reader.integer("max_snapshot_items"))
            maxChangeEvents = Int(try reader.integer("max_change_events"))
            challengeTTLSeconds = Int(try reader.integer("challenge_ttl_seconds"))
            maxApprovalLifetimeSeconds = Int(try reader.integer("max_approval_lifetime_seconds"))
            minPollIntervalSeconds = Int(try reader.integer("min_poll_interval_seconds"))
            try reader.rejectUnknownMembers()
        }
    }

    public init(
        protocolVersions: [String] = [ServiceCapabilities.protocolName],
        commandTypes: [String] = ControlCommandType.allCases.map(\.rawValue).sorted(),
        operationSchemas: [String] = [ExecOperation.schema],
        requiredFeatures: [String] = ControlFeature.supported.sorted(),
        limits: Limits = Limits(),
        serviceIdentity: String,
        serverTime: ControlTimestamp
    ) {
        self.protocolVersions = protocolVersions
        self.commandTypes = commandTypes
        self.operationSchemas = operationSchemas
        self.requiredFeatures = requiredFeatures
        self.limits = limits
        self.serviceIdentity = serviceIdentity
        self.serverTime = serverTime
    }

    public var json: JSONValue {
        .object([
            "protocol_versions": JSONValue(strings: protocolVersions),
            "command_types": JSONValue(strings: commandTypes),
            "operation_schemas": JSONValue(strings: operationSchemas),
            "required_features": JSONValue(strings: requiredFeatures),
            "limits": limits.json,
            "service_identity": .string(serviceIdentity),
            "server_time": JSONValue(serverTime),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        protocolVersions = try reader.stringArray("protocol_versions", maxCount: 8, maxLength: 32)
        commandTypes = try reader.stringArray("command_types", maxCount: 32, maxLength: 48)
        operationSchemas = try reader.stringArray("operation_schemas", maxCount: 32, maxLength: 64)
        requiredFeatures = try reader.stringArray("required_features", maxCount: 32, maxLength: 64)
        limits = try Limits(json: try reader.value("limits"))
        serviceIdentity = try reader.string("service_identity", maxLength: 200)
        serverTime = try reader.timestamp("server_time")
        try reader.rejectUnknownMembers()
    }

    /// Whether this client can speak to the advertised service at all.
    public func isCompatible(supportedFeatures: Set<String> = ControlFeature.supported) -> Bool {
        protocolVersions.contains(ServiceCapabilities.protocolName)
    }
}
