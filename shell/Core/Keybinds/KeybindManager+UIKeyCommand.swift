//
//  KeybindManager+UIKeyCommand.swift
//  shell
//
//  Build UIKeyCommands from the user's live bindings so auxiliary responders
//  (the empty-state screen) honor KeybindManager remaps instead of hardcoding
//  the default chord.
//

import UIKit

extension KeybindManager {
    /// A `UIKeyCommand` for the user's current binding of `action`, or nil if it's
    /// unbound or a multi-key sequence (which can't map to a single UIKeyCommand).
    func keyCommand(
        for action: KeybindAction,
        selector: Selector,
        title: String? = nil,
        wantsPriority: Bool = false
    ) -> UIKeyCommand? {
        guard let sequence = keybind(for: action)?.sequence,
              !sequence.isSequence,
              let trigger = sequence.first else { return nil }

        let command: UIKeyCommand
        if let title {
            command = UIKeyCommand(title: title, action: selector,
                                   input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags)
        } else {
            command = UIKeyCommand(input: trigger.uiKeyInput, modifierFlags: trigger.uiModifierFlags,
                                   action: selector)
        }
        command.wantsPriorityOverSystemBehavior = wantsPriority
        return command
    }
}
