import Foundation

/// The answer a reviewer is composing for one input, shared by every client
/// so the signed response is built one way only: answers sorted by question
/// ID, multi-choice IDs in the committed choice order, never tap order, and
/// validated against the spec before return (docs/specs/agent-relay.md 7.1).
public struct InputAnswerDraft: Sendable, Hashable {
    /// Selected choice IDs per question, in the order they were tapped.
    public private(set) var selections: [String: [String]] = [:]
    public private(set) var texts: [String: String] = [:]

    public enum DraftError: Error, Equatable, Sendable {
        case missingRequired([String])
        case invalid(String)
    }

    public init() {}

    public func isSelected(_ choiceID: String, in question: InputQuestion) -> Bool {
        selections[question.id]?.contains(choiceID) ?? false
    }

    /// Single choice replaces; multi choice toggles and refuses to go past
    /// the committed maximum rather than silently dropping a selection.
    public mutating func select(_ choiceID: String, in question: InputQuestion) {
        guard question.kind.choices.contains(where: { $0.id == choiceID }) else { return }
        switch question.kind {
        case .singleChoice:
            selections[question.id] = [choiceID]
        case .multiChoice(_, _, let maximum):
            var current = selections[question.id] ?? []
            if let index = current.firstIndex(of: choiceID) {
                current.remove(at: index)
            } else if current.count < maximum {
                current.append(choiceID)
            }
            selections[question.id] = current.isEmpty ? nil : current
        case .text:
            break
        }
    }

    public mutating func setText(_ text: String, for question: InputQuestion) {
        guard case .text = question.kind else { return }
        texts[question.id] = text
    }

    public func text(for question: InputQuestion) -> String { texts[question.id] ?? "" }

    /// Exact UTF-8 bytes, the unit the committed limit is expressed in.
    public func byteCount(for question: InputQuestion) -> Int { text(for: question).utf8.count }

    public func selectionCount(for question: InputQuestion) -> Int { selections[question.id]?.count ?? 0 }

    /// Whether the question has an answer the user actually gave. An empty
    /// text is not an answer; a multi-choice question needs at least one
    /// selection and its committed minimum.
    public func isAnswered(_ question: InputQuestion) -> Bool {
        switch question.kind {
        case .singleChoice: return selectionCount(for: question) == 1
        case .multiChoice(_, let minimum, _):
            let count = selectionCount(for: question)
            return count > 0 && count >= minimum
        case .text: return !text(for: question).isEmpty
        }
    }

    public func missingRequired(in spec: InputSpec) -> [InputQuestion] {
        spec.questions.filter { $0.required && !isAnswered($0) }
    }

    public func response(for spec: InputSpec) throws -> InputResponse {
        let missing = missingRequired(in: spec)
        guard missing.isEmpty else { throw DraftError.missingRequired(missing.map(\.id)) }
        var answers: [InputAnswer] = []
        for question in spec.questions where isAnswered(question) {
            switch question.kind {
            case .singleChoice:
                if let choice = selections[question.id]?.first {
                    answers.append(.singleChoice(questionID: question.id, choiceID: choice))
                }
            case .multiChoice(let choices, _, _):
                let selected = Set(selections[question.id] ?? [])
                answers.append(.multiChoice(questionID: question.id, choiceIDs: choices.map(\.id).filter(selected.contains)))
            case .text:
                answers.append(.text(questionID: question.id, text: text(for: question)))
            }
        }
        let response = InputResponse.answer(answers.sorted { $0.questionID < $1.questionID })
        do {
            try response.validate(against: spec)
        } catch {
            throw DraftError.invalid(String(describing: error))
        }
        return response
    }
}
