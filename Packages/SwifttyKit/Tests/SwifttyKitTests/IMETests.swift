import Foundation
@testable import SwifttyKit
import Testing

/// IME composition: marked text is shown as preedit at the cursor and never
/// sent; committing sends the composed text once.
@Suite(.serialized)
struct IMETests {
    @Test func preeditIsDisplayedNotSentAndCommitSendsOnce() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { swiftty_surface_free(s); swiftty_app_free(app) }
        swiftty_surface_set_size(s, 800, 400)
        write(swiftty_surface_get_slave_fd(s), "$ ")
        #expect(waitFor { screenText(s).first == "$" })

        // Composing (e.g. kana before conversion): shown, not sent.
        "にほ".withCString { swiftty_surface_preedit(s, $0, UInt(strlen($0))) }
        #expect(Surface.from(s)?.renderer.preedit == "にほ")
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        swiftty_surface_ime_point(s, &x, &y, &w, &h)
        #expect(x > 0 && y > 0 && h > 0)
        #expect(w > 0) // the candidate window spans the two wide preedit cells
        #expect(drain(swiftty_surface_response_read_fd(s), timeout: 0.3) == "")

        // Commit: preedit cleared, converted text sent exactly once.
        swiftty_surface_preedit(s, nil, 0)
        #expect(Surface.from(s)?.renderer.preedit == nil)
        "日本".withCString { swiftty_surface_text(s, $0, UInt(strlen($0))) }
        #expect(drain(swiftty_surface_response_read_fd(s)) == "日本")
    }
}
