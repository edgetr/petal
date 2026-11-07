import Foundation

// Checks the vault's pure side (Vault.swift): sites and registrable names, when Petal fills by itself (logins, API
// keys, the one Buy card for payment info, contact info and addresses), picking from a menu, the importers (Apple
// Passwords, Chrome, Proton Pass CSV and JSON, Petal's own) and exporters, password making, old items, and that what
// the AI is told never holds a secret. No Keychain, no window, no screen.

@main
struct VaultCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; print("FAIL: \(what)") }
    }

    static func main() {
        unlisted()
        guard VaultSite.load(URL(fileURLWithPath: "Resources/public_suffix_list.dat")) else {
            print("FAIL: the Public Suffix List (macos/Resources/public_suffix_list.dat) didn't load")
            exit(1)
        }
        suffixList()
        sites()
        exports()
        imports()
        passwords()
        migration()
        shown()
        decisions()
        picking()
        redaction()
        records()
        places()
        checkouts()
        if failures > 0 { print("vault: \(failures) failed"); exit(1) }
        print("vault: ok")
    }

    /// Before the list is read: a login fills only on its saved host and what's under it.
    static func unlisted() {
        let m = VaultSite.matches
        expect(m("github.com", "github.com") && m("accounts.github.com", "github.com"), "no list: the host and under it")
        expect(!m("github.com", "accounts.github.com"), "no list: not up to a registrable name it can't work out")
        expect(!m("evil.uk.com", "bank.uk.com") && !m("evil.duckdns.org", "home.duckdns.org"), "no list: no sibling")
        expect(VaultSite.registrable("www.example.co.uk") == "www.example.co.uk", "no list: the host itself")
    }

    /// The Public Suffix List's own rules, ICANN and private, wildcards and exceptions.
    static func suffixList() {
        let r = VaultSite.registrable
        expect(r("bank.uk.com") == "bank.uk.com" && r("www.bank.uk.com") == "bank.uk.com", "uk.com is a private suffix")
        expect(r("home.duckdns.org") == "home.duckdns.org", "duckdns.org is a private suffix")
        expect(r("me.github.io") == "me.github.io" && r("x.me.github.io") == "me.github.io", "github.io")
        expect(r("www.example.co.uk") == "example.co.uk", "co.uk")
        expect(r("foo.bar.ck") == "foo.bar.ck", "*.ck: every second-level name is a suffix")
        expect(r("www.ck") == "www.ck" && r("a.www.ck") == "www.ck", "!www.ck: the exception is registrable")
        let m = VaultSite.matches
        expect(!m("evil.uk.com", "bank.uk.com") && m("www.bank.uk.com", "bank.uk.com"), "a sibling on uk.com never fills")
        expect(!m("evil.duckdns.org", "home.duckdns.org"), "a sibling on duckdns.org never fills")
        expect(!m("evil.github.io", "me.github.io"), "a sibling on github.io never fills")
        expect(!m("other.co.uk", "example.co.uk") && m("login.example.co.uk", "example.co.uk"), "co.uk")
        expect(!m("x.bar.ck", "y.bar.ck") && !m("evil.ck", "www.ck"), "wildcard and exception rules")
        expect(!m("anything.uk.com", "uk.com") && m("uk.com", "uk.com"), "a suffix saved as a site matches only itself")
        expect(!m("evil.example", "x.example") && m("a.x.example", "x.example"), "a name the list doesn't cover: the host and under it")
    }

    static func sites() {
        let r = VaultSite.registrable
        expect(r("gist.github.com") == "github.com", "gist.github.com → github.com")
        expect(r("www.example.co.uk") == "example.co.uk", "co.uk")
        expect(r("a.b.example.com.tr") == "example.com.tr", "com.tr")
        expect(r("ogrenci.example.edu.tr") == "example.edu.tr", "edu.tr")
        expect(r("shop.example.co.jp") == "example.co.jp", "co.jp")
        expect(r("x.example.com.au") == "example.com.au", "com.au")
        expect(r("me.github.io") == "me.github.io", "github.io is hosting")
        expect(r("https://login.example.org/path?x=1") == "example.org", "from an address")
        expect(r("192.168.1.10") == "192.168.1.10", "an IP address is itself")
        expect(r("Example.COM.") == "example.com", "case and trailing dot")
        expect(r("foo.example.ac.ir") == "example.ac.ir", "ac under a country, by the rule")

        let m = VaultSite.matches
        expect(m("github.com", "github.com"), "same host")
        expect(m("accounts.github.com", "github.com"), "subdomain")
        expect(m("github.com", "accounts.github.com"), "the registrable name of a saved subdomain")
        expect(!m("githuh.com", "github.com"), "a lookalike")
        expect(!m("github.com.evil.com", "github.com"), "github.com as a subdomain elsewhere")
        expect(!m("evilgithub.com", "github.com"), "suffix without a dot")
        expect(!m("evil.github.io", "me.github.io"), "another github.io site")
        expect(m("me.github.io", "me.github.io"), "the same github.io site")
        expect(!m("anything.github.io", "github.io"), "a shared suffix saved as a site matches only itself")
        expect(!m("other.co.uk", "example.co.uk"), "another co.uk")
        expect(m("www.example.co.uk", "example.co.uk"), "www under co.uk")
        expect(!m("10.0.0.2", "10.0.0.1"), "another IP")
        expect(m("https://www.github.com/login", "https://github.com"), "addresses both sides")
        expect(m("http://localhost:5173/login", "localhost"), "localhost, any port")
        expect(!m("evil.localhost", "localhost") && !m("localhost", "github.com"), "localhost only matches itself")
        expect(VaultSite.host("http://[::1]:3000/x") == "::1", "IPv6 loopback without brackets")
        expect(VaultSite.host("github.com") == "github.com", "bare host")
        expect(VaultSite.host("https://user:pw@GitHub.com:443/x") == "github.com", "host without user, port, case")
        expect(VaultSite.host("not a url") == nil, "no host")
        expect(Vault.secure("http://127.0.0.1:8080") && Vault.secure("http://[::1]/") && Vault.secure("http://localhost/"), "this Mac over http")
        expect(!Vault.secure("http://example.com/") && Vault.secure("https://example.com/"), "http elsewhere isn't secure")
    }

    static func sample() -> [VaultItem] {
        var login = VaultItem(kind: .login, title: "GitHub, \"work\"", sites: ["github.com"], updated: Date(timeIntervalSince1970: 1_700_000_000.123))
        login[.username] = "ada"
        login[.password] = "p,w\"q\nx"
        login[.notes] = "two\nlines"
        var app = VaultItem(kind: .login, title: "Slack", apps: ["com.tinyspeck.slackmacgap"], appSigners: ["com.tinyspeck.slackmacgap": "BQR82RBBHL"])
        app[.password] = "slack-pass-1234"
        var deniz = VaultItem(kind: .contact, title: "Deniz")
        deniz[.name] = "Deniz Kaya"
        deniz[.relationship] = "girlfriend"
        deniz[.email] = "deniz@example.com"
        var me = VaultItem(kind: .contact, title: "Me")
        me[.name] = "Ada Lovelace"
        me[.relationship] = "me"
        var home = VaultItem(kind: .address, title: "Home")
        home[.name] = "Deniz Kaya"
        home[.street] = "Bağdat Cd. 12"
        home[.street2] = "Daire 4"
        home[.city] = "İstanbul"
        home[.postalCode] = "34728"
        home[.country] = "Türkiye"
        home[.contact] = deniz.id
        var card = VaultItem(kind: .card, title: "Visa")
        card[.name] = "Ada Lovelace"
        card[.number] = "4111 1111 1111 1111"
        card[.expiry] = "04/27"
        card[.securityCode] = "737"
        var key = VaultItem(kind: .apiKey, title: "OpenAI", sites: ["platform.openai.com"])
        key[.value] = "sk-abcdefghijklmnop"
        return [login, app, deniz, me, home, card, key]
    }

    static func exports() {
        let items = sample()
        // Petal's own file: every kind, every field and link, ids and dates, back exactly.
        let data = Vault.exportJSON(items)
        let back = Vault.importData(data)
        expect(back?.items == items, "Petal's export round trip is lossless")
        let merged = Vault.merge(existing: [], incoming: back?.items ?? [])
        expect(merged.save.sorted { $0.id < $1.id } == items.sorted { $0.id < $1.id } && merged.added == items.count, "importing it into an empty vault keeps every item as it was")
        let again = Vault.merge(existing: items, incoming: items)
        expect(again.save.isEmpty && again.same == items.count, "importing it again changes nothing")
        // Logins as CSV, in Chrome's format: back with the same title, site, username, password and notes.
        let csv = Vault.exportCSV(items)
        expect(csv.hasPrefix("name,url,username,password,note\r\n"), "Chrome's header")
        let logins = Vault.importData(Data(csv.utf8))?.items ?? []
        expect(logins.count == 2, "only the logins go in the CSV (got \(logins.count))")
        let web = logins.first { $0.sites == ["github.com"] }
        expect(web?.title == items[0].title && web?.username == "ada" && web?[.password] == items[0][.password] && web?[.notes] == "two\nlines",
               "the CSV round trip keeps a login's title, site, username, password and notes")
    }

    static func imports() {
        let rows = Vault.csv("a,\"b, with comma\",\"say \"\"hi\"\"\"\r\n\"multi\nline\",x,\n")
        expect(rows.count == 2, "two rows (got \(rows.count))")
        expect(rows.first == ["a", "b, with comma", "say \"hi\""], "quotes and commas")
        expect(rows.last == ["multi\nline", "x", ""], "a line break inside quotes, an empty last field")
        expect(Vault.csv("\u{FEFF}x,y\n") == [["x", "y"]], "byte-order mark")

        let apple = """
        Title,URL,Username,Password,Notes,OTPAuth
        GitHub,https://github.com/login,ada,pa55-word,"two
        lines",otpauth://totp/GitHub:ada?secret=GEZDGNBVGY3TQOJQ
        Bank,https://www.bank.com.tr/,ada@example.com,"p,w""q",,
        Empty,https://empty.example,,,,
        """
        guard let parsed = Vault.importCSV(apple) else { return expect(false, "Apple Passwords header") }
        expect(parsed.items.count == 2 && parsed.skipped == 1, "two logins and one empty row (got \(parsed.items.count), \(parsed.skipped))")
        let github = parsed.items[0]
        expect(github.title == "GitHub" && github.sites == ["github.com"] && github.username == "ada" && github[.password] == "pa55-word", "GitHub row")
        expect(github[.notes] == "two\nlines" && !github.fields.values.contains { $0.contains("otpauth") }, "notes kept, the 2FA column left out")
        expect(parsed.items[1].sites == ["www.bank.com.tr"] && parsed.items[1][.password] == "p,w\"q", "quoted password")

        let chrome = "name,url,username,password,note\nexample.com,https://example.com/,bob,secret1,\n"
        expect(Vault.importCSV(chrome)?.items.first?.username == "bob", "Chrome's header")
        let shuffled = "password,username,url\nsecret2,carol,https://c.example/\n"
        expect(Vault.importCSV(shuffled)?.items.first.map { $0.username == "carol" && $0.sites == ["c.example"] } == true, "columns in any order")
        expect(Vault.importCSV("foo,bar\n1,2\n") == nil, "an unknown header")

        let proton = """
        type,name,url,email,username,password,note,totp,createTime,modifyTime,vault
        login,Shop,https://shop.example/,ada@example.com,,shop-pass,,,1,2,Personal
        note,A note,,,,,secret note,,1,2,Personal
        login,Mail,https://mail.example/,ada@mail.example,ada,mail-pass,,otpauth://totp/x?secret=AAAA,1,2,Personal
        """
        let fromProton = Vault.importCSV(proton)
        expect(fromProton?.items.count == 2 && fromProton?.skipped == 1, "Proton Pass CSV: two logins, a note left out")
        expect(fromProton?.items.first?.username == "ada@example.com", "Proton Pass: the email is the username when there's none")

        let protonJSON = #"""
        {"version":"1.21","encrypted":false,"vaults":{"s1":{"name":"Personal","items":[
          {"state":1,"data":{"type":"login","metadata":{"name":"GitHub","note":"n"},"content":{"itemEmail":"a@b.com","itemUsername":"ada","password":"gh-pass","urls":["https://github.com/login","https://github.com/"],"totpUri":"otpauth://totp/x?secret=AAAA"}}},
          {"state":1,"data":{"type":"creditCard","metadata":{"name":"Visa"},"content":{"cardholderName":"Ada","number":"4242424242424242","verificationCode":"123","expirationDate":"2027-04"}}},
          {"state":1,"data":{"type":"identity","metadata":{"name":"Deniz"},"content":{"fullName":"Deniz Kaya","email":"deniz@example.com","phoneNumber":"+90 555","streetAddress":"Bağdat Cd. 12","city":"İstanbul","zipOrPostalCode":"34728","countryOrRegion":"Türkiye"}}},
          {"state":2,"data":{"type":"login","metadata":{"name":"Old"},"content":{"password":"x"}}},
          {"state":1,"data":{"type":"alias","metadata":{"name":"alias"},"content":{}}}
        ]}}}
        """#
        guard let json = Vault.importData(Data(protonJSON.utf8)) else { return expect(false, "Proton Pass JSON") }
        expect(json.skipped == 2, "trashed and alias left out (got \(json.skipped))")
        let login = json.items.first { $0.kind == .login }
        expect(login?.username == "ada" && login?.sites == ["github.com"] && login?[.password] == "gh-pass" && login?[.notes] == "n", "Proton login")
        let card = json.items.first { $0.kind == .card }
        expect(card?[.expiry] == "04/27" && card?[.securityCode] == "123" && card?[.name] == "Ada", "Proton card")
        let contact = json.items.first { $0.kind == .contact }, address = json.items.first { $0.kind == .address }
        expect(contact?[.name] == "Deniz Kaya" && contact?[.email] == "deniz@example.com", "Proton identity as contact info")
        expect(address?[.contact] == contact?.id && address?[.city] == "İstanbul" && address?[.name] == "Deniz Kaya", "its address, linked to it")

        // Merging: a login with a newer password is updated (kept the import's); the same one changes nothing; an
        // imported address whose contact is already saved is linked to the saved one.
        var saved = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"])
        saved[.username] = "ADA"
        saved[.password] = "old"
        var same = VaultItem(kind: .login, title: "Bank", sites: ["www.bank.com.tr"])
        same[.username] = "ada@example.com"
        same[.password] = "p,w\"q"
        let merged = Vault.merge(existing: [saved, same], incoming: parsed.items)
        expect(merged.added == 0 && merged.same == 1 && merged.updated == ["GitHub"], "merge: one newer password, one the same")
        expect(merged.save.count == 1 && merged.save[0].id == saved.id && merged.save[0][.password] == "pa55-word", "the saved login keeps its id")
        let twice = Vault.merge(existing: [], incoming: parsed.items + parsed.items)
        expect(twice.added == 2 && twice.same == 2, "the same row twice in a file is one login")
        var deniz = VaultItem(kind: .contact, title: "Deniz")
        deniz[.email] = "deniz@example.com"
        let linked = Vault.merge(existing: [deniz], incoming: json.items.filter { $0.kind == .contact || $0.kind == .address })
        let newAddress = linked.save.first { $0.kind == .address }
        expect(newAddress?[.contact] == deniz.id, "an imported address joins the contact already saved")
    }

    static func passwords() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        let random: (Int) -> [UInt8] = { count in
            (0..<count).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        for _ in 0..<200 {
            let password = Vault.password(random: random)
            expect(password.count == 20, "20 characters")
            expect(password.contains(where: \.isLowercase) && password.contains(where: \.isUppercase) && password.contains(where: \.isNumber)
                   && password.contains(where: { Vault.symbols.contains($0) }), "every kind of character: \(password)")
            expect(!password.contains(where: { "lIO01".contains($0) }), "no look-alikes")
        }
        let plain = Vault.password(length: 16, symbols: false, random: random)
        expect(plain.count == 16 && plain.allSatisfy { $0.isLetter || $0.isNumber }, "letters and digits only")
        let limited = Vault.password(length: 30, allowed: "!_ab", random: random)
        expect(limited.count == 30 && limited.allSatisfy { $0.isLetter || $0.isNumber || "!_".contains($0) } && limited.contains(where: { "!_".contains($0) }),
               "only the symbols the site takes")
        expect(Vault.password(length: 3, random: random).count == 12 && Vault.password(length: 500, random: random).count == 64, "length kept to 12…64")
        var flip = false
        let skewed: (Int) -> [UInt8] = { count in flip.toggle(); return [UInt8](repeating: flip ? 255 : 7, count: count) }
        expect(Vault.password(random: skewed).count == 20, "rejection sampling ends")
    }

    static func migration() {
        let items = Vault.migrate([("OpenAI key", "sk-hunter22"), ("Empty", ""), ("", "x1")])
        expect(items.count == 2, "empty secrets dropped")
        expect(items[0].kind == .apiKey && items[0].title == "OpenAI key" && items[0][.value] == "sk-hunter22", "a name and secret become an API key")
        expect(items[1].title == "Key", "a nameless one gets a title")
        expect(Vault.find(items, "openai KEY")?.id == items[0].id, "found by its old name")
        let old = #"{"id":"abc","kind":"login","title":"T"}"#
        expect((try? JSONDecoder().decode(VaultItem.self, from: Data(old.utf8)))?.title == "T", "lenient decoding")
    }

    static func shown() {
        let items = sample()
        for item in items {
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: Vault.shown(item, in: items))) ?? Data(), as: UTF8.self)
            for field in VaultField.allCases where field.isSecret && !item[field].isEmpty {
                expect(!json.contains(item[field].replacingOccurrences(of: "\n", with: "\\n")) && !json.contains(item[field]), "\(item.title): \(field) never shown")
            }
            expect(!json.contains("4111111111111111") && !json.contains("1111 1111"), "\(item.title): no card number")
        }
        let card = Vault.shown(items[5])
        expect(card["last4"] as? String == "1111" && card["brand"] as? String == "Visa" && card["expiry"] as? String == "04/27", "a card's last four, brand, expiry")
        let deniz = Vault.shown(items[2], in: items)
        expect(deniz["relationship"] as? String == "girlfriend" && (deniz["addresses"] as? [[String: String]])?.first?["label"] == "Home", "a contact with her addresses")
        let home = Vault.shown(items[4], in: items)
        expect(home["street"] as? String == "Bağdat Cd. 12" && home["contactName"] as? String == "Deniz Kaya", "an address in full, with its contact")
        expect(Vault.shown(items[3])["me"] as? Bool == true, "the owner's own contact")
        expect(Vault.shown(items[6])["hasKey"] as? Bool == true, "an API key's title, never the key")
    }

    static func decisions() {
        let items = sample()
        let login = items[0], app = items[1], home = items[4], card = items[5], key = items[6]
        var deniz = items[2]
        deniz[.phone] = "+90 555"
        let secure = Vault.Target(secure: true, text: true)
        let text = Vault.Target(secure: false, text: true)
        let popup = Vault.Target(secure: false, text: false, popup: true)
        func web(_ frame: String?, top: String? = nil, tab: String? = nil) -> Vault.Place {
            Vault.Place(web: true, frameURL: frame, topURL: top ?? frame, tabURL: tab, bundle: "com.apple.Safari", appName: "Safari", signed: true)
        }
        func isAsk(_ d: Vault.Decision) -> Bool { if case .ask = d { return true }; return false }
        func isRefuse(_ d: Vault.Decision) -> Bool { if case .refuse = d { return true }; return false }

        // Logins.
        expect(Vault.decide(login, .password, target: secure, place: web("https://github.com/login")) == .fill, "own site fills")
        expect(Vault.decide(login, .password, target: secure, place: web("https://github.com/session", tab: "https://github.com/session")) == .fill, "tab agrees")
        expect(Vault.decide(login, .username, target: text, place: web("https://accounts.github.com/")) == .fill, "a subdomain fills")
        expect(Vault.decide(login, .password, target: secure, place: web("https://github.com/embed", top: "https://partner.example/")) == .fill,
               "a login frame from its own site: the frame's address decides")
        let phish = Vault.decide(login, .password, target: secure, place: web("https://githuh-login.com/"))
        if case .ask(let title, let detail) = phish {
            expect(title == "Fill your github.com password on githuh-login.com?", "the question names both: \(title)")
            expect(detail.contains("githuh-login.com") && detail.contains("github.com"), "the mismatch is said plainly")
        } else { expect(false, "a lookalike asks") }
        expect(isAsk(Vault.decide(login, .password, target: secure, place: web("http://github.com/login"))), "http asks")
        expect(isAsk(Vault.decide(login, .password, target: secure, place: web("https://github.com/x", top: "http://github.com/"))), "an http page around asks")
        expect(isAsk(Vault.decide(login, .password, target: secure, place: web("https://github.com/", tab: "https://evil.com/"))), "a tab that disagrees asks")
        expect(isAsk(Vault.decide(login, .password, target: secure, place: web(nil))), "an unreadable page asks")
        expect(isRefuse(Vault.decide(login, .password, target: text, place: web("https://github.com/"))), "a password never into a text field")
        expect(isRefuse(Vault.decide(login, .username, target: secure, place: web("https://github.com/"))), "a username never into a password field")
        expect(isRefuse(Vault.decide(login, .password, target: Vault.Target(secure: false, text: false), place: web("https://github.com/"))), "not into a button")
        expect(isRefuse(Vault.decide(login, .number, target: text, place: web("https://github.com/"))), "a login has no card number")
        var test = VaultItem(kind: .login, title: "Dev", sites: ["localhost"])
        test[.password] = "dev-pass-1"
        expect(Vault.decide(test, .password, target: secure, place: web("http://localhost:3000/login")) == .fill, "a test login on http://localhost")
        var loop = VaultItem(kind: .login, title: "Dev", sites: ["127.0.0.1", "::1"])
        loop[.password] = "dev-pass-1"
        expect(Vault.decide(loop, .password, target: secure, place: web("http://127.0.0.1:8080/")) == .fill, "on http://127.0.0.1")
        expect(Vault.decide(loop, .password, target: secure, place: web("http://[::1]:8080/")) == .fill, "on http://[::1]")
        expect(isAsk(Vault.decide(test, .password, target: secure, place: web("http://evil.example/"))), "a localhost login elsewhere asks")
        let native = Vault.Place(web: false, bundle: "com.tinyspeck.slackmacgap", appName: "Slack", signed: true, team: "BQR82RBBHL")
        expect(Vault.decide(app, .password, target: secure, place: native) == .fill, "its own app fills")
        var unsigned = native
        unsigned.signed = false
        expect(isAsk(Vault.decide(app, .password, target: secure, place: unsigned)), "an app whose signature fails asks")
        var other = native
        other.bundle = "com.example.fake"
        expect(isAsk(Vault.decide(app, .password, target: secure, place: other)), "another app asks")
        var lookalike = native
        lookalike.team = "EVILTEAM12"
        expect(isAsk(Vault.decide(app, .password, target: secure, place: lookalike)), "the same bundle id signed by someone else asks")
        var unbound = app
        unbound.appSigners = [:]
        expect(isAsk(Vault.decide(unbound, .password, target: secure, place: native)), "an app login with no saved signer asks")
        expect(Vault.moved(from: native, to: lookalike) != nil, "another signer since the decision")
        expect(isAsk(Vault.decide(login, .password, target: secure, place: native)), "a web login in an app asks")
        let nowhere = VaultItem(kind: .login, title: "X", fields: ["password": "pw-12345678"])
        expect(isAsk(Vault.decide(nowhere, .password, target: secure, place: web("https://x.com/"))), "a login saved for no site asks")

        // API keys.
        expect(Vault.decide(key, .value, target: text, place: web("https://platform.openai.com/settings")) == .fill, "a key on its service")
        expect(Vault.decide(key, .value, target: secure, place: web("https://openai.com/")) == .fill, "a key on its service's registrable name")
        expect(Vault.decide(key, .value, target: text, place: web("http://localhost:8000/setup")) == .fill, "a key on this Mac's page")
        expect(Vault.decide(key, .value, target: text, place: web("http://127.0.0.1/", tab: "http://127.0.0.1/")) == .fill, "a key on 127.0.0.1")
        expect(isAsk(Vault.decide(key, .value, target: text, place: web("file://localhost/Users/x/page.html"))), "file://localhost isn't this Mac's web page")
        expect(isAsk(Vault.decide(key, .value, target: text, place: web("ftp://localhost/"))), "only http and https on this Mac")
        expect(Vault.decide(key, .value, target: text, place: native) == .fill, "a key into an app")
        let stolen = Vault.decide(key, .value, target: text, place: web("https://0penai-billing.com/"))
        if case .ask(let title, let detail) = stolen {
            expect(title.contains("0penai-billing.com") && detail.contains("platform.openai.com"), "a key on another site asks, saying both")
        } else { expect(false, "a key on another site asks") }
        expect(isAsk(Vault.decide(key, .value, target: text, place: web("http://platform.openai.com/"))), "a key over http elsewhere asks")
        var bare = key
        bare.sites = []
        expect(isAsk(Vault.decide(bare, .value, target: text, place: web("https://example.com/"))), "a key with no service asks on a site")
        expect(Vault.decide(bare, .value, target: text, place: native) == .fill, "a key with no service fills into an app")

        // Payment info: nothing before Buy; once Buy, every field; only https.
        let shop = web("https://checkout.shop.example/pay")
        expect(Vault.decide(card, .number, target: text, place: shop) == .buy(shop: "checkout.shop.example"), "a card number waits for Buy, on the exact host")
        expect(Vault.decide(card, .name, target: text, place: shop) == .buy(shop: "checkout.shop.example"), "even the name on the card waits for Buy")
        expect(Vault.decide(card, .securityCode, target: secure, place: shop, checkout: true) == .fill, "after Buy the security code fills")
        expect(Vault.decide(card, .month, target: popup, place: shop, checkout: true) == .fill, "after Buy a month from a menu")
        let stripe = web("https://js.stripe.com/v3/elements", top: "https://shop.example/checkout")
        expect(Vault.decide(card, .number, target: text, place: stripe) == .buy(shop: "shop.example"), "a payment frame: the shop is the tab's page")
        expect(Vault.mixed(.card, [stripe, web("https://shop.example/checkout")]) == nil, "a payment frame and its shop's page are one place")
        expect(isRefuse(Vault.decide(card, .number, target: text, place: web("http://shop.example/"), checkout: true)), "never on http")
        expect(isRefuse(Vault.decide(card, .number, target: text, place: web("http://localhost/"), checkout: true)), "never on http, even this Mac")
        expect(isRefuse(Vault.decide(card, .number, target: text, place: native, checkout: true)), "never into an app")
        expect(isRefuse(Vault.decide(card, .number, target: text, place: web("https://shop.example/", tab: "https://evil.example/"), checkout: true)),
               "never when the tab disagrees")
        expect(Vault.text(card, .month) == "04" && Vault.text(card, .year) == "27" && Vault.text(card, .year, fourDigitYear: true) == "2027", "month and year")

        // Contact info and addresses: freely, anywhere, field by field.
        expect(Vault.decide(deniz, .email, target: text, place: web("http://anywhere.example/")) == .fill, "contact info anywhere")
        expect(Vault.decide(home, .street, target: text, place: shop) == .fill && Vault.decide(home, .street2, target: text, place: shop) == .fill, "address lines")
        expect(Vault.decide(home, .country, target: popup, place: shop) == .fill, "a country from a menu")
        expect(isRefuse(Vault.decide(home, .city, target: popup, place: shop)), "a city isn't picked from a menu")
        expect(isRefuse(Vault.decide(home, .region, target: text, place: shop)), "nothing saved, nothing filled")
        expect(isRefuse(Vault.decide(deniz, .email, target: secure, place: shop)), "contact info never into a password field")
        expect(isRefuse(Vault.decide(deniz, .relationship, target: text, place: shop)), "a relationship isn't typed into pages")

        expect(Vault.field("CVV") == .securityCode && Vault.field("zip") == .postalCode && Vault.field("line2") == .street2, "field words")
        expect(Vault.field("email", kind: .login) == .username && Vault.field("email", kind: .contact) == .email, "a login's email is its username")
        expect(Vault.field("favourite colour") == nil, "an unknown field")
        let here = web("https://github.com/login")
        expect(Vault.moved(from: here, to: web("https://github.com/session")) == nil, "the same site, another path")
        expect(Vault.moved(from: here, to: web("https://githuh.com/login")) != nil, "another site")
        expect(Vault.moved(from: here, to: web("http://github.com/login")) != nil, "http now")
        expect(Vault.moved(from: here, to: web("https://github.com/x", top: "https://evil.example/")) != nil, "now framed by another page")
        expect(Vault.moved(from: native, to: other) != nil && Vault.moved(from: native, to: native) == nil, "another app")
    }

    static func picking() {
        let countries = ["Select…", "Germany", "Turkey", "United Kingdom", "United States"]
        expect(Vault.pick("Türkiye", from: countries) == 2, "Türkiye is Turkey")
        expect(Vault.pick("USA", from: countries) == 4, "USA")
        expect(Vault.pick("germany", from: countries) == 1, "case aside")
        expect(Vault.pick("United", from: countries) == nil, "two start alike: unsure")
        expect(Vault.pick("Atlantis", from: countries) == nil, "not there")
        expect(Vault.pick("Türkiye", from: ["Almanya", "Türkiye"]) == 1, "the same words in Turkish")
        expect(Vault.pick("04", from: ["MM", "01", "02", "03", "04"]) == 4, "a month by number")
        expect(Vault.pick("4", from: ["Month", "January", "February", "March", "April"]) == 4, "a month by name")
        expect(Vault.pick("27", from: ["2026", "2027"]) == nil && Vault.pick("2027", from: ["2026", "2027"]) == 1, "a four-digit year")
    }

    static func redaction() {
        let items = sample()
        let index = UIMap.SecretIndex(items.flatMap(Vault.secrets))
        expect(index.matches("Card: 4111 1111 1111 1111"), "a card number in fours is caught")
        expect(index.matches("4111-1111-1111-1111"), "with dashes")
        expect(index.matches("4111111111111111"), "as digits")
        expect(index.matches("key=sk-abcdefghijklmnop"), "an API key")
        expect(index.matches("pw: slack-pass-1234"), "a password")
        expect(!index.matches("ada@example.com") && !index.matches("Bağdat Cd. 12"), "a username or address isn't a secret")
        expect(!index.matches("Visa ending 1111"), "the last four aren't a secret")
        // A 3-digit security code: wherever it isn't part of a longer number.
        expect(index.matches("CVV: 737") && index.matches("cvc737") && index.matches("737") && index.matches("(737)"), "a security code by itself")
        expect(!index.matches("17370") && !index.matches("7371") && !index.matches("Order 1737"), "not inside a longer number")
        expect(index.redacted("CVV: 737, order 17370") == "CVV: \(UIMap.hidden), order 17370", "only the code itself is hidden")
        expect(UIMap.SecretIndex(["ab1"]).matches("x ab1 y") == false, "3 characters that aren't digits aren't looked for inside text")
        // Payment fields are named so in petal_ui and pictures.
        var field = UINode(role: "AXTextField")
        field.label = "Security code"
        expect(UIMap.looksSecret(field), "a security code field")
        field.label = ""
        field.identifier = "cc-number"
        expect(UIMap.looksSecret(field), "a card number field by its autofill id")
        field.identifier = "quantity"
        expect(!UIMap.looksSecret(field), "a quantity field isn't")
        // What Petal typed is listed with every form of it (a card number's fours).
        let typed = UIMap.SecretIndex(Vault.secrets(.number, "5555444433331111") + Vault.secrets(.password, "typed-only-pw"))
        expect(typed.matches("5555 4444 3333 1111") && typed.matches("pw typed-only-pw"), "a typed secret is hidden too")
        expect(Vault.secrets(.email, "a@b.c").isEmpty, "contact info isn't a secret")
    }

    /// Keychain records: Petal's own items, and secrets from before kinds, whatever their names.
    static func records() {
        let item = sample()[0]
        let data = (try? JSONEncoder().encode(item)) ?? Data()
        expect(Vault.stored(account: "item:" + item.id, data: data, marked: true) == .item(item), "a marked item")
        expect(Vault.stored(account: "item:" + item.id, data: data, marked: false) == .item(item), "an item from before the mark, by its id")
        expect(Vault.stored(account: "item:work", data: Data("sk-legacy-123".utf8), marked: false) == .legacy(name: "item:work", secret: "sk-legacy-123"),
               "an old secret named item:… stays a secret")
        expect(Vault.stored(account: "item:x", data: Data("{\"id\":\"x\"}".utf8), marked: false) == .legacy(name: "item:x", secret: "{\"id\":\"x\"}"),
               "JSON that isn't an item is an old secret")
        expect(Vault.stored(account: "item:other", data: data, marked: false) == .legacy(name: "item:other", secret: String(decoding: data, as: UTF8.self)),
               "an item under another id isn't trusted as one")
        expect(Vault.stored(account: "OpenAI", data: Data("sk-1".utf8), marked: false) == .legacy(name: "OpenAI", secret: "sk-1"), "a plain old name")
        expect(Vault.stored(account: "x", data: Data([0xff, 0xfe, 0x00]), marked: false) == .unreadable, "bytes that aren't text")
        expect(Vault.migrate([("item:work", "sk-legacy-123")]).first?.title == "item:work", "it becomes an API key under its name")

        // Logins for apps: a login is the same only for the same site or app and username.
        var slack = VaultItem(kind: .login, title: "Slack", apps: ["com.tinyspeck.slackmacgap"])
        slack[.username] = "ada"
        slack[.password] = "one"
        var zoom = VaultItem(kind: .login, title: "Zoom", apps: ["us.zoom.xos"])
        zoom[.username] = "ada"
        zoom[.password] = "two"
        expect(!Vault.same(slack, zoom), "two apps' logins with the same username are two logins")
        let both = Vault.merge(existing: [], incoming: [slack, zoom])
        expect(both.added == 2, "export and import keep both app logins")
        var again = zoom
        again.id = Vault.newID()
        expect(Vault.same(zoom, again), "the same app and username is the same login")
        var nowhere1 = VaultItem(kind: .login, title: "A"), nowhere2 = VaultItem(kind: .login, title: "B")
        nowhere1[.password] = "p1"
        nowhere2[.password] = "p2"
        expect(!Vault.same(nowhere1, nowhere2), "logins saved for nowhere are never merged")
        expect(Vault.merge(existing: [nowhere1], incoming: [nowhere2]).added == 1, "so neither password is lost")
        let round = Vault.importData(Vault.exportJSON([slack, zoom, nowhere1, nowhere2]))?.items ?? []
        expect(Vault.merge(existing: [], incoming: round.map { var i = $0; i.id = Vault.newID(); return i }).added == 4, "every one survives a round trip into a fresh vault")
    }

    /// One fill, one place; new_login and requests check every field.
    static func places() {
        func web(_ frame: String?, top: String? = nil) -> Vault.Place {
            Vault.Place(web: true, frameURL: frame, topURL: top ?? frame, bundle: "com.apple.Safari", appName: "Safari", signed: true)
        }
        let secure = Vault.Target(secure: true, text: true), text = Vault.Target(secure: false, text: true)
        let page = web("https://github.com/signup")
        let frame = web("https://evil.example/frame", top: "https://github.com/signup")
        expect(Vault.mixed(.login, [page, page]) == nil, "fields on one page")
        expect(Vault.mixed(.login, [page, frame]) != nil, "a login's fields in two sites' frames are refused")
        expect(Vault.mixed(.login, [page, web("http://github.com/signup")]) != nil, "https and http are two places")
        expect(Vault.mixed(.contact, [page, frame]) == nil, "contact info fills freely")
        let native = Vault.Place(web: false, bundle: "com.example.app", appName: "App", signed: true, team: "TEAM123456")
        expect(Vault.mixed(.apiKey, [page, native]) != nil, "a page and an app are two places")

        // new_login: every field must fill by itself.
        var login = VaultItem(kind: .login, title: "GitHub")
        Vault.bind(&login, to: page)
        login[.username] = "ada"
        login[.password] = "x"
        expect(login.sites == ["github.com"], "saved for the page read")
        expect(Vault.unasked(login, [.password, .password, .username], targets: [secure, secure, text], places: [page, page, page]) == nil, "one secure page")
        expect(Vault.unasked(login, [.password, .password], targets: [secure, secure], places: [page, frame])?.index == 0, "a confirm field in another site's frame")
        let http = web("http://github.com/signup")
        var plain = VaultItem(kind: .login, title: "GitHub")
        Vault.bind(&plain, to: http)
        plain[.password] = "x"
        expect(Vault.unasked(plain, [.password], targets: [secure], places: [http]) != nil, "no password made on http")
        var appLogin = VaultItem(kind: .login, title: "App")
        Vault.bind(&appLogin, to: native)
        appLogin[.password] = "x"
        expect(appLogin.appSigners == ["com.example.app": "TEAM123456"], "an app login keeps who signed it")
        expect(Vault.unasked(appLogin, [.password], targets: [secure], places: [native]) == nil, "a verified app")
        var unverified = native
        unverified.team = nil
        var none = VaultItem(kind: .login, title: "App")
        Vault.bind(&none, to: unverified)
        expect(none.apps.isEmpty, "an app Petal can't verify isn't saved as the login's")

        // request: a refusal before the card; what doesn't match, on the card.
        expect(Vault.request(.login, [.username, .password], targets: [text, secure], places: [page, page], saved: 1) == Vault.Requested(), "a login form on its page")
        let overHTTP = Vault.request(.login, [.username, .password], targets: [text, secure], places: [http, http], saved: 1)
        expect(overHTTP.refusal == nil && overHTTP.warning?.contains("secure") == true, "http: the card says it isn't secure")
        expect(Vault.request(.login, [.username, .password], targets: [text, secure], places: [page, frame], saved: 1).refusal != nil, "two sites: refused")
        expect(Vault.request(.login, [.password], targets: [text], places: [page], saved: 0).refusal != nil, "a password into a text field: refused")
        expect(Vault.request(.apiKey, [.value], targets: [text], places: [web("http://evil.example/")], saved: 0).warning != nil, "a key over http elsewhere: warned")
        expect(Vault.request(.contact, [.email], targets: [text], places: [http], saved: 0) == Vault.Requested(), "contact info: nothing to warn about")
        expect(Vault.question(login, [.username, .password], place: frame) == "Fill your github.com username and password on evil.example?", "one question names every field")
    }

    /// A Buy covers its exact host, window, tab, card and reply only.
    static func checkouts() {
        func web(_ frame: String, tab: String? = nil) -> Vault.Place {
            Vault.Place(web: true, frameURL: frame, topURL: frame, tabURL: tab, bundle: "com.apple.Safari", appName: "Safari", signed: true)
        }
        let pay = web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay")
        let bought = Vault.Checkout(host: "checkout.shop.example", window: 7, tab: "checkout.shop.example", card: "visa", turn: "3|")
        expect(bought.covers(pay, window: 7, card: "visa", turn: "3|"), "the same checkout")
        expect(bought.covers(web("https://checkout.shop.example/confirm", tab: "https://checkout.shop.example/confirm"), window: 7, card: "visa", turn: "3|"),
               "another page of the same host")
        expect(!bought.covers(web("https://other.shop.example/pay", tab: "https://other.shop.example/pay"), window: 7, card: "visa", turn: "3|"), "a subdomain asks again")
        expect(!bought.covers(web("https://evil.example/pay", tab: "https://evil.example/pay"), window: 7, card: "visa", turn: "3|"), "another shop")
        expect(!bought.covers(pay, window: 8, card: "visa", turn: "3|"), "another window")
        expect(!bought.covers(pay, window: nil, card: "visa", turn: "3|"), "a window Petal can't name")
        expect(!bought.covers(pay, window: 7, card: "amex", turn: "3|"), "another card")
        expect(!bought.covers(pay, window: 7, card: "visa", turn: "4|"), "the next reply")
        expect(!bought.covers(web("https://checkout.shop.example/pay", tab: "https://evil.example/"), window: 7, card: "visa", turn: "3|"), "the tab says another host")
        expect(!bought.covers(web("https://checkout.shop.example/pay"), window: 7, card: "visa", turn: "3|"), "the tab can't be read now, though it could then")
        expect(bought.left(web("https://evil.example/"), window: 7) && !bought.left(pay, window: 7) && !bought.left(web("https://evil.example/"), window: 8),
               "leaving the host in that window ends it")
    }
}
