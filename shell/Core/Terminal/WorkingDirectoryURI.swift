//
//  WorkingDirectoryURI.swift
//  shell
//
//  Decoding for the working directory a terminal reports over OSC 7.
//

import Foundation

/// Turns an OSC 7 working-directory value into a plain filesystem path.
///
/// OSC 7 carries `file://<host><percent-encoded-path>`. Ghostty hands the
/// sequence's payload through `GHOSTTY_ACTION_PWD` as it arrived, so a directory
/// with a space in it would otherwise remain percent-encoded.
///
/// A value that is not a `file://` URI is returned untouched. That case is not
/// an error: a bare path may legitimately contain spaces or a literal `%`, and
/// running one through a percent-decoder corrupts it.
nonisolated enum WorkingDirectoryURI {
    static func path(_ value: String) -> String {
        guard value.hasPrefix("file://") else { return value }
        guard let components = URLComponents(string: value), !components.path.isEmpty else {
            return value
        }
        return components.path
    }
}
