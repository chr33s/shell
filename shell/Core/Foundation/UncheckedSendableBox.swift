//
//  UncheckedSendableBox.swift
//  shell
//
//  One-way transfer of a non-`Sendable` value across an isolation boundary.
//  Use only when the sender never touches the value again, or when both
//  sides run on the same thread (a main-queue observer hopping to the main
//  actor).
//

nonisolated struct UncheckedSendableBox<Value>: @unchecked Sendable {
    nonisolated(unsafe) let value: Value

    nonisolated init(_ value: Value) {
        self.value = value
    }
}
