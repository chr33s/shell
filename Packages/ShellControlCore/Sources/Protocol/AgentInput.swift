import Foundation

/// What answering an input actually does. v1 answers questions only; an
/// input that grants tool or permission authority is an approval, and an
/// unknown effect is not remotely answerable (docs/specs/agent-relay.md 6.1).
public enum InputEffect {
    public static let answerQuestion = "answer_question"
}

public enum InputAllowedResponse: String, Sendable, Hashable, CaseIterable {
    case answer
    /// Offered only when the adapter has a tested native decline mapping.
    case decline
}

/// One offered choice. The ID is stable and adapter-assigned; the label is
/// display text and is never used to match an answer (docs/specs/agent-relay.md 6.3).
public struct InputChoice: Sendable, Hashable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) throws {
        try AgentIdentifier.require(id, field: "choices.id")
        guard !label.isEmpty, label.utf8Count <= AgentPolicy.maximumLabelBytes else {
            throw ValidationError.invalid("choices.label", "must be 1...\(AgentPolicy.maximumLabelBytes) bytes")
        }
        if let description {
            guard description.utf8Count <= AgentPolicy.maximumDescriptionBytes else {
                throw ValidationError.invalid("choices.description", "exceeds \(AgentPolicy.maximumDescriptionBytes) bytes")
            }
        }
        self.id = id
        self.label = label
        self.description = description
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let id = try reader.string("id", maxLength: 64)
        let label = try reader.string("label", maxLength: AgentPolicy.maximumLabelBytes)
        let description = try reader.optionalString("description", maxLength: AgentPolicy.maximumDescriptionBytes)
        try reader.rejectUnknownMembers()
        try self.init(id: id, label: label, description: description)
    }

    public var json: JSONValue {
        JSONWriter.object([
            "id": .string(id),
            "label": .string(label),
            "description": description.map { .string($0) }
        ])
    }
}

/// One question. No arbitrary schema, validator, upload, URL action, secret
/// entry, or executable template exists in v1 (docs/specs/agent-relay.md 6.1).
public struct InputQuestion: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case singleChoice(choices: [InputChoice])
        case multiChoice(choices: [InputChoice], minimum: Int, maximum: Int)
        case text(maximumBytes: Int, hint: String?)

        public var rawValue: String {
            switch self {
            case .singleChoice: return "single_choice"
            case .multiChoice: return "multi_choice"
            case .text: return "text"
            }
        }

        public var choices: [InputChoice] {
            switch self {
            case .singleChoice(let choices), .multiChoice(let choices, _, _): return choices
            case .text: return []
            }
        }
    }

    public let id: String
    public let prompt: String
    public let kind: Kind
    public let required: Bool

    public init(id: String, prompt: String, kind: Kind, required: Bool) throws {
        try AgentIdentifier.require(id, field: "questions.id")
        guard !prompt.isEmpty, prompt.utf8Count <= AgentPolicy.maximumPromptBytes else {
            throw ValidationError.invalid("questions.prompt", "must be 1...\(AgentPolicy.maximumPromptBytes) bytes")
        }
        switch kind {
        case .singleChoice(let choices):
            try Self.validate(choices)
        case .multiChoice(let choices, let minimum, let maximum):
            try Self.validate(choices)
            guard minimum >= 0, maximum >= 1, minimum <= maximum, maximum <= choices.count else {
                throw ValidationError.invalid("questions.selections", "needs 0 <= min <= max <= choice count")
            }
        case .text(let maximumBytes, let hint):
            guard maximumBytes >= 1, maximumBytes <= AgentPolicy.maximumTextAnswerBytes else {
                throw ValidationError.invalid("questions.max_bytes", "must be 1...\(AgentPolicy.maximumTextAnswerBytes)")
            }
            guard hint?.utf8Count ?? 0 <= AgentPolicy.maximumDescriptionBytes else {
                throw ValidationError.invalid("questions.hint", "exceeds \(AgentPolicy.maximumDescriptionBytes) bytes")
            }
        }
        self.id = id
        self.prompt = prompt
        self.kind = kind
        self.required = required
    }

    private static func validate(_ choices: [InputChoice]) throws {
        guard !choices.isEmpty, choices.count <= AgentPolicy.maximumChoices else {
            throw ValidationError.invalid("questions.choices", "must hold 1...\(AgentPolicy.maximumChoices) choices")
        }
        guard Set(choices.map(\.id)).count == choices.count else {
            throw ValidationError.invalid("questions.choices", "choice IDs must be unique")
        }
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let id = try reader.string("id", maxLength: 64)
        let prompt = try reader.string("prompt", maxLength: AgentPolicy.maximumPromptBytes)
        let kindText = try reader.string("kind", maxLength: 32)
        let required = try reader.bool("required")
        let kind: Kind
        func choices() throws -> [InputChoice] {
            guard let items = try reader.value("choices").arrayValue else {
                throw ValidationError.invalid("questions.choices", "must be an array")
            }
            guard items.count <= AgentPolicy.maximumChoices else {
                throw ValidationError.invalid("questions.choices", "more than \(AgentPolicy.maximumChoices) choices")
            }
            return try items.map(InputChoice.init(json:))
        }
        switch kindText {
        case "single_choice":
            kind = .singleChoice(choices: try choices())
        case "multi_choice":
            let parsed = try choices()
            kind = .multiChoice(
                choices: parsed,
                minimum: Int(try reader.integer("min_selections")),
                maximum: Int(try reader.integer("max_selections"))
            )
        case "text":
            kind = .text(maximumBytes: Int(try reader.integer("max_bytes")), hint: try reader.optionalString("hint", maxLength: 1024))
        default:
            throw ValidationError.unsupported("question kind \(kindText)")
        }
        // An unknown constraint disables remote reply rather than being
        // ignored (docs/specs/agent-relay.md 6.1).
        try reader.rejectUnknownMembers()
        try self.init(id: id, prompt: prompt, kind: kind, required: required)
    }

    public var json: JSONValue {
        var members: [String: JSONValue?] = [
            "id": .string(id),
            "prompt": .string(prompt),
            "kind": .string(kind.rawValue),
            "required": .bool(required)
        ]
        switch kind {
        case .singleChoice(let choices):
            members["choices"] = .array(choices.map(\.json))
        case .multiChoice(let choices, let minimum, let maximum):
            members["choices"] = .array(choices.map(\.json))
            members["min_selections"] = .number(.int(Int64(minimum)))
            members["max_selections"] = .number(.int(Int64(maximum)))
        case .text(let maximumBytes, let hint):
            members["max_bytes"] = .number(.int(Int64(maximumBytes)))
            members["hint"] = hint.map { .string($0) }
        }
        return JSONWriter.object(members)
    }
}

/// Where the question came from, bound into the request hash: tested builds,
/// the native request and context digests, the exact answer mapping, and the
/// native wait (docs/specs/agent-relay.md 6.1).
public struct InputSource: Sendable, Hashable {
    public let provider: String
    public let providerBuild: String
    public let adapterBuild: String
    public let nativeRequestSHA256: String
    public let contextSHA256: String
    public let answerMappingSHA256: String
    public let agentSessionID: ControlID
    public let nativeWaitID: ControlID
    public let connectionEpoch: ControlID?
    public let providerSessionID: String?
    public let providerTurnID: String?
    public let providerRequestID: NativeIdentifier?

    public init(
        provider: String,
        providerBuild: String,
        adapterBuild: String,
        nativeRequestSHA256: String,
        contextSHA256: String,
        answerMappingSHA256: String,
        agentSessionID: ControlID,
        nativeWaitID: ControlID,
        connectionEpoch: ControlID? = nil,
        providerSessionID: String? = nil,
        providerTurnID: String? = nil,
        providerRequestID: NativeIdentifier? = nil
    ) throws {
        try AgentIdentifier.require(provider, field: "source.provider")
        for (field, text) in [("source.provider_build", providerBuild), ("source.adapter_build", adapterBuild)] {
            guard !text.isEmpty, text.utf8Count <= 64 else { throw ValidationError.invalid(field, "must be 1...64 bytes") }
        }
        for (field, hex) in [
            ("source.native_request_sha256", nativeRequestSHA256),
            ("source.context_sha256", contextSHA256),
            ("source.answer_mapping_sha256", answerMappingSHA256)
        ] {
            guard ASCIIHex.isSHA256(hex) else { throw ValidationError.invalid(field, "must be 64 lowercase hex characters") }
        }
        self.provider = provider
        self.providerBuild = providerBuild
        self.adapterBuild = adapterBuild
        self.nativeRequestSHA256 = nativeRequestSHA256
        self.contextSHA256 = contextSHA256
        self.answerMappingSHA256 = answerMappingSHA256
        self.agentSessionID = agentSessionID
        self.nativeWaitID = nativeWaitID
        self.connectionEpoch = connectionEpoch
        self.providerSessionID = providerSessionID
        self.providerTurnID = providerTurnID
        self.providerRequestID = providerRequestID
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let provider = try reader.string("provider", maxLength: 64)
        let providerBuild = try reader.string("provider_build", maxLength: 64)
        let adapterBuild = try reader.string("adapter_build", maxLength: 64)
        let native = try reader.sha256Hex("native_request_sha256")
        let context = try reader.sha256Hex("context_sha256")
        let mapping = try reader.sha256Hex("answer_mapping_sha256")
        let session = try reader.id("agent_session_id")
        let wait = try reader.id("native_wait_id")
        let epoch = try reader.optionalID("connection_epoch")
        let providerSession = try reader.optionalString("provider_session_id", maxLength: 256)
        let providerTurn = try reader.optionalString("provider_turn_id", maxLength: 256)
        let providerRequest = try reader.optionalNativeIdentifier("provider_request_id")
        try reader.rejectUnknownMembers()
        try self.init(
            provider: provider, providerBuild: providerBuild, adapterBuild: adapterBuild,
            nativeRequestSHA256: native, contextSHA256: context, answerMappingSHA256: mapping,
            agentSessionID: session, nativeWaitID: wait, connectionEpoch: epoch,
            providerSessionID: providerSession, providerTurnID: providerTurn, providerRequestID: providerRequest
        )
    }

    public var json: JSONValue {
        JSONWriter.object([
            "provider": .string(provider),
            "provider_build": .string(providerBuild),
            "adapter_build": .string(adapterBuild),
            "native_request_sha256": .string(nativeRequestSHA256),
            "context_sha256": .string(contextSHA256),
            "answer_mapping_sha256": .string(answerMappingSHA256),
            "agent_session_id": JSONValue(agentSessionID),
            "native_wait_id": JSONValue(nativeWaitID),
            "connection_epoch": connectionEpoch.map { JSONValue($0) },
            "provider_session_id": providerSessionID.map { .string($0) },
            "provider_turn_id": providerTurnID.map { .string($0) },
            "provider_request_id": providerRequestID?.json
        ])
    }
}

/// The immutable `input.request`, defined independently of
/// `approval.request`: no `reply` is ever added to the approve/reject enum
/// (docs/specs/agent-relay.md 6.1).
public struct InputSpec: Sendable, Hashable {
    public static let type = "input.request"

    public let version: Int
    public let requestID: ControlID
    public let originID: ControlID
    public let jobID: ControlID
    public let runID: ControlID
    public let createdAt: ControlTimestamp
    public let expiresAt: ControlTimestamp
    public let summary: String
    public let effect: String
    public let source: InputSource
    public let questions: [InputQuestion]
    public let allowedResponses: [InputAllowedResponse]
    public let minimumReview: MinimumReview
    public let requiredFeatures: [String]

    public init(
        version: Int = 1,
        requestID: ControlID,
        originID: ControlID,
        jobID: ControlID,
        runID: ControlID,
        createdAt: ControlTimestamp,
        expiresAt: ControlTimestamp,
        summary: String,
        effect: String = InputEffect.answerQuestion,
        source: InputSource,
        questions: [InputQuestion],
        allowedResponses: [InputAllowedResponse] = [.answer],
        minimumReview: MinimumReview,
        requiredFeatures: [String] = [AgentFeature.input, AgentFeature.inputConsume]
    ) throws {
        guard version == 1 else { throw ValidationError.unsupported("input spec version \(version)") }
        guard expiresAt > createdAt else { throw ValidationError.invalid("expires_at", "must be after created_at") }
        guard expiresAt.date.timeIntervalSince(createdAt.date) <= AgentPolicy.maximumLifetime else {
            throw ValidationError.invalid("expires_at", "exceeds the \(Int(AgentPolicy.maximumLifetime))s cap")
        }
        guard !summary.isEmpty, summary.unicodeScalars.count <= AgentPolicy.maximumSummaryScalars else {
            throw ValidationError.invalid("summary", "must be 1...\(AgentPolicy.maximumSummaryScalars) characters")
        }
        guard !effect.isEmpty, effect.utf8Count <= 64 else { throw ValidationError.invalid("effect", "must be 1...64 bytes") }
        guard !questions.isEmpty, questions.count <= AgentPolicy.maximumQuestions else {
            throw ValidationError.invalid("questions", "must hold 1...\(AgentPolicy.maximumQuestions) questions")
        }
        guard Set(questions.map(\.id)).count == questions.count else {
            throw ValidationError.invalid("questions", "question IDs must be unique")
        }
        guard allowedResponses.contains(.answer), Set(allowedResponses).count == allowedResponses.count else {
            throw ValidationError.invalid("allowed_responses", "must include answer once and repeat nothing")
        }
        guard Set(requiredFeatures).count == requiredFeatures.count else {
            throw ValidationError.invalid("required_features", "must not repeat a feature")
        }
        self.version = version
        self.requestID = requestID
        self.originID = originID
        self.jobID = jobID
        self.runID = runID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.summary = summary
        self.effect = effect
        self.source = source
        self.questions = questions
        self.allowedResponses = allowedResponses
        self.minimumReview = minimumReview
        self.requiredFeatures = requiredFeatures
        guard try JSONCanonicalization.canonicalize(json).count <= AgentPolicy.maximumInputSpecBytes else {
            throw ValidationError.invalid("input.request", "exceeds \(AgentPolicy.maximumInputSpecBytes) bytes")
        }
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let version = Int(try reader.integer("v"))
        guard try reader.string("type", maxLength: 64) == Self.type else {
            throw ValidationError.unsupported("input spec type")
        }
        let requestID = try reader.id("request_id")
        let originID = try reader.id("origin_id")
        let jobID = try reader.id("job_id")
        let runID = try reader.id("run_id")
        let createdAt = try reader.timestamp("created_at")
        let expiresAt = try reader.timestamp("expires_at")
        let summary = try reader.string("summary", maxLength: AgentPolicy.maximumSummaryScalars)
        let effect = try reader.string("effect", maxLength: 64)
        let source = try InputSource(json: try reader.value("source"))
        guard let rawQuestions = try reader.value("questions").arrayValue,
              rawQuestions.count <= AgentPolicy.maximumQuestions else {
            throw ValidationError.invalid("questions", "must be an array of at most \(AgentPolicy.maximumQuestions)")
        }
        let questions = try rawQuestions.map(InputQuestion.init(json:))
        let responses = try reader.stringArray("allowed_responses", maxCount: 4, maxLength: 16).map { text -> InputAllowedResponse in
            guard let response = InputAllowedResponse(rawValue: text) else { throw ValidationError.unsupported("response \(text)") }
            return response
        }
        let reviewText = try reader.string("minimum_review", maxLength: 16)
        guard let minimumReview = MinimumReview(rawValue: reviewText) else {
            throw ValidationError.unsupported("minimum_review \(reviewText)")
        }
        let requiredFeatures = try reader.stringArray("required_features", maxCount: 32, maxLength: 64)
        try reader.rejectUnknownMembers()
        try self.init(
            version: version, requestID: requestID, originID: originID, jobID: jobID, runID: runID,
            createdAt: createdAt, expiresAt: expiresAt, summary: summary, effect: effect, source: source,
            questions: questions, allowedResponses: responses, minimumReview: minimumReview,
            requiredFeatures: requiredFeatures
        )
    }

    public var json: JSONValue {
        .object([
            "v": .number(.int(Int64(version))),
            "type": .string(Self.type),
            "request_id": JSONValue(requestID),
            "origin_id": JSONValue(originID),
            "job_id": JSONValue(jobID),
            "run_id": JSONValue(runID),
            "created_at": JSONValue(createdAt),
            "expires_at": JSONValue(expiresAt),
            "summary": .string(summary),
            "effect": .string(effect),
            "source": source.json,
            "questions": .array(questions.map(\.json)),
            "allowed_responses": JSONValue(strings: allowedResponses.map(\.rawValue)),
            "minimum_review": .string(minimumReview.rawValue),
            "required_features": JSONValue(strings: requiredFeatures)
        ])
    }

    /// Over the complete canonical spec: source, labels, descriptions,
    /// constraints, and expiry (docs/specs/agent-relay.md 6.2).
    public func requestHash() throws -> String { try ContentDigest.digest(ofCanonical: json) }

    public func isExpired(at now: ControlTimestamp) -> Bool { now >= expiresAt }

    public var isAnswerableEffect: Bool { effect == InputEffect.answerQuestion }

    public func question(_ id: String) -> InputQuestion? { questions.first { $0.id == id } }

    /// The Watch question policy: at most two questions, four choices each,
    /// and short explicitly permitted text (docs/specs/agent-relay.md 12.2).
    public var permitsWatchReview: Bool {
        guard minimumReview == .watch, questions.count <= AgentPolicy.watchMaximumQuestions else { return false }
        return questions.allSatisfy { question in
            switch question.kind {
            case .singleChoice(let choices), .multiChoice(let choices, _, _):
                return choices.count <= AgentPolicy.watchMaximumChoices
            case .text(let maximumBytes, _):
                return maximumBytes <= AgentPolicy.watchMaximumTextBytes
            }
        }
    }
}

/// One typed answer. The signed command carries the answer itself, never
/// only its digest (docs/specs/agent-relay.md 6.3).
public enum InputAnswer: Sendable, Hashable {
    case singleChoice(questionID: String, choiceID: String)
    case multiChoice(questionID: String, choiceIDs: [String])
    case text(questionID: String, text: String)

    public var questionID: String {
        switch self {
        case .singleChoice(let id, _), .multiChoice(let id, _), .text(let id, _): return id
        }
    }

    public var kindName: String {
        switch self {
        case .singleChoice: return "single_choice"
        case .multiChoice: return "multi_choice"
        case .text: return "text"
        }
    }

    public var json: JSONValue {
        switch self {
        case .singleChoice(let id, let choice):
            return .object(["question_id": .string(id), "kind": "single_choice", "choice_id": .string(choice)])
        case .multiChoice(let id, let choices):
            return .object(["question_id": .string(id), "kind": "multi_choice", "choice_ids": JSONValue(strings: choices)])
        case .text(let id, let text):
            return .object(["question_id": .string(id), "kind": "text", "text": .string(text)])
        }
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let id = try reader.string("question_id", maxLength: 64)
        try AgentIdentifier.require(id, field: "answers.question_id")
        let kind = try reader.string("kind", maxLength: 32)
        switch kind {
        case "single_choice":
            self = .singleChoice(questionID: id, choiceID: try reader.string("choice_id", maxLength: 64))
        case "multi_choice":
            self = .multiChoice(questionID: id, choiceIDs: try reader.stringArray("choice_ids", maxCount: AgentPolicy.maximumChoices, maxLength: 64))
        case "text":
            self = .text(questionID: id, text: try reader.string("text", maxLength: AgentPolicy.maximumTextAnswerBytes))
        default:
            throw ValidationError.unsupported("answer kind \(kind)")
        }
        try reader.rejectUnknownMembers()
    }
}

/// `answer` with typed answers, or `decline` with none.
public enum InputResponse: Sendable, Hashable {
    case answer([InputAnswer])
    case decline

    public var action: InputAllowedResponse {
        switch self {
        case .answer: return .answer
        case .decline: return .decline
        }
    }

    public var answers: [InputAnswer] {
        if case .answer(let answers) = self { return answers }
        return []
    }

    /// The single deterministic representation: answers sorted by question
    /// ID (docs/specs/agent-relay.md 7.1).
    public var json: JSONValue {
        switch self {
        case .answer(let answers):
            return .object([
                "action": "answer",
                "answers": .array(answers.sorted { $0.questionID < $1.questionID }.map(\.json))
            ])
        case .decline:
            return .object(["action": "decline"])
        }
    }

    public var responseHash: String {
        // A response built from validated values always canonicalizes.
        (try? ContentDigest.digest(ofCanonical: json)) ?? ContentDigest.digest(of: Data())
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let action = try reader.string("action", maxLength: 16)
        switch action {
        case "answer":
            guard let items = try reader.value("answers").arrayValue, items.count <= AgentPolicy.maximumQuestions else {
                throw ValidationError.invalid("answers", "must be an array of at most \(AgentPolicy.maximumQuestions)")
            }
            self = .answer(try items.map(InputAnswer.init(json:)))
        case "decline":
            self = .decline
        default:
            throw ValidationError.unsupported("response action \(action)")
        }
        try reader.rejectUnknownMembers()
    }

    /// Validates the response against the committed spec. Missing required
    /// answers, duplicates, unknown IDs, extra questions, bad cardinality,
    /// non-canonical order, and over-limit text are all rejected before any
    /// claim or dispatch (docs/specs/agent-relay.md 6.3; A21).
    public func validate(against spec: InputSpec) throws {
        guard spec.allowedResponses.contains(action) else {
            throw AgentResponseError.invalid("\(action.rawValue) is not allowed for this request")
        }
        guard case .answer(let answers) = self else { return }
        let ids = answers.map(\.questionID)
        guard Set(ids).count == ids.count else { throw AgentResponseError.invalid("duplicate question id") }
        guard ids == ids.sorted() else { throw AgentResponseError.invalid("answers must be sorted by question id") }
        for question in spec.questions where question.required {
            guard ids.contains(question.id) else { throw AgentResponseError.invalid("missing required answer \(question.id)") }
        }
        for answer in answers {
            guard let question = spec.question(answer.questionID) else {
                throw AgentResponseError.invalid("unknown question \(answer.questionID)")
            }
            switch (question.kind, answer) {
            case (.singleChoice(let choices), .singleChoice(_, let choice)):
                guard choices.contains(where: { $0.id == choice }) else { throw AgentResponseError.invalid("unknown choice \(choice)") }
            case (.multiChoice(let choices, let minimum, let maximum), .multiChoice(_, let selected)):
                guard Set(selected).count == selected.count else { throw AgentResponseError.invalid("duplicate choice") }
                guard selected.count >= minimum, selected.count <= maximum else {
                    throw AgentResponseError.invalid("\(selected.count) selections outside \(minimum)...\(maximum)")
                }
                // Canonical order is the committed choice order.
                let order = choices.map(\.id)
                let positions = try selected.map { id -> Int in
                    guard let index = order.firstIndex(of: id) else { throw AgentResponseError.invalid("unknown choice \(id)") }
                    return index
                }
                guard positions == positions.sorted() else {
                    throw AgentResponseError.invalid("choices must be in the committed order")
                }
            case (.text(let maximumBytes, _), .text(_, let text)):
                guard text.utf8Count <= maximumBytes else { throw AgentResponseError.invalid("text exceeds \(maximumBytes) bytes") }
                guard !text.unicodeScalars.contains(where: { (0xD800...0xDFFF).contains($0.value) }) else {
                    throw AgentResponseError.invalid("text is not valid Unicode")
                }
            default:
                throw AgentResponseError.invalid("answer kind does not match question \(question.id)")
            }
        }
        guard try JSONCanonicalization.canonicalize(json).count <= AgentPolicy.maximumAnswerBytes else {
            throw AgentResponseError.invalid("answers exceed \(AgentPolicy.maximumAnswerBytes) bytes")
        }
    }
}

public enum AgentResponseError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let reason): return "response_invalid: \(reason)"
        }
    }
}

/// The adapter's committed mapping from Shell question/choice IDs to the
/// provider's native answer fields and values. The host keeps it locally,
/// commits its digest in the spec, and rechecks it before dispatch
/// (docs/specs/agent-relay.md 6.1).
public struct InputAnswerMapping: Sendable, Hashable {
    public struct Question: Sendable, Hashable {
        /// The native key the answer is written under (for Claude Code, the
        /// exact question text).
        public let nativeKey: String
        /// Shell choice ID to the exact native value.
        public let choices: [String: String]

        public init(nativeKey: String, choices: [String: String]) {
            self.nativeKey = nativeKey
            self.choices = choices
        }
    }

    public let questions: [String: Question]

    public init(questions: [String: Question]) { self.questions = questions }

    public var json: JSONValue {
        .object(questions.mapValues { question in
            .object([
                "native_key": .string(question.nativeKey),
                "choices": .object(question.choices.mapValues { .string($0) })
            ])
        })
    }

    public init(json: JSONValue) throws {
        guard let members = json.objectValue else { throw ValidationError.invalid("answer_mapping", "must be an object") }
        var questions: [String: Question] = [:]
        for (id, value) in members {
            var reader = try JSONReader(value)
            let key = try reader.string("native_key", maxLength: AgentPolicy.maximumPromptBytes)
            guard let rawChoices = try reader.value("choices").objectValue else {
                throw ValidationError.invalid("answer_mapping.choices", "must be an object")
            }
            var choices: [String: String] = [:]
            for (choiceID, native) in rawChoices {
                guard let text = native.stringValue else { throw ValidationError.invalid("answer_mapping.choices", "must be strings") }
                choices[choiceID] = text
            }
            try reader.rejectUnknownMembers()
            questions[id] = Question(nativeKey: key, choices: choices)
        }
        self.questions = questions
    }

    public var sha256Hex: String {
        ContentDigest.sha256Hex((try? JSONCanonicalization.canonicalize(json)) ?? Data())
    }
}
