import Carbon
import Foundation

extension ShellMacSupport {
    func inputSources() -> [[String: String]] {
        sourceList().compactMap { source in
            guard selectable(source),
                  property(source, kTISPropertyInputSourceCategory) as? String == kTISCategoryKeyboardInputSource as String,
                  let id = property(source, kTISPropertyInputSourceID) as? String else { return nil }
            return ["id": id, "name": property(source, kTISPropertyLocalizedName) as? String ?? id]
        }
    }
    func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(source, kTISPropertyInputSourceID) as? String
    }
    func currentInputSourceLanguages() -> [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return [] }
        return property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
    }
    func selectInputSource(_ id: String) -> Bool {
        guard let source = sourceList().first(where: {
            selectable($0) && property($0, kTISPropertyInputSourceID) as? String == id
        }) else { return false }
        return TISSelectInputSource(source) == noErr
    }
    func translateKey(_ code: UInt16, shift: Bool, command: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = property(source, kTISPropertyUnicodeKeyLayoutData) as? Data else { return nil }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var deadKey: UInt32 = 0
            var length = 0
            var output = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), code,
                // Carbon has Command at bit 8 and Shift at bit 9; UCKeyTranslate
                // expects the event modifier bits shifted right by 8.
                UInt16(kUCKeyActionDown), (command ? 1 : 0) | (shift ? 2 : 0), UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, output.count, &length, &output)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: output, count: length)
        }
    }
    /// Carbon returns NULL rather than an empty list when Text Input Services is
    /// unavailable, so every entry point has to tolerate the absent list.
    private func sourceList() -> [TISInputSource] {
        (TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }
    private func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
    private func selectable(_ source: TISInputSource) -> Bool {
        (property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true) &&
        (property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true)
    }
}
