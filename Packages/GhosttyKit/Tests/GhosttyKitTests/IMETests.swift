import Foundation
@testable import GhosttyKit
import Testing

/// IME composition: marked text is shown as preedit at the cursor and never
/// sent; committing sends the composed text once.
@Suite(.serialized)
struct IMETests {
    @Test func preeditIsDisplayedNotSentAndCommitSendsOnce() {
        let app = makeApp()
        let s = makeSurface(app)
        defer { ghostty_surface_free(s); ghostty_app_free(app) }
        ghostty_surface_set_size(s, 800, 400)
        write(ghostty_surface_get_slave_fd(s), "$ ")
        #expect(waitFor { screenText(s).first == "$" })

        // Composing (e.g. kana before conversion): shown, not sent.
        "にほ".withCString { ghostty_surface_preedit(s, $0, UInt(strlen($0))) }
        #expect(Surface.from(s)?.renderer.preedit == "にほ")
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(s, &x, &y, &w, &h)
        #expect(x > 0 && y > 0 && h > 0)
        #expect(w > 0) // the candidate window spans the two wide preedit cells
        #expect(drain(ghostty_surface_response_read_fd(s), timeout: 0.3) == "")

        // Commit: preedit cleared, converted text sent exactly once.
        ghostty_surface_preedit(s, nil, 0)
        #expect(Surface.from(s)?.renderer.preedit == nil)
        "日本".withCString { ghostty_surface_text(s, $0, UInt(strlen($0))) }
        #expect(drain(ghostty_surface_response_read_fd(s)) == "日本")
    }
}
