import Foundation

/// A page Petal AI made, as it may leave Petal (pure: `macos/checks/run.sh` checks it). Inside Petal a page is only
/// ever shown (`PageWindow`: scripts off, nothing fetched); Open in Browser hands the person's browser a copy made
/// safe the same way, never the stored file: its scripts, event handlers, `javascript:` addresses and refreshes
/// taken out, and a strict Content Security Policy first in it, so nothing runs and nothing it names is fetched.
enum PageCopy {
    /// Text made safe inside HTML, in an element or in a quoted attribute: `&`, `<`, `>`, `"` and `'`.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The policy the browser's copy carries: no script, no frame, no form, no fetch; only its own inline styles and
    /// pictures written into it (data: addresses).
    static let policy = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; connect-src 'none'; "
        + "form-action 'none'; base-uri 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:"

    /// `html` as the browser is given it.
    static func forBrowser(_ html: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            // A script, whole, and any opening tag of one left over (never closed).
            ("(?is)<script\\b.*?</script\\s*>", ""),
            ("(?is)<script\\b[^>]*>", ""),
            // Elements that run or fetch something by themselves, whatever the policy says.
            ("(?is)<(iframe|frame|frameset|object|embed|applet|base|portal)\\b[^>]*>", ""),
            ("(?is)</(iframe|frame|frameset|object|embed|applet|portal)\\s*>", ""),
            // A refresh, or a policy of the page's own (its own could be looser: only Petal's stands).
            ("(?is)<meta\\b[^>]*http-equiv\\s*=\\s*[\"']?\\s*(refresh|content-security-policy)[^>]*>", ""),
            // Event handlers (onload=, onclick=…), quoted or not.
            ("(?is)(<[^>]*?)[\\s/]on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", "$1"),
            // javascript: (and vbscript:) addresses in any attribute that takes one.
            ("(?is)\\b(href|src|action|formaction|xlink:href|data)\\s*=\\s*([\"']?)\\s*(javascript|vbscript)\\s*:", "$1=$2#blocked:"),
        ]
        for (pattern, template) in rules {
            // Handlers are taken out one per tag per pass: again until there's none left.
            for _ in 0..<64 {
                let next = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
                if next == s { break }
                s = next
            }
        }
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        // First in the document (after its doctype, so it isn't read in quirks mode): before anything it could load.
        if let doctype = s.range(of: "(?is)^\\s*<!doctype[^>]*>", options: .regularExpression) {
            s.insert(contentsOf: meta, at: doctype.upperBound)
        } else {
            s = meta + s
        }
        return s
    }
}
