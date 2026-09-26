import ShellControlProtocol

/// The binding every adapter must check before writing a claimed answer to
/// its native provider. Keep it in one place so hook and managed routes cannot
/// accept different subsets of the same permit contract.
enum InputPermitBinding {
    static func validate(
        _ permit: InputConsumePermit,
        spec: InputSpec,
        requestID: ControlID,
        requestHash: String,
        runID: ControlID,
        nativeWaitID: ControlID,
        answerMappingSHA256: String,
        now: ControlTimestamp,
        ownerAlive: Bool
    ) throws {
        guard ownerAlive, permit.isApplicable(at: now),
              spec.requestID == requestID, spec.runID == runID,
              spec.source.nativeWaitID == nativeWaitID,
              ContentDigest.matches(try spec.requestHash(), requestHash),
              ContentDigest.matches(spec.source.answerMappingSHA256, answerMappingSHA256)
        else {
            throw AdapterRefusal("permit_invalid", "the committed input no longer matches this native wait")
        }
        let claim = InputConsumeRequest(
            mutationID: permit.mutationID, runID: runID, nativeWaitID: nativeWaitID,
            requestHash: requestHash, commandID: permit.commandID, responseHash: permit.response.responseHash
        )
        try permit.validate(request: claim, originID: spec.originID, requestID: requestID)
        try permit.response.validate(against: spec)
    }
}
