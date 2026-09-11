import Foundation
import ShellControlProtocol

/// The authenticated browser surface a device sends the user to.
///
/// It displays the requested origin permissions, platform, device label, and
/// key fingerprint before anything is approved (spec.watch.md section 5). A
/// real deployment is expected to replace this with its own console and its own
/// session handling; what must not change is that confirming requires account
/// administration, and that the user sees what is being granted first.
enum ConfirmationPage {
    static func pair(brokerURL: String) -> String {
        let link = "shell-control://pair?broker=\(queryEscape(brokerURL))"
        return page(title: "Open Shell", body: """
        <p>This is a pairing page for the Shell control companion. It does not
        enrol anything by itself.</p>
        <p><a href="\(escape(link))">Open in Shell</a></p>
        <p class="hint">If the link does nothing, paste this broker URL in
        Settings → Control:</p>
        <p><code>\(escape(brokerURL))</code></p>
        """)
    }

    static func pairUnavailable() -> String {
        page(title: "Pairing is not configured", body: """
        <p>This broker has no public URL, so it will not tell a device where to
        connect. Set <code>SHELL_CONTROL_PUBLIC_URL</code> and restart.</p>
        """)
    }

    /// Percent-encode a query value. HTML-escaping is not URL encoding and would
    /// leave <code>://</code> intact inside <code>broker=</code>.
    static func queryEscape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func form(userCode: String, message: String?) -> String {
        page(title: "Confirm a device", body: """
        <p>Enter the administration secret for this service to see what
        <code>\(escape(userCode.isEmpty ? "this code" : userCode))</code> is asking for.</p>
        \(message.map { "<p class=\"error\">\(escape($0))</p>" } ?? "")
        <form method="get" action="/v1/oauth/confirm">
          <label>Code<input name="user_code" value="\(escape(userCode))" autocomplete="off"></label>
          <p class="hint">Sign in below, then submit to see the request.</p>
        </form>
        <form method="post" action="/v1/oauth/confirm">
          <input type="hidden" name="user_code" value="\(escape(userCode))">
          <label>Administration secret<input name="admin_secret" type="password" autocomplete="off"></label>
          <button type="submit" name="approve" value="true">Show and approve</button>
          <button type="submit" name="approve" value="false" class="secondary">Deny</button>
        </form>
        """)
    }

    static func details(_ described: JSONValue, userCode: String) -> String {
        let label = described["label"]?.stringValue ?? "unknown device"
        let platform = described["platform"]?.stringValue ?? "unknown platform"
        let fingerprint = described["key_fingerprint"]?.stringValue ?? ""
        let grants = described["requested_grants"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let expires = described["expires_at"]?.stringValue ?? ""
        return page(title: "Confirm \(label)", body: """
        <dl>
          <dt>Device</dt><dd>\(escape(label))</dd>
          <dt>Platform</dt><dd>\(escape(platform))</dd>
          <dt>Key fingerprint</dt><dd><code>\(escape(fingerprint))</code></dd>
          <dt>Code</dt><dd><code>\(escape(userCode))</code></dd>
          <dt>Expires</dt><dd>\(escape(expires))</dd>
        </dl>
        <p>Permissions requested:</p>
        <ul>\(grants.map { "<li><code>\(escape($0))</code></li>" }.joined())</ul>
        <p class="hint">Check the fingerprint against the one shown on the device
        before approving. Approving enrols a new device identity that can record
        decisions on your behalf; it does not grant a terminal, an SSH client, or
        the ability to run anything on its own.</p>
        <form method="post" action="/v1/oauth/confirm">
          <input type="hidden" name="user_code" value="\(escape(userCode))">
          <label>Administration secret<input name="admin_secret" type="password" autocomplete="off"></label>
          <button type="submit" name="approve" value="true">Approve this device</button>
          <button type="submit" name="approve" value="false" class="secondary">Deny</button>
        </form>
        """)
    }

    static func outcome(approved: Bool, userCode: String) -> String {
        page(
            title: approved ? "Device approved" : "Device denied",
            body: approved
                ? """
                <p>Code <code>\(escape(userCode))</code> was approved. The device will
                finish enrolling on its next poll.</p>
                <p class="hint">You can close this page.</p>
                """
                : """
                <p>Code <code>\(escape(userCode))</code> was denied. The device will stop
                polling and will not be enrolled.</p>
                """
        )
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title)) — Shell Control</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 16px/1.5 -apple-system, system-ui, sans-serif; margin: 0 auto; padding: 2rem 1rem; max-width: 34rem; }
          h1 { font-size: 1.25rem; }
          label { display: block; margin: 0.75rem 0; }
          input { display: block; width: 100%; padding: 0.5rem; font: inherit; margin-top: 0.25rem; }
          button { font: inherit; padding: 0.5rem 1rem; margin-right: 0.5rem; }
          button.secondary { opacity: 0.7; }
          dt { font-weight: 600; margin-top: 0.5rem; }
          dd { margin: 0 0 0.25rem; }
          code { font-family: ui-monospace, SFMono-Regular, monospace; }
          .hint { opacity: 0.75; font-size: 0.9rem; }
          .error { color: #b00; }
        </style>
        </head>
        <body>
        <h1>\(escape(title))</h1>
        \(body)
        </body>
        </html>
        """
    }

    /// Everything interpolated here is attacker-influenced (a device label is
    /// supplied by the enrolling client), so it is escaped, not trusted.
    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
