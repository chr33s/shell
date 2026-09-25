import Foundation
import ShellControlProtocol

/// Claude Code `AskUserQuestion` through `PreToolUse`: the questions are
/// preserved exactly, Shell assigns stable IDs, and typed answers map back to
/// the provider's question-text keys and option labels through a committed
/// mapping — never by a lossy or truncated display label
/// (spec.agent-relay.md sections 7 and 10.3).
public struct QuestionMapping: Sendable, Hashable {
    public let questions: [InputQuestion]
    public let mapping: InputAnswerMapping
    /// The original `questions` array, echoed back verbatim.
    public let nativeQuestions: JSONValue

    public static func make(from input: NativeHookInput) throws -> QuestionMapping {
        guard input.provider == .claudeCode, input.event == .preToolUse, input.toolName == "AskUserQuestion",
              let members = input.toolInput.objectValue else {
            throw AdapterRefusal("unsupported_operation", "not an AskUserQuestion call")
        }
        let unknown = Set(members.keys).subtracting(["questions"])
        guard unknown.isEmpty else {
            throw AdapterRefusal("unsupported_input_schema", "unrecognized AskUserQuestion fields \(unknown.sorted().joined(separator: ", "))")
        }
        guard let nativeQuestions = members["questions"], let items = nativeQuestions.arrayValue,
              !items.isEmpty, items.count <= AgentPolicy.maximumQuestions else {
            throw AdapterRefusal("unsupported_input_schema", "questions must be a nonempty array")
        }
        var questions: [InputQuestion] = []
        var mapping: [String: InputAnswerMapping.Question] = [:]
        var seenText: Set<String> = []
        for (index, item) in items.enumerated() {
            guard let question = item.objectValue else { throw AdapterRefusal("unsupported_input_schema", "question \(index) is not an object") }
            // Any constraint this build does not understand (option previews,
            // free-text settings) disables the route rather than being dropped.
            let extra = Set(question.keys).subtracting(["question", "header", "options", "multiSelect"])
            guard extra.isEmpty else {
                throw AdapterRefusal("unsupported_input_schema", "unrecognized question fields \(extra.sorted().joined(separator: ", "))")
            }
            guard let text = question["question"]?.stringValue, !text.isEmpty else {
                throw AdapterRefusal("unsupported_input_schema", "question \(index) has no text")
            }
            // Answers are keyed by question text: duplicates are ambiguous.
            guard seenText.insert(text).inserted else {
                throw AdapterRefusal("unsupported_input_schema", "duplicate question text cannot be answered unambiguously")
            }
            let multiSelect = question["multiSelect"].flatMap { $0.isNull ? false : $0.boolValue } ?? false
            guard let options = question["options"]?.arrayValue, !options.isEmpty, options.count <= AgentPolicy.maximumChoices else {
                throw AdapterRefusal("unsupported_input_schema", "question \(index) needs options")
            }
            var choices: [InputChoice] = []
            var nativeChoices: [String: String] = [:]
            var seenLabels: Set<String> = []
            for (optionIndex, option) in options.enumerated() {
                guard let fields = option.objectValue else { throw AdapterRefusal("unsupported_input_schema", "option is not an object") }
                let optionExtra = Set(fields.keys).subtracting(["label", "description"])
                guard optionExtra.isEmpty else {
                    throw AdapterRefusal("unsupported_input_schema", "unrecognized option fields \(optionExtra.sorted().joined(separator: ", "))")
                }
                guard let label = fields["label"]?.stringValue, !label.isEmpty, seenLabels.insert(label).inserted else {
                    throw AdapterRefusal("unsupported_input_schema", "option labels must be nonempty and distinct")
                }
                // Multi-select answers are joined with ", "; a label that
                // contains it could not be told apart.
                if multiSelect, label.contains(", ") {
                    throw AdapterRefusal("unsupported_input_schema", "a multi-select label contains \", \"")
                }
                let description = fields["description"]?.stringValue
                let id = "c\(optionIndex + 1)"
                do {
                    choices.append(try InputChoice(id: id, label: label, description: description?.isEmpty == true ? nil : description))
                } catch {
                    throw AdapterRefusal("limit_exceeded", "\(error)")
                }
                nativeChoices[id] = label
            }
            let id = "q\(index + 1)"
            let kind: InputQuestion.Kind = multiSelect
                ? .multiChoice(choices: choices, minimum: 1, maximum: choices.count)
                : .singleChoice(choices: choices)
            do {
                questions.append(try InputQuestion(id: id, prompt: text, kind: kind, required: true))
            } catch {
                throw AdapterRefusal("limit_exceeded", "\(error)")
            }
            mapping[id] = InputAnswerMapping.Question(nativeKey: text, choices: nativeChoices)
        }
        return QuestionMapping(questions: questions, mapping: InputAnswerMapping(questions: mapping), nativeQuestions: nativeQuestions)
    }

    /// Builds the native `updatedInput` from the preserved questions and the
    /// signed answers, after rechecking the committed mapping digest.
    public func updatedInput(for response: InputResponse, committedMappingSHA256: String) throws -> JSONValue {
        guard mapping.sha256Hex == committedMappingSHA256 else {
            throw AdapterRefusal("native_context_changed", "the answer mapping changed")
        }
        guard case .answer(let answers) = response else {
            throw AdapterRefusal("response_invalid", "no tested native decline mapping")
        }
        var native: [String: JSONValue] = [:]
        for answer in answers {
            guard let question = mapping.questions[answer.questionID] else {
                throw AdapterRefusal("response_invalid", "unknown question \(answer.questionID)")
            }
            switch answer {
            case .singleChoice(_, let choiceID):
                guard let label = question.choices[choiceID] else { throw AdapterRefusal("response_invalid", "unknown choice") }
                native[question.nativeKey] = .string(label)
            case .multiChoice(_, let choiceIDs):
                // Labels joined with ", ": the one form every documented
                // variant of the answers record accepts (a string record;
                // arrays are documented for the SDK only). A label containing
                // ", " would make that ambiguous, so such questions never
                // reach this point (see make(from:)).
                let labels = try choiceIDs.map { id -> String in
                    guard let label = question.choices[id] else { throw AdapterRefusal("response_invalid", "unknown choice") }
                    return label
                }
                native[question.nativeKey] = .string(labels.joined(separator: ", "))
            case .text:
                throw AdapterRefusal("response_invalid", "free-text answers are not offered")
            }
        }
        return .object(["questions": nativeQuestions, "answers": .object(native)])
    }
}
