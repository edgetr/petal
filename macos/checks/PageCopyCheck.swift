import Foundation

// Checks PageCopy.swift: text escaped for HTML (both quotes too, so a link's address can't end its attribute), and
// the copy of a page Open in Browser hands the browser: no script, no event handler, no javascript: address, no
// refresh, and Petal's strict Content Security Policy first in it (after its doctype). Run with macos/checks/run.sh.
@main
struct PageCopyCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        print((ok ? "ok    " : "FAIL  ") + what + (ok ? "" : " " + detail()))
        if !ok { failures += 1 }
    }

    static func main() {
        let link = PageCopy.escape("https://a.example/\" onmouseover=\"alert(1)")
        expect(!link.contains("\"") && link.contains("&quot;") && PageCopy.escape("it's <b>&</b>") == "it&#39;s &lt;b&gt;&amp;&lt;/b&gt;",
               "both quotes, <, > and & are escaped", link)

        let page = """
        <!doctype html><html><head><meta http-equiv="refresh" content="0; url=https://evil.example">
        <meta http-equiv="Content-Security-Policy" content="default-src *">
        <script>alert(1)</script><SCRIPT src="https://evil.example/x.js"></SCRIPT><script>never closed
        </head><body onload="alert(2)"><img src=x onerror=alert(3)><svg/onload=alert(4)>
        <a href="javascript:alert(5)">x</a><a href=' JavaScript:alert(6)'>y</a><iframe src="https://evil.example"></iframe>
        <p>onions are fine</p></body></html>
        """
        let copy = PageCopy.forBrowser(page)
        let lower = copy.lowercased()
        expect(!lower.contains("<script") && !lower.contains("alert(1)"), "scripts are taken out", copy)
        expect(!lower.contains("onload") && !lower.contains("onerror"), "event handlers are taken out", copy)
        expect(!lower.contains("javascript:"), "javascript: addresses are taken out", copy)
        expect(!lower.contains("refresh") && !lower.contains("default-src *") && !lower.contains("<iframe"), "a refresh, the page's own policy and frames go", copy)
        expect(copy.hasPrefix("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'"),
               "Petal's policy comes first, after the doctype", String(copy.prefix(120)))
        expect(PageCopy.forBrowser("<p>hi</p>").hasPrefix("<meta http-equiv=\"Content-Security-Policy\""), "a body without a doctype gets it first too")
        expect(copy.contains("<p>onions are fine</p>"), "the words stay")
        print("page copy: " + (failures == 0 ? "all passed" : "\(failures) failed"))
        if failures > 0 { exit(1) }
    }
}
