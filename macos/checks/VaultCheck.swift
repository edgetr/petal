import Foundation

// Checks the vault's pure side (Vault.swift): sites and registrable names, when Petal fills by itself (logins, API
// keys, the one Buy card for payment info, contact info and addresses), picking from a menu, the importers (Apple
// Passwords, Chrome, Proton Pass CSV and JSON, Petal's own) and exporters, password making, old items, that what
// the AI is told never holds a secret (card numbers whatever separates their digits, an unreadable vault hiding
// everything, the index made again while it changes), when a picture's check of a window is whole, and which
// addresses are the same. No Keychain, no window, no screen.

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
        selections()
        records()
        places()
        checkouts()
        unicodeCards()
        unreadableVault()
        settling()
        coverage()
        addresses()
        rechecked()
        untrusted()
        joinedPieces()
        importConflicts()
        buyRevoked()
        buyTokens()
        joinedControls()
        unsortedSecrets()
        buyReplaced()
        petalNotesKept()
        petalRestoresWhole()
        anyScriptCodes()
        oneToOne()
        oneToOneEverywhere()
        nameHeuristics()
        securityCodes()
        years()
        wideCardGaps()
        importDetails()
        cardDigits()
        joinedFocus()
        missingFrames()
        buyRevision()
        filledFields()
        protonSites()
        editorRevision()
        scanSkipsGone()
        piecesBeforeRedaction()
        nestedPages()
        importChoiceStale()
        answeredFromVault()
        paymentNoSubmit()
        monthMenus()
        selectMenus()
        identityNotes()
        protonZip()
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
        // (A card number is kept as its digits.)
        expect(merged.save.sorted { $0.id < $1.id } == items.map(Vault.normalized).sorted { $0.id < $1.id } && merged.added == items.count, "importing it into an empty vault keeps every item as it was")
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

        // Proton Pass's CSV: a card's and an identity's details as JSON in the note column; several URLs in one cell.
        let protonDetails = #"""
        type,name,url,autofillUrls,email,username,password,note,totp,createTime,modifyTime,vault
        creditCard,Visa,,,,,,"{""cardholderName"":""Ada Lovelace"",""cardType"":0,""number"":""4111111111111111"",""verificationNumber"":""737"",""expirationDate"":""2028-09"",""pin"":"""",""note"":""work card""}",,1,2,Personal
        identity,Home,,,,,,"{""fullName"":"""",""firstName"":""Deniz"",""middleName"":"""",""lastName"":""Kaya"",""email"":""deniz@example.com"",""phoneNumber"":""+90 555 000"",""streetAddress"":""Bağdat Cd. 12"",""floor"":""3"",""city"":""İstanbul"",""stateOrProvince"":"""",""zipOrPostalCode"":""34728"",""countryOrRegion"":""Türkiye"",""extraPersonalDetails"":[],""note"":""""}",,1,2,Personal
        creditCard,Broken,,,,,,{not json,,1,2,Personal
        identity,,,,,,,plain words,,1,2,Personal
        login,Shop,"https://shop.example/login, https://www.shop.example/, https://shop.example/cart,https://pay.example",,ada@example.com,,shop-pass,,,1,2,Personal
        """#
        guard let details = Vault.importCSV(protonDetails) else { return expect(false, "Proton Pass CSV with cards and identities") }
        let csvCard = details.items.first { $0.kind == .card }
        expect(csvCard?.title == "Visa" && csvCard?[.number] == "4111111111111111" && csvCard?[.name] == "Ada Lovelace"
               && csvCard?[.securityCode] == "737" && csvCard?[.expiry] == "09/28" && csvCard?[.notes] == "work card",
               "Proton Pass CSV: a card from its note's JSON")
        let csvContact = details.items.first { $0.kind == .contact }, csvAddress = details.items.first { $0.kind == .address }
        expect(csvContact?.title == "Home" && csvContact?[.name] == "Deniz Kaya" && csvContact?[.email] == "deniz@example.com"
               && csvContact?[.phone] == "+90 555 000", "Proton Pass CSV: an identity's contact info from its note's JSON")
        expect(csvAddress?[.contact] == csvContact?.id && csvAddress?[.street] == "Bağdat Cd. 12" && csvAddress?[.street2] == "3"
               && csvAddress?[.city] == "İstanbul" && csvAddress?[.postalCode] == "34728", "and its address, linked to it")
        expect(details.unreadable == ["Broken (couldn't read the card's details)", "An identity (couldn't read the identity's details)"]
               && details.skipped == 0, "rows whose details can't be read are said so, not 'nothing to keep' (got \(details.unreadable), \(details.skipped))")
        let shop = details.items.first { $0.kind == .login }
        expect(shop?.sites == ["shop.example", "www.shop.example", "pay.example"], "every URL in the cell, each site once (got \(shop?.sites ?? []))")
        expect(VaultSite.hosts("https://a.example/?q=1,2") == ["a.example"], "a comma inside one address adds no site")

        let protonJSON = #"""
        {"version":"1.21","encrypted":false,"vaults":{"s1":{"name":"Personal","items":[
          {"state":1,"data":{"type":"login","metadata":{"name":"GitHub","note":"n"},"content":{"itemEmail":"a@b.com","itemUsername":"ada","password":"gh-pass","urls":["https://github.com/login","https://github.com/"],"totpUri":"otpauth://totp/x?secret=AAAA"}}},
          {"state":1,"data":{"type":"creditCard","metadata":{"name":"Visa"},"content":{"cardholderName":"Ada","number":"4242424242424242","verificationNumber":"123","expirationDate":"2027-04"}}},
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

        // Merging: a login with another password from another app's export is a conflict (kept as saved, the import's
        // offered); the same one changes nothing; an imported address whose contact is already saved is linked to the
        // saved one.
        var saved = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"])
        saved[.username] = "ADA"
        saved[.password] = "old"
        var same = VaultItem(kind: .login, title: "Bank", sites: ["www.bank.com.tr"])
        same[.username] = "ada@example.com"
        same[.password] = "p,w\"q"
        let merged = Vault.merge(existing: [saved, same], incoming: parsed.items)
        expect(merged.added == 0 && merged.same == 1 && merged.updated.isEmpty && merged.save.isEmpty, "merge: one different password kept, one the same")
        expect(merged.conflicts.count == 1 && merged.conflicts[0].id == saved.id && merged.conflicts[0][.password] == "pa55-word"
               && merged.conflicts[0].username == "ADA", "the conflict offers the import's password on the saved login's id")
        // The same login with another site too: the site is added to the saved one, not dropped as already here.
        var wider = saved
        wider.id = "imported"
        wider.sites = ["github.com", "gist.github.com"]
        wider.apps = ["com.github.GitHubClient"]
        let widened = Vault.merge(existing: [saved], incoming: [wider])
        expect(widened.same == 0 && widened.widened == 1 && widened.updated.isEmpty && widened.conflicts.isEmpty
               && widened.save.count == 1 && widened.save[0].id == saved.id
               && widened.save[0].sites == ["github.com", "gist.github.com"] && widened.save[0].apps == ["com.github.GitHubClient"]
               && widened.save[0].appSigners.isEmpty, "an imported login's extra site and app are added to the saved one")
        let again = Vault.merge(existing: widened.save, incoming: [wider])
        expect(again.same == 1 && again.save.isEmpty && again.widened == 0, "and then it's already here")
        var www = wider
        www.sites = ["https://www.github.com/login"]
        www.apps = []
        let noMore = Vault.merge(existing: [saved], incoming: [www])
        expect(noMore.same == 1 && noMore.widened == 0, "the same site written another way adds nothing")
        var renamed = wider
        renamed.title = "GitHub work"
        let both = Vault.merge(existing: [saved], incoming: [renamed])
        expect(both.widened == 1 && both.save.first?.sites.count == 2 && both.conflicts.count == 1
               && both.conflicts[0].title == "GitHub work" && both.conflicts[0].sites.count == 2,
               "another title is still offered as a conflict, the sites added")
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
        expect(items[0].kind == .unsorted && items[0].title == "OpenAI key" && items[0][.value] == "sk-hunter22", "a name and secret become unsorted")
        expect(items[1].title == "Secret", "a nameless one gets a title")
        expect(Vault.find(items, "openai KEY")?.id == items[0].id, "found by its old name")
        let old = #"{"id":"abc","kind":"login","title":"T"}"#
        expect((try? JSONDecoder().decode(VaultItem.self, from: Data(old.utf8)))?.title == "T", "lenient decoding")
        let unknown = #"{"id":"abc","kind":"passkey","title":"T","fields":{"value":"x"}}"#
        expect((try? JSONDecoder().decode(VaultItem.self, from: Data(unknown.utf8)))?.kind == .unsorted, "a kind this Petal doesn't know is unsorted, never an API key")
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
        expect(Vault.migrate([("item:work", "sk-legacy-123")]).first.map { $0.title == "item:work" && $0.kind == .unsorted } == true, "it becomes unsorted under its name")

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

    /// A Buy covers its exact host and page, window, tab, card and reply only; its window seen on anything else ends it.
    static func checkouts() {
        let tabA = NSObject(), tabB = NSObject()
        func web(_ frame: String, tab: String? = nil, page: AnyObject? = tabA, id: String? = "11", top: String? = nil) -> Vault.Place {
            Vault.Place(web: true, frameURL: frame, topURL: top ?? frame, tabURL: tab, tab: Vault.Tab(id: id, page: page),
                        bundle: "com.google.Chrome", appName: "Chrome", signed: true)
        }
        let pay = web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay")
        guard let bought = Vault.Checkout(place: pay, window: 7, card: "visa", turn: "3|") else { return expect(false, "a Buy for a page Petal read") }
        expect(bought.host == "checkout.shop.example" && bought.path == "/pay" && bought.tab.id == "11", "bound to its host, path and tab")
        expect(Vault.Checkout(place: web("https://checkout.shop.example/pay", page: nil), window: 7, card: "visa", turn: "3|") == nil,
               "no Buy for a page whose tab Petal couldn't read")
        expect(bought.covers(pay, window: 7, card: "visa", turn: "3|"), "the same checkout")
        expect(bought.covers(web("https://checkout.shop.example/pay?step=2#card", tab: "https://checkout.shop.example/pay?step=2"), window: 7, card: "visa", turn: "3|"),
               "the same page with another query")
        expect(bought.covers(web("https://js.stripe.com/frame", tab: "https://checkout.shop.example/pay", top: "https://checkout.shop.example/pay"), window: 7, card: "visa", turn: "3|"),
               "a payment company's frame on that page")
        expect(!bought.covers(web("https://checkout.shop.example/confirm", tab: "https://checkout.shop.example/confirm"), window: 7, card: "visa", turn: "3|"),
               "another page of the same shop asks again")
        expect(!bought.covers(web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay", id: "12"), window: 7, card: "visa", turn: "3|"),
               "another tab of the same shop in that window (the browser's id)")
        expect(!bought.covers(web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay", page: tabB), window: 7, card: "visa", turn: "3|"),
               "another tab, or the page loaded again (another page element)")
        expect(!bought.covers(web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay", id: nil), window: 7, card: "visa", turn: "3|"),
               "the browser's id for the tab can't be read now, though it could then")
        expect(!bought.covers(web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay", page: nil), window: 7, card: "visa", turn: "3|"),
               "the page can't be read now")
        expect(!bought.covers(web("https://other.shop.example/pay", tab: "https://other.shop.example/pay"), window: 7, card: "visa", turn: "3|"), "a subdomain asks again")
        expect(!bought.covers(web("https://evil.example/pay", tab: "https://evil.example/pay"), window: 7, card: "visa", turn: "3|"), "another shop")
        expect(!bought.covers(pay, window: 8, card: "visa", turn: "3|"), "another window")
        expect(!bought.covers(pay, window: nil, card: "visa", turn: "3|"), "a window Petal can't name")
        expect(!bought.covers(pay, window: 7, card: "amex", turn: "3|"), "another card")
        expect(!bought.covers(pay, window: 7, card: "visa", turn: "4|"), "the next reply")
        expect(!bought.covers(web("https://checkout.shop.example/pay", tab: "https://evil.example/"), window: 7, card: "visa", turn: "3|"), "the tab says another host")
        // Without an id from the browser (Firefox, or Automation not allowed), the page element is the tab.
        let firefox = web("https://checkout.shop.example/pay", id: nil)
        if let plain = Vault.Checkout(place: firefox, window: 7, card: "visa", turn: "3|") {
            expect(plain.covers(firefox, window: 7, card: "visa", turn: "3|"), "no browser id: the same page element")
            expect(!plain.covers(web("https://checkout.shop.example/pay", page: tabB, id: nil), window: 7, card: "visa", turn: "3|"), "no browser id: another page element")
        } else {
            expect(false, "a Buy without the browser's id")
        }
        expect(bought.left(web("https://evil.example/"), window: 7) && !bought.left(pay, window: 7) && !bought.left(web("https://evil.example/"), window: 8),
               "leaving the host in that window ends it")
        expect(bought.left(web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay", id: "12"), window: 7),
               "another tab seen in that window ends it, so coming back asks again")
        expect(bought.left(web("https://checkout.shop.example/cart", tab: "https://checkout.shop.example/cart"), window: 7), "another page of the shop ends it")
        // Filling re-checks the page itself right before the keys.
        expect(Vault.moved(from: pay, to: pay) == nil, "the same page fills")
        expect(Vault.moved(from: pay, to: web("https://checkout.shop.example/pay", tab: "https://checkout.shop.example/pay", page: tabB)) != nil,
               "another page element doesn't")
        let later = web("https://checkout.shop.example/done", tab: "https://checkout.shop.example/done")
        expect(Vault.moved(from: pay, to: later) == nil && Vault.moved(from: pay, to: later, samePage: true) != nil,
               "payment info also needs the same path")
    }

    /// A card number whatever separates its digits, and in other scripts' digits: hidden whole, with its separators.
    static func unicodeCards() {
        let index = UIMap.SecretIndex(sample().flatMap(Vault.secrets))
        for (text, what) in [("4111\u{00A0}1111\u{00A0}1111\u{00A0}1111", "no-break spaces"), ("4111\u{2007}1111\u{2007}1111\u{2007}1111", "figure spaces"),
                             ("4111\u{202F}1111\u{202F}1111\u{202F}1111", "narrow no-break spaces"), ("4111\u{2009}1111\u{2009}1111\u{2009}1111", "thin spaces"),
                             ("4111.1111.1111.1111", "dots"), ("4111/1111/1111/1111", "slashes"), ("4111 - 1111 - 1111 - 1111", "spaced dashes"),
                             ("4111\u{200B}1111\u{200B}1111\u{200B}1111", "zero-width spaces"), ("４１１１ １１１１ １１１１ １１１１", "full-width digits"),
                             ("4 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1", "every digit apart"), ("4111\n1111\n1111\n1111", "line breaks")] {
            expect(index.matches(text), "a card number with \(what) is caught")
            // (The sample's repeated 1111 groups may take a space next to it too.)
            let shown = index.redacted("Card: \(text) ok")
            expect(shown.hasPrefix("Card: \(UIMap.hidden)") && shown.hasSuffix("ok") && !shown.contains { UIMap.SecretIndex.digit($0) != nil },
                   "a card number with \(what) is hidden whole: \(shown)")
        }
        expect(index.matches("ends …1111 1111 1111"), "twelve of its digits are enough")
        let other = UIMap.SecretIndex(Vault.secrets(.number, "5555444433331111"))
        expect(other.matches("5555\u{00A0}·\u{00A0}4444") && !other.matches("5555 card 4444") && !other.matches("5555 (·) 4444"),
               "half a card number across a few characters is caught; across a word, or more than 3 that aren't separators, it isn't")
        expect(!index.matches("Call 4111 2222 3333") && !index.matches("4111.11"), "other numbers aren't")
        expect(!index.matches("Visa •••• 1111"), "the last four still aren't a secret")
        expect(index.redacted("Order 1234 5678, card 4111 1111 1111 1111.") == "Order 1234 5678, card \(UIMap.hidden).", "only the card number goes")
        // A full-width security code is the same code.
        expect(index.matches("CVV ７３７") && !index.matches("１７３７０"), "a security code in full-width digits")
        expect(UIMap.SecretIndex.digit("٤") == 4 && UIMap.SecretIndex.digit("x") == nil && UIMap.SecretIndex.digit("²") == nil, "digits in any script, not superscripts")
    }

    /// A card number spread out by separators of any kind and length (up to 16 between two digits) is still caught,
    /// and hidden whole; a letter, or 17 separators, breaks it.
    static func wideCardGaps() {
        let index = UIMap.SecretIndex(Vault.secrets(.number, "4532015112830366"))
        for (text, what) in [("4532    0151    1283    0366", "four spaces"), ("4532\t\t0151\t\t1283\t\t0366", "tabs"),
                             ("4532\n    0151\n    1283\n    0366", "line breaks and indents"), ("4532 . 0151 / 1283 - 0366", "spaced punctuation"),
                             ("4532 \u{200B}\u{00A0} \u{2014} 0151\u{3000}\u{3000}\u{3000}\u{3000}1283\r\n\r\n0366", "mixed invisible and wide spaces"),
                             ("4532" + String(repeating: " ", count: 16) + "0151 1283 0366", "16 spaces")] {
            expect(index.matches(text), "a card number with \(what) is caught")
            let shown = index.redacted("Card: \(text) ok")
            expect(shown == "Card: \(UIMap.hidden) ok", "a card number with \(what) is hidden whole: \(shown.debugDescription)")
        }
        let half = UIMap.SecretIndex(Vault.secrets(.number, "5555444433331111"))
        expect(half.matches("5555 \u{00A0} - 4444") && half.matches("5555        4444"), "half of one across separators")
        expect(!half.matches("5555" + String(repeating: " ", count: 17) + "4444"), "17 separators break it")
        expect(!half.matches("5555    x    4444") && !half.matches("5555 :: ** 4444"), "a letter, or more than 3 that aren't separators, break it")
        expect(UIMap.SecretIndex.separator("\u{200D}") && UIMap.SecretIndex.separator("\u{2013}") && !UIMap.SecretIndex.separator("a")
               && !UIMap.SecretIndex.separator("*"), "what counts as a separator")
    }

    /// A login from another app's file with the same secrets but another title or notes is never "already here"
    /// with its details dropped: notes join a login that has none; otherwise the import's are offered.
    static func importDetails() {
        var saved = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"])
        saved[.username] = "ada"
        saved[.password] = "pw"
        saved[.notes] = "mine"
        var renamed = saved
        renamed.id = Vault.newID()
        renamed.title = "github.com"
        renamed[.notes] = "recovery codes in the drawer"
        let merged = Vault.merge(existing: [saved], incoming: [renamed])
        expect(merged.same == 0 && merged.save.isEmpty && merged.conflicts.count == 1, "other details: kept yours, offered the import's")
        expect(merged.conflicts.first.map { $0.id == saved.id && $0.title == "github.com" && $0[.notes] == "recovery codes in the drawer" && $0[.password] == "pw" } == true,
               "the offer is the import's title and notes on the saved login")
        var bare = saved
        bare[.notes] = ""
        var noted = saved
        noted.id = Vault.newID()
        noted[.notes] = "n"
        let joined = Vault.merge(existing: [bare], incoming: [noted])
        expect(joined.save.count == 1 && joined.save[0][.notes] == "n" && joined.conflicts.isEmpty && joined.same == 0, "notes join a login that had none")
        var titled = saved
        titled.id = Vault.newID()
        titled.title = "Work GitHub"
        titled[.notes] = ""
        let named = Vault.merge(existing: [saved], incoming: [titled])
        expect(named.conflicts.first?.title == "Work GitHub" && named.conflicts.first?[.notes] == "mine" && named.same == 0, "only the title differs: offered")
        var twin = saved
        twin.id = Vault.newID()
        expect(Vault.merge(existing: [saved], incoming: [twin]).same == 1, "every field the same: already here")
        var other = renamed
        other[.password] = "new"
        let both = Vault.merge(existing: [saved], incoming: [other])
        expect(both.conflicts.count == 1 && both.conflicts[0][.password] == "new" && both.conflicts[0].title == "github.com", "another password: the import's details with it")
    }

    /// A card number and security code are typed as ASCII digits whatever they were saved as, kept so, and a field
    /// that took fewer digits than were typed isn't a fill.
    static func cardDigits() {
        var card = VaultItem(kind: .card, title: "Visa")
        card[.number] = "4532 0151 1283 0366"
        card[.securityCode] = "７３７"
        expect(Vault.text(card, .number) == "4532015112830366" && Vault.text(card, .securityCode) == "737", "typed as digits only")
        expect(Vault.typed(.number, "4532-0151\u{00A0}1283 0366") == "4532015112830366" && Vault.typed(.password, "a b") == "a b", "only card fields lose separators")
        let kept = Vault.normalized(card)
        expect(kept[.number] == "4532015112830366" && kept[.securityCode] == "737", "kept as digits")
        var odd = card
        odd[.number] = "ask the bank"
        expect(Vault.normalized(odd)[.number] == "ask the bank", "text that isn't a number stays")
        var login = VaultItem(kind: .login, title: "x")
        login[.password] = "1 2 3"
        expect(Vault.normalized(login)[.password] == "1 2 3", "only cards")
        let digits = "4532015112830366"
        expect(Vault.fits(digits, value: "4532 0151 1283 0366", count: 19) == true, "a field that groups them holds them all")
        expect(Vault.fits(digits, value: "453201511283", count: 12) == false, "a field that cut it short")
        expect(Vault.fits(digits, value: nil, count: 16) == true && Vault.fits(digits, value: nil, count: 15) == false, "a secure field by its length")
        expect(Vault.fits(digits, value: nil, count: nil) == nil, "a field that says nothing: can't tell")
        // An import with the number grouped is the card already saved.
        var grouped = card
        grouped.id = Vault.newID()
        expect(Vault.merge(existing: [kept], incoming: [grouped]).same == 1, "a grouped number is the same card")
    }

    /// A vault that can't be read hides everything rather than nothing.
    static func unreadableVault() {
        let none = UIMap.SecretIndex.unavailable
        expect(none.unreadable && !none.isEmpty, "unreadable, and not an empty vault")
        expect(none.check("hello") == .unreadable && none.matches("hello") && none.check("") == .clean, "nothing counts as checked")
        expect(none.redacted("hello") == UIMap.hidden && none.redacted("") == "", "nothing is shown")
        expect(UIMap.SecretIndex([]).check("hello") == .clean && UIMap.SecretIndex([]).isEmpty, "an empty vault hides nothing")
    }

    /// The index and what's redacted with it are made again while the vault changes under them.
    static func settling() {
        var generation = 0
        var builds = 0
        let once = UIMap.settled(generation: { generation }) { builds += 1; return builds }
        expect(once?.value == 1 && once?.generation == 0 && builds == 1, "nothing changed: built once")
        builds = 0
        // A secret Petal is about to type arrives while the first index is made: it's made again.
        let again = UIMap.settled(generation: { generation }) { () -> Int in
            builds += 1
            if builds == 1 { generation += 1 }
            return builds
        }
        expect(again?.value == 2 && again?.generation == 1, "a change meanwhile: made again, for the newer generation")
        builds = 0
        let never = UIMap.settled(attempts: 3, generation: { generation }) { () -> Int in generation += 1; builds += 1; return builds }
        expect(never == nil && builds == 3, "always changing: given up after 3, never a stale one")
    }

    /// A picture's check of a window is whole only when every part under it was read.
    static func coverage() {
        expect(UIMap.childRead(error: 0, count: 3) == .children(3) && UIMap.childRead(error: 0, count: 0) == .none, "children, or none")
        expect(UIMap.childRead(error: -25205, count: 0) == .none && UIMap.childRead(error: -25212, count: 0) == .none, "no such attribute: none")
        expect(UIMap.childRead(error: -25202, count: 0) == .gone, "the element went away")
        expect(UIMap.childRead(error: -25204, count: 0) == .unreadable && UIMap.childRead(error: -25200, count: 0) == .unreadable,
               "a busy or failing app: unreadable, never none")
        expect(!UIMap.covered(.unreadable, depth: 3, maxDepth: 80), "unreadable children: not whole")
        expect(UIMap.covered(.children(4), depth: 3, maxDepth: 80) && !UIMap.covered(.children(4), depth: 80, maxDepth: 80),
               "children past the deepest level: not whole")
        expect(UIMap.covered(.none, depth: 80, maxDepth: 80) && UIMap.covered(.gone, depth: 3, maxDepth: 80), "a leaf, or gone: whole")

        // A text that couldn't be read (not "none there") on something that shows text: covered, else not whole.
        for none: Int32 in [0, -25212, -25205, -25208] {
            expect(!UIMap.readFailed(none) && !UIMap.textUnread(role: "AXTextField", errors: [none, none]), "\(none): no text, as before")
        }
        for failing: Int32 in [-25204, -25200, -25202, -25211] {
            expect(UIMap.readFailed(failing), "\(failing): a failed read")
            for role in ["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
                expect(UIMap.textUnread(role: role, errors: [0, failing]), "\(role) whose text failed to read (\(failing)) may show a secret")
            }
            for role in ["AXButton", "AXLink", "AXCell", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
                         "AXRadioButton", "AXTab", "AXRow", "AXHeading", "AXSomethingNew"] {
                expect(UIMap.textUnread(role: role, errors: [failing]), "a \(role) whose title failed to read (\(failing)) may show a saved key")
            }
            expect(!UIMap.textUnread(role: "AXGroup", errors: [failing]) && !UIMap.textUnread(role: "AXScrollArea", errors: [failing]),
                   "a group's failed title isn't text it shows (what's under it is read)")
            expect(UIMap.textUnread(role: "", roleError: failing, errors: [failing]), "a role that couldn't be read counts as showing text")
            expect(!UIMap.textUnread(role: "", roleError: -25205, errors: [-25205]), "no role and no text: nothing unread")
        }
        // Covered by its own frame, else the nearest ancestor with one; with none, the window isn't read whole.
        var parts = UIMap.ScanParts<String>()
        let window = parts.read("window", frame: CGRect(x: 0, y: 0, width: 800, height: 600), parent: -1)
        let group = parts.read("group", frame: .zero, parent: window)
        let field = parts.read("field", frame: CGRect(x: 20, y: 40, width: 200, height: 20), parent: group)
        let label = parts.read("label", frame: .zero, parent: group)
        expect(parts.cover(field)?.element == "field" && parts.cover(label)?.element == "window", "an unread field: its frame, or what holds it")
        var bare = UIMap.ScanParts<String>()
        let top = bare.read("window", frame: .zero, parent: -1)
        expect(bare.cover(bare.read("text", frame: .zero, parent: top)) == nil, "an unread text with nothing framed around it: not read whole")
    }

    /// Two flats in one building are two addresses; the same address saved twice is one.
    static func addresses() {
        func address(_ street2: String, id: String = Vault.newID(), contact: String = "c1", street: String = "Bağdat Cd. 12", city: String = "İstanbul",
                     country: String = "Turkey") -> VaultItem {
            var item = VaultItem(id: id, kind: .address, title: "Home")
            item[.street] = street
            item[.street2] = street2
            item[.city] = city
            item[.postalCode] = "34728"
            item[.country] = country
            item[.contact] = contact
            return item
        }
        let one = address("Apartment 1"), two = address("Apartment 2")
        expect(!Vault.same(one, two), "another flat is another address")
        expect(Vault.same(one, address("apartment  1", street: "BAGDAT CD. 12", city: "Istanbul", country: "Türkiye")),
               "case, accents, spacing and the country's name aside, the same address")
        expect(!Vault.same(one, address("Apartment 1", contact: "c2")), "the same address for another person is theirs")
        expect(!Vault.same(one, address("Apartment 1", city: "Ankara")), "another city")
        let imported = Vault.merge(existing: [one], incoming: [address("Apartment 2"), address("Apartment 1")])
        expect(imported.added == 1 && imported.same == 1, "an import adds the other flat and keeps the one saved")
        // Petal's own export: its items keep their ids, and two with different ids stay two however alike.
        let a = address("Apartment 1", id: "aaaa"), b = address("Apartment 1", id: "bbbb")
        let own = Vault.merge(existing: [], incoming: [a, b], petal: true)
        expect(own.added == 2 && Set(own.save.map(\.id)) == ["aaaa", "bbbb"], "distinct ids in Petal's export stay distinct")
        let again = Vault.merge(existing: own.save, incoming: [a, b], petal: true)
        expect(again.added == 0 && again.same == 2, "importing it again adds nothing")
        let elsewhere = Vault.merge(existing: [one], incoming: [address("Apartment 1", id: "cccc")], petal: true)
        expect(elsewhere.added == 0 && elsewhere.same == 1, "Petal's export from another Mac still finds the address saved here")
    }

    /// After a request card: the completed item is decided again where its fields are, before anything is typed.
    static func rechecked() {
        let secure = Vault.Target(secure: true, text: true), text = Vault.Target(secure: false, text: true)
        let page = Vault.Place(web: true, frameURL: "https://integration.example/settings", topURL: "https://integration.example/settings",
                               bundle: "com.apple.Safari", appName: "Safari", signed: true)
        // The request card itself saw nothing wrong: the key's service would have been this page.
        let asked = Vault.request(.apiKey, [.value], targets: [text], places: [page], saved: 0)
        expect(asked.refusal == nil && asked.warning == nil, "a key requested on a page: no warning before it's typed")
        // The person typed another service for it.
        var key = VaultItem(kind: .apiKey, title: "OpenAI", sites: ["platform.openai.com"])
        key[.value] = "sk-typed-into-the-card"
        if case .ask(let title, let detail) = Vault.recheck(key, [.value], targets: [text], places: [page], warned: asked.warning) {
            expect(title.contains("integration.example") && detail.contains("platform.openai.com") && detail.contains("integration.example"),
                   "another service than the page asks, naming both: \(detail)")
        } else { expect(false, "a key typed for another service asks before it fills") }
        key.sites = ["integration.example"]
        expect(Vault.recheck(key, [.value], targets: [text], places: [page], warned: nil) == .fill, "the page's own service fills")
        // A login bound to the page it was asked on fills; one on http was warned about already, so it isn't asked again.
        var login = VaultItem(kind: .login, title: "x")
        login[.username] = "ada"; login[.password] = "pw-typed"
        Vault.bind(&login, to: page)
        expect(Vault.recheck(login, [.username, .password], targets: [text, secure], places: [page, page], warned: nil) == .fill, "a login bound to its page")
        var plain = page
        plain.frameURL = "http://integration.example/login"; plain.topURL = plain.frameURL
        let warned = Vault.request(.login, [.password], targets: [secure], places: [plain], saved: 0)
        expect(warned.warning != nil, "http is warned on the request card")
        var onHTTP = VaultItem(kind: .login, title: "x"); onHTTP[.password] = "pw"
        Vault.bind(&onHTTP, to: plain)
        expect(Vault.recheck(onHTTP, [.password], targets: [secure], places: [plain], warned: warned.warning) == .fill, "what the card said isn't asked twice")
        if case .ask = Vault.recheck(onHTTP, [.password], targets: [secure], places: [plain], warned: nil) {} else { expect(false, "unwarned http asks") }
        if case .refuse = Vault.recheck(login, [.password], targets: [text], places: [page], warned: nil) {} else { expect(false, "a password into a text field is refused") }
    }

    /// A browser Petal doesn't trust, another app's web view, or a browser's own controls: never filled by itself,
    /// never saved for the app.
    static func untrusted() {
        expect(Vault.surface(webArea: true, trusted: true, browser: true) == .web, "a trusted browser's page")
        expect(Vault.surface(webArea: true, trusted: false, browser: true) == .unverified, "a known browser that isn't trusted (Zen)")
        expect(Vault.surface(webArea: true, trusted: false, browser: false) == .unverified, "any app's web page")
        expect(Vault.surface(webArea: false, trusted: false, browser: true) == .unverified, "a browser's own controls")
        expect(Vault.surface(webArea: false, trusted: false, browser: false) == .app, "an app's own field")
        let items = sample()
        let login = items[0], key = items[6], home = items[4], card = items[5]
        let secure = Vault.Target(secure: true, text: true), text = Vault.Target(secure: false, text: true)
        let zen = Vault.Place(bundle: "app.zen-browser.zen", appName: "Zen", signed: true, team: "ZENTEAM", unverified: true,
                              claimedURL: "https://github.com/login")
        if case .ask(_, let detail) = Vault.decide(login, .password, target: secure, place: zen) {
            expect(detail.contains("github.com") && detail.contains("Zen"), "the card names the unverified address: \(detail)")
        } else { expect(false, "a login on an untrusted browser's page asks, even for its own site") }
        if case .ask = Vault.decide(key, .value, target: text, place: zen) {} else { expect(false, "a key on an untrusted browser's page asks") }
        if case .refuse = Vault.decide(card, .number, target: text, place: zen) {} else { expect(false, "no payment info there") }
        expect(Vault.decide(home, .street, target: text, place: zen) == .fill, "an address isn't a secret: it fills")
        // A login saved for the browser as an app (before) still asks; a new one is saved for nothing.
        var bound = login
        bound.sites = []; bound.apps = ["app.zen-browser.zen"]; bound.appSigners = ["app.zen-browser.zen": "ZENTEAM"]
        if case .ask = Vault.decide(bound, .password, target: secure, place: zen) {} else { expect(false, "a login bound to a browser asks") }
        var fresh = VaultItem(kind: .login, title: "x")
        Vault.bind(&fresh, to: zen)
        expect(fresh.apps.isEmpty && fresh.sites.isEmpty && fresh.appSigners.isEmpty, "never bound to a browser's bundle")
        fresh[.password] = "x"
        if let (_, why) = Vault.unasked(fresh, [.password], targets: [secure], places: [zen]) {
            expect(why.contains("Zen"), "no password is made there")
        } else { expect(false, "new_login refuses an untrusted browser") }
        // A page it can't verify that navigated after the card: nothing is filled.
        var moved = zen
        moved.claimedURL = "https://evil.example/"
        expect(Vault.moved(from: zen, to: zen) == nil && Vault.moved(from: zen, to: moved) != nil, "an unverified page that moved on")
        var app = zen
        app.unverified = false
        expect(Vault.moved(from: zen, to: app) != nil, "an unverified page is never the same place as the app")
        expect(Vault.mixed(.login, [zen, moved]) != nil, "two unverified addresses are two places")
    }

    /// A secret a window shows in pieces (a card number as four texts) is found and every piece covered.
    static func joinedPieces() {
        let index = UIMap.SecretIndex(sample().flatMap(Vault.secrets))
        func piece(_ text: String, _ parent: Int, _ order: Int, x: CGFloat, y: CGFloat = 100) -> UIMap.TextPiece {
            UIMap.TextPiece(text: text, parent: parent, order: order, frame: CGRect(x: x, y: y, width: 36, height: 16))
        }
        let groups = ["4111", "1111", "1111", "1111"]
        expect(groups.allSatisfy { !index.matches($0) }, "no group alone is a secret")
        let siblings = [piece("Card", 1, 0, x: 0, y: 60)] + groups.enumerated().map { piece($1, 2, $0, x: 40 + CGFloat($0) * 40) }
            + [piece("Expires 04/27", 2, 4, x: 220)]
        let found = UIMap.joinedSecrets(siblings, matches: index.matches) ?? []
        expect(found == Set(1...4), "four sibling groups are covered, nothing else (\(found.sorted()))")
        // Each group in its own parent, side by side on one line.
        let spans = groups.enumerated().map { piece($1, 10 + $0, 0, x: CGFloat($0) * 42) }
        expect(UIMap.joinedSecrets(spans, matches: index.matches) == Set(0...3), "groups on one line, each in its own parent")
        // Far apart on a line, in different parents: not one number.
        let apart = groups.enumerated().map { piece($1, 10 + $0, 0, x: CGFloat($0) * 400) }
        expect(UIMap.joinedSecrets(apart, matches: index.matches) == [], "far apart in different parents isn't joined")
        // Text that isn't a secret is left alone, and time running out means not checked whole.
        let plain = ["Order", "1234", "shipped"].enumerated().map { piece($1, 3, $0, x: CGFloat($0) * 40) }
        expect(UIMap.joinedSecrets(plain, matches: index.matches) == [], "ordinary words")
        expect(UIMap.joinedSecrets(siblings, matches: index.matches, going: { false }) == nil, "out of time: not whole")
        // An API key split in two.
        let key = [piece("sk-abcdefgh", 4, 0, x: 0), piece("ijklmnop", 4, 1, x: 80)]
        expect(UIMap.joinedSecrets(key, matches: index.matches) != nil, "a key in two pieces is looked at")
        let many = (0..<(UIMap.joinPieces + 1)).map { piece("w", $0, 0, x: CGFloat($0)) }
        expect(UIMap.joinedSecrets(many, matches: { _ in false }) == nil, "too many pieces: not checked whole")
    }

    /// Imports never quietly replace a secret with an older or unknown one.
    static func importConflicts() {
        let then = Date(timeIntervalSince1970: 1_700_000_000), now = Date(timeIntervalSince1970: 1_800_000_000)
        var saved = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"], updated: now)
        saved[.username] = "ada"; saved[.password] = "newer-password"
        // Petal's own older export: kept, not stamped as new.
        var old = saved
        old[.password] = "older-password"; old.updated = then
        let older = Vault.merge(existing: [saved], incoming: [old], petal: true, at: now.addingTimeInterval(60))
        expect(older.save.isEmpty && older.older == 1 && older.conflicts.isEmpty, "an older Petal export keeps yours")
        // Petal's own newer export: taken, with its own date.
        var newer = saved
        newer[.password] = "newest-password"; newer.updated = now.addingTimeInterval(10)
        let taken = Vault.merge(existing: [saved], incoming: [newer], petal: true, at: now.addingTimeInterval(60))
        expect(taken.save.count == 1 && taken.save[0][.password] == "newest-password" && taken.save[0].updated == newer.updated
               && taken.updated == ["GitHub"], "a newer Petal export replaces it, keeping its date")
        // The same date, another password: a conflict.
        var tie = saved
        tie[.password] = "tie-password"
        let tied = Vault.merge(existing: [saved], incoming: [tie], petal: true)
        expect(tied.save.isEmpty && tied.conflicts.count == 1, "the same date: a conflict")
        // Another app's export: no reliable date, so a different secret is a conflict. Two rows for one login: the
        // first meets the saved one (a conflict), the second is a login of its own (nothing in the file is lost).
        var csv1 = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"]); csv1[.username] = "ada"; csv1[.password] = "csv-one"
        var csv2 = csv1; csv2.id = Vault.newID(); csv2[.password] = "csv-two"
        let other = Vault.merge(existing: [saved], incoming: [csv1, csv2])
        expect(other.conflicts.count == 1 && other.conflicts[0].id == saved.id && other.conflicts[0][.password] == "csv-one"
               && other.added == 1 && other.save.map { $0[.password] } == ["csv-two"],
               "another app's export: kept yours, the first row offered, the second added")
        // A card's other security code and an API key's other value are conflicts too; details without a secret merge.
        var card = VaultItem(kind: .card, title: "Visa"); card[.number] = "4111111111111111"; card[.securityCode] = "737"
        var card2 = card; card2.id = Vault.newID(); card2[.securityCode] = "999"
        expect(Vault.merge(existing: [card], incoming: [card2]).conflicts.count == 1, "another security code")
        var key = VaultItem(kind: .apiKey, title: "OpenAI"); key[.value] = "sk-one-1234567"
        var key2 = key; key2.id = Vault.newID(); key2[.value] = "sk-two-1234567"
        expect(Vault.merge(existing: [key], incoming: [key2]).conflicts.count == 1, "another key")
        var card3 = card; card3.id = Vault.newID(); card3[.name] = "Ada Lovelace"
        let details = Vault.merge(existing: [card], incoming: [card3])
        expect(details.conflicts.isEmpty && details.save.count == 1 && details.save[0][.name] == "Ada Lovelace" && details.save[0][.securityCode] == "737",
               "details without another secret merge")
        var card4 = VaultItem(kind: .card, title: "Visa"); card4[.number] = "4111111111111111"
        var noCode = card4; noCode.id = Vault.newID(); noCode[.securityCode] = "123"
        expect(Vault.merge(existing: [card4], incoming: [noCode]).conflicts.isEmpty, "a secret saved for the first time isn't a conflict")
    }

    /// Buy on tab A, tab B seen in that window (a petal_ui read, an act, a title change), back on A: the Buy is over.
    static func buyRevoked() {
        let tabA = NSObject(), tabB = NSObject()
        func web(_ url: String, page: AnyObject, id: String?) -> Vault.Place {
            Vault.Place(web: true, frameURL: url, topURL: url, tabURL: url, tab: Vault.Tab(id: id, page: page), bundle: "com.google.Chrome", appName: "Chrome", signed: true)
        }
        let a = web("https://checkout.shop.example/pay", page: tabA, id: "11")
        let b = web("https://news.example/", page: tabB, id: "12")
        guard let buy = Vault.Checkout(place: a, window: 7, card: "visa", turn: "3|") else { return expect(false, "a Buy") }
        var list = [buy]
        list = Vault.Checkout.seen(list, place: a, window: 7)
        expect(list.count == 1, "the same tab seen keeps it")
        list = Vault.Checkout.seen(list, place: b, window: 8)
        expect(list.count == 1, "another window seen doesn't touch it")
        list = Vault.Checkout.seen(list, place: b, window: 7)
        expect(list.isEmpty, "tab B seen in its window ends it")
        list = Vault.Checkout.seen(list, place: a, window: 7)
        expect(list.isEmpty && !list.contains { $0.covers(a, window: 7, card: "visa", turn: "3|") }, "back on tab A doesn't bring it back")
        // What petal_ui read (its page element, the browser's id answered later): tab B's page even if the id is A's.
        let readB = web("https://checkout.shop.example/pay", page: tabB, id: "11")
        expect(Vault.Checkout.seen([buy], place: readB, window: 7).isEmpty, "another page element ends it whatever id came back")
        var none = Vault.Place(bundle: "com.google.Chrome", appName: "Chrome")
        none.web = false
        expect(Vault.Checkout.seen([buy], place: none, window: 7).isEmpty, "a read that found no page ends it")
    }

    /// A Buy's token: covering only until revoked; a Buy gone from the list, however it went, is revoked, and one kept
    /// isn't. A payment fill made under it stops as soon as it is.
    static func buyTokens() {
        let tab = NSObject()
        let pay = Vault.Place(web: true, frameURL: "https://checkout.shop.example/pay", topURL: "https://checkout.shop.example/pay",
                              tabURL: "https://checkout.shop.example/pay", tab: Vault.Tab(id: "11", page: tab),
                              bundle: "com.google.Chrome", appName: "Chrome", signed: true)
        let away = Vault.Place(web: true, frameURL: "https://news.example/", topURL: "https://news.example/", tabURL: "https://news.example/",
                               tab: Vault.Tab(id: "12", page: NSObject()), bundle: "com.google.Chrome", appName: "Chrome", signed: true)
        guard let a = Vault.Checkout(place: pay, window: 7, card: "visa", turn: "3|"),
              let b = Vault.Checkout(place: pay, window: 9, card: "visa", turn: "3|") else { return expect(false, "two Buys") }
        expect(!a.token.revoked && a.covers(pay, window: 7, card: "visa", turn: "3|"), "a new Buy covers its page")
        expect(a.token != b.token, "each Buy has its own token")
        // Its window seen on another page: gone from the list, so revoked; the other window's Buy is kept, and valid.
        let left = Vault.Checkout.seen([a, b], place: away, window: 7)
        Vault.Checkout.revoke([a, b], keeping: left)
        expect(a.token.revoked && !a.covers(pay, window: 7, card: "visa", turn: "3|"), "the Buy that left is revoked and covers nothing")
        expect(!b.token.revoked && b.covers(pay, window: 9, card: "visa", turn: "3|"), "the other Buy stays")
        // Revoked for good: the same Buy put back (coming back to the tab) still covers nothing.
        Vault.Checkout.revoke([], keeping: [a])
        expect(a.token.revoked, "a revoked token never comes back")
        // A reply's Buys all dropped at once (the reply ended): every one revoked.
        Vault.Checkout.revoke([b], keeping: [])
        expect(b.token.revoked, "a reply's end revokes its Buys")
        // A copy of a Buy (a session's list copied) shares its token.
        guard let c = Vault.Checkout(place: pay, window: 7, card: "visa", turn: "4|") else { return expect(false, "a third Buy") }
        let copy = c
        Vault.Checkout.revoke([c], keeping: [copy])
        expect(!c.token.revoked, "the same Buy kept (as a copy) isn't revoked")
    }

    /// petal_ui: a card number shown four digits a control (four fields in a row, or four buttons on a line) is hidden
    /// in every one of them; what isn't a secret, and a single group, stays.
    static func joinedControls() {
        let index = UIMap.SecretIndex(sample().flatMap(Vault.secrets))
        func field(_ value: String, parent: Int, sibling: Int, x: CGFloat, order: Int) -> UINode {
            var node = UINode(role: "AXTextField")
            node.value = value
            node.parent = parent
            node.sibling = sibling
            node.order = order
            node.frame = CGRect(x: x, y: 200, width: 50, height: 20)
            return node
        }
        var form = UINode(role: "AXGroup")
        form.frame = CGRect(x: 0, y: 190, width: 400, height: 40)
        var label = UINode(role: "AXStaticText")
        label.title = "Card"
        label.parent = 0
        label.order = 1
        label.frame = CGRect(x: 0, y: 160, width: 40, height: 16)
        let groups = ["4111", "1111", "1111", "1111"]
        let nodes = [form, label] + groups.enumerated().map { field($1, parent: 0, sibling: $0 + 1, x: 60 + CGFloat($0) * 60, order: $0 + 2) }
        let (hid, any) = UIMap.hideJoined(nodes, matches: index.matches)
        expect(any && hid[2...5].allSatisfy { $0.value == UIMap.hidden }, "each of four fields holding a card number's groups is hidden")
        expect(hid[1].title == "Card" && hid[0] == nodes[0], "the label and the form are left alone")
        // Each group a button in its own parent, side by side on a line.
        let buttons = groups.enumerated().map { pair -> UINode in
            var node = UINode(role: "AXButton")
            node.title = pair.element
            node.parent = 10 + pair.offset
            node.order = pair.offset
            node.frame = CGRect(x: CGFloat(pair.offset) * 44, y: 300, width: 40, height: 20)
            return node
        }
        let (shown, hidButtons) = UIMap.hideJoined(buttons, matches: index.matches)
        expect(hidButtons && shown.allSatisfy { $0.title == UIMap.hidden }, "four buttons on one line showing it are each hidden")
        // Not a secret: an order number and a phone number in pieces stay.
        let plain = ["Order", "1234", "5678"].enumerated().map { field($1, parent: 0, sibling: $0, x: CGFloat($0) * 60, order: $0) }
        let (same, none) = UIMap.hideJoined(plain, matches: index.matches)
        expect(!none && same == plain, "ordinary pieces stay")
        // Out of time: only what holds a secret by itself is hidden; ordinary digits stay.
        let (late, lateAny) = UIMap.hideJoined(plain, matches: index.matches, going: { false })
        expect(!lateAny && late == plain, "not checked whole: ordinary pieces with digits stay")
        // A password field's value is never a piece (and never read).
        var secure = field("4111", parent: 0, sibling: 0, x: 0, order: 0)
        secure.subrole = "AXSecureTextField"
        let mixed = [secure, field("1111", parent: 0, sibling: 1, x: 60, order: 1)]
        expect(!UIMap.hideJoined(mixed, matches: index.matches).hid, "a password field isn't a piece")
        // The digits in a control's title as well as its value: every text of a matched piece is hidden, and so is
        // its name; a control whose value was already hidden still counts by its title.
        var both = nodes
        for at in 2...5 { both[at].title = both[at].value; both[at].help = "Group " + both[at].value }
        both[3].value = UIMap.hidden
        let (all, allAny) = UIMap.hideJoined(both, matches: index.matches)
        expect(allAny && all[2...5].allSatisfy { node in
            [node.value, node.title, node.help].allSatisfy { $0 == UIMap.hidden } && UIMap.name(node) == UIMap.hidden
        }, "a joined piece hides its value, title, help and name")
        expect(all[1].title == "Card", "its label stays")
    }

    /// Copying, or petal_look's selection, in one of four fields that show a card number together is refused: each
    /// field alone holds no secret. In a window that couldn't be read whole, what's selected counts only when it holds
    /// a secret by itself.
    static func joinedFocus() {
        let index = UIMap.SecretIndex(sample().flatMap(Vault.secrets))
        let nodes = ["Card", "4111", "1111", "1111", "1111", "Order 1234"].enumerated().map { pair -> UINode in
            var node = UINode(role: "AXTextField")
            node.value = pair.element
            node.parent = pair.offset == 5 ? 9 : 0
            node.sibling = pair.offset
            node.order = pair.offset
            node.frame = CGRect(x: CGFloat(pair.offset) * 60, y: pair.offset == 5 ? 400 : 200, width: 50, height: 20)
            return node
        }
        let (hidden, whole) = UIMap.joinedHidden(nodes, matches: index.matches)
        expect(whole && hidden == [1, 2, 3, 4], "the four groups are the joined secret's pieces")
        let pieces = hidden.sorted().map { nodes[$0].value }
        func copied(_ focus: Set<Int>, around: Set<Int> = [0], complete: Bool = true, _ selected: String, in vault: UIMap.SecretIndex? = nil) -> Bool {
            let vault = vault ?? index
            return UIMap.focusInJoined(focus: focus, hidden: hidden, around: around, pieces: pieces, complete: complete,
                                       selected: [selected], matches: vault.matches)
        }
        for at in 1...4 {
            expect(copied([at], nodes[at].value), "piece \(at) isn't copied or told selected")
        }
        expect(!copied([0], around: [], "Card"), "the label next to it is")
        expect(!copied([5], "Order 1234"), "a field elsewhere with digits is")
        // What has the keyboard holds the pieces (a page's web area showing a card in four spans): what's selected in
        // it isn't told or copied when it's in them, a piece at a time, across two, or with words around it.
        expect(copied([0], "4111"), "a container's selection that is one piece is hidden")
        expect(copied([0], "11 11"), "across two pieces")
        expect(copied([0], "Card: 4111,"), "with words and punctuation around it")
        expect(copied([0], "1"), "even one digit of it")
        expect(!copied([0], "Total"), "words that aren't in the pieces are fine")
        expect(!copied([0], "Order 2026"), "nor digits that aren't")
        expect(!copied([0], around: [], "4111"), "a control that doesn't hold the pieces isn't checked against them")
        // With the pieces found whole, a control not found in the read is still checked against them.
        expect(copied([], around: [], "1111 1"), "not found in the read: a piece the window shows counts")
        expect(!copied([], around: [], "Order 2026"), "not found: an order number is fine")
        // Not read whole (no pieces to compare with: they're given only when checked whole): what's selected counts
        // only when it holds a secret by the redaction's own rules, never because a saved secret contains it.
        func late(_ selected: String, focus: Set<Int> = [5], in vault: UIMap.SecretIndex? = nil) -> Bool {
            UIMap.focusInJoined(focus: focus, hidden: [], complete: false, selected: [selected], matches: (vault ?? index).matches)
        }
        for ordinary in ["the", "1", "11", "a", "Hello there", "9058", "4111", "1111", "sk-a", "Order 2026", "73"] {
            expect(!late(ordinary) && !late(ordinary, focus: []), "not read whole: \"\(ordinary)\" is selected and copied as usual")
        }
        expect(late("4111 1111 1111 1111") && late("4111111111111111") && late("card: 4111-1111-1111-1111 exp"),
               "not read whole: the saved card number is still refused, across separators")
        expect(late("737") && late("CVV: 737") && !late("17370"), "a saved security code standing alone is, not inside a longer number")
        expect(late("sk-abcdefghijklmnop") && late("key sk-abcdefgh"), "a saved key, or a run of one, is")
        expect(!late("4111", in: UIMap.SecretIndex([])), "an empty vault never refuses on this ground")
        expect(late("4111", in: UIMap.SecretIndex.unavailable), "a vault that can't be read may hold anything")
        // Static text (a web page's span) shows its text only as its value: it counts as a piece.
        let spans = ["4111", "1111", "1111", "1111"].enumerated().map { pair -> UINode in
            var node = UINode(role: "AXStaticText")
            node.value = pair.element
            node.parent = 0
            node.sibling = pair.offset
            node.order = pair.offset + 1
            node.frame = CGRect(x: CGFloat(pair.offset) * 44, y: 100, width: 40, height: 20)
            return node
        }
        let page = [UINode(role: "AXWebArea")] + spans
        expect(UIMap.joinedHidden(page, matches: index.matches).hidden == [1, 2, 3, 4], "four static texts showing a card are its pieces")
        // Out of time with an empty vault: nothing is hidden as a piece; with the card, only its parts are.
        let plain = ["Order", "9058", "4111"].enumerated().map { pair -> UINode in
            var node = UINode(role: "AXTextField")
            node.value = pair.element
            node.parent = 0
            node.sibling = pair.offset
            node.order = pair.offset
            return node
        }
        let empty = UIMap.SecretIndex([])
        let lateEmpty = UIMap.joinedHidden(plain, matches: empty.matches, going: { false })
        expect(!lateEmpty.whole && lateEmpty.hidden.isEmpty, "not checked whole, empty vault: nothing hidden")
        let lateCard = UIMap.joinedHidden(plain, matches: index.matches, going: { false })
        expect(lateCard.hidden.isEmpty, "not checked whole: a few digits a saved card also has aren't hidden")
        var withCode = plain
        var code = UINode(role: "AXTextField")
        code.value = "CVV 737"
        code.order = 3
        code.sibling = 3
        withCode.append(code)
        expect(UIMap.joinedHidden(withCode, matches: index.matches, going: { false }).hidden == [3],
               "not checked whole: a text holding a secret by itself is")
        // hideJoined hides exactly what joinedHidden finds.
        let (shown, any) = UIMap.hideJoined(nodes, matches: index.matches)
        expect(any && (1...4).allSatisfy { shown[$0].value == UIMap.hidden } && shown[5].value == "Order 1234", "hideJoined agrees")
    }

    /// A part of a picture that may show a secret but has no bounds of its own is covered by the nearest part holding
    /// it that has some; when none has, the window isn't read whole.
    static func missingFrames() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let group = CGRect(x: 10, y: 10, width: 200, height: 40)
        // 0 the window, 1 a group, 2 a field in it with no size, 3 a field with its own frame, 4 under 2 (no frame either).
        let frames = [window, group, .zero, CGRect(x: 20, y: 60, width: 100, height: 20), CGRect(x: 30, y: 30, width: 0, height: 10)]
        let parents = [-1, 0, 1, 0, 2]
        expect(UIMap.cover(frames: frames, parents: parents, at: 3) == 3, "a part with bounds covers itself")
        expect(UIMap.cover(frames: frames, parents: parents, at: 2) == 1, "a part with no bounds: its group is covered")
        expect(UIMap.cover(frames: frames, parents: parents, at: 4) == 1, "two levels without bounds: the nearest that has some")
        let bare: [CGRect] = [.zero, .zero, .zero]
        expect(UIMap.cover(frames: bare, parents: [-1, 0, 1], at: 2) == nil, "nothing around it has bounds: not read whole")
        expect(UIMap.cover(frames: [.zero, .zero], parents: [1, 0], at: 0) == nil, "a loop of parents ends")
    }

    /// A fill planned (or a Buy said) for an item covers only that version of it: edited meanwhile, nothing fills.
    static func buyRevision() {
        guard let card = sample().first(where: { $0.kind == .card }) else { return expect(false, "a sample card") }
        let shown = Vault.revision(card)
        expect(Vault.sameRevision(shown, card) && Vault.revision(card) == shown, "the same item, the same version")
        var edited = card
        edited[.number] = "5555 5555 5555 4444"
        expect(!Vault.sameRevision(shown, edited), "another number: another version")
        var resaved = card
        resaved.updated = card.updated.addingTimeInterval(1)
        expect(!Vault.sameRevision(shown, resaved), "saved again: another version")
        var renamed = card
        renamed.title = card.title + " (old)"
        expect(Vault.sameRevision(shown, renamed), "only its name changed in memory: the same version")
        expect(Vault.sameRevision(nil, edited), "what the person typed on the card has no version to match")
        let tabA = NSObject()
        let pay = Vault.Place(web: true, frameURL: "https://shop.example/pay", topURL: "https://shop.example/pay", tabURL: "https://shop.example/pay",
                              tab: Vault.Tab(id: "1", page: tabA), bundle: "com.google.Chrome", appName: "Chrome", signed: true)
        guard let bought = Vault.Checkout(place: pay, window: 7, card: card.id, revision: shown, turn: "3|") else { return expect(false, "a Buy") }
        expect(bought.covers(pay, window: 7, card: card.id, revision: shown, turn: "3|"), "the card as shown on the Buy card fills")
        expect(!bought.covers(pay, window: 7, card: card.id, revision: Vault.revision(edited), turn: "3|"), "the card edited since doesn't")
    }

    /// petal_look's selection in a field holding a secret isn't told, whatever is selected; elsewhere it is.
    static func selections() {
        var number = UINode(role: "AXTextField")
        number.label = "Card number"
        var code = UINode(role: "AXTextField")
        code.placeholder = "CVC"
        let password = UINode(role: "AXTextField", subrole: "AXSecureTextField")
        var plain = UINode(role: "AXTextField")
        plain.title = "Notes"
        var heading = UINode(role: "AXStaticText")
        heading.title = "Card number"
        let saved = UIMap.SecretIndex(["sk-live-9f8e7d6c5b4a3210"])
        func hidden(_ node: UINode, filled: Bool = false) -> Bool { UIMap.selectionHidden(in: node, filled: filled, secret: saved.matches) }
        expect(hidden(number) && hidden(code) && hidden(password), "a card number, code or password field's selection isn't told")
        expect(hidden(plain, filled: true), "nor one in a field Petal filled with a secret")
        expect(!hidden(plain) && !hidden(heading), "an ordinary field's or a heading's is")
        // A field named nothing secret ("Value") holding a saved key: hidden, however little is selected at a time.
        var generic = UINode(role: "AXTextField")
        generic.title = "Value"
        generic.value = "sk-live-9f8e7d6c5b4a3210"
        expect(hidden(generic), "a generic field holding a saved key hides its selection")
        generic.value = "export KEY=sk-live-9f8e7d6c5b4a3210 # prod"
        expect(hidden(generic), "nor when the key is part of the field's text")
        generic.value = "nothing saved here"
        expect(!hidden(generic), "a generic field holding no secret still tells its selection")
        expect(UIMap.selectionHidden(in: generic, filled: false, secret: UIMap.SecretIndex.unavailable.matches),
               "and while the vault can't be read, nothing selected is told")
        // Copy stays away from a window holding a secret, not from one with a heading named for one.
        let index = UIMap.SecretIndex(["4111111111111111"])
        var text = UINode(role: "AXStaticText")
        text.value = "Card number"
        text.title = "Card number"
        expect(!UIMap.holdsSecret(text, secret: index.matches), "a heading named Card number holds no secret")
        expect(UIMap.holdsSecret(number, secret: index.matches) && UIMap.holdsSecret(password, secret: index.matches),
               "a card number or password field does")
        var shown = UINode(role: "AXStaticText")
        shown.value = "Your card 4111 1111 1111 1111"
        expect(UIMap.holdsSecret(shown, secret: index.matches), "text showing a vault secret does, wherever it is")
    }

    /// A secret from before kinds is unsorted: the AI sees its title and "unsorted"; filling it asks everywhere, a
    /// password field on its own site or an app's text field alike, and its old name still finds it. Sorted, it's
    /// that kind (its secret where that kind keeps it, the same id) and fills by the normal rules.
    static func unsortedSecrets() {
        guard let old = Vault.migrate([("GitHub password", "hunter2-hunter2")]).first else { return expect(false, "an old secret") }
        expect(old.kind == .unsorted && old[.value] == "hunter2-hunter2", "an old name and secret become unsorted")
        expect(Vault.find([old], "github PASSWORD")?.id == old.id, "old callers still find it by its name")
        let shown = Vault.shown(old)
        expect(Set(shown.keys) == ["id", "kind", "title"] && shown["kind"] as? String == "unsorted" && shown["title"] as? String == "GitHub password",
               "the AI sees its title and unsorted, nothing more (\(shown.keys.sorted()))")
        expect(UIMap.SecretIndex(Vault.secrets(old)).matches("pw: hunter2-hunter2"), "its secret stays hidden from the AI")
        let secure = Vault.Target(secure: true, text: true), text = Vault.Target(secure: false, text: true)
        let github = Vault.Place(web: true, frameURL: "https://github.com/login", topURL: "https://github.com/login", bundle: "com.apple.Safari",
                                 appName: "Safari", signed: true)
        let local = Vault.Place(web: true, frameURL: "http://localhost:3000/", topURL: "http://localhost:3000/", bundle: "com.apple.Safari",
                                appName: "Safari", signed: true)
        let mail = Vault.Place(bundle: "com.apple.mail", appName: "Mail", signed: true, team: "apple")
        let field = Vault.field("password", kind: .unsorted)
        expect(field == .value && Vault.field("key", kind: .unsorted) == .value, "whatever the AI calls it, it's the one value")
        for (target, place, name) in [(secure, github, "a password field on github.com"), (text, mail, "Mail's compose field"),
                                      (text, local, "this Mac's page"), (secure, mail, "an app's password field")] {
            if case .ask(let title, let detail) = Vault.decide(old, .value, target: target, place: place) {
                expect(title.contains("GitHub password") && detail.contains("doesn't know what"), "\(name): the card says why")
            } else {
                expect(false, "\(name): an unsorted secret asks first")
            }
        }
        if case .refuse = Vault.decide(old, .username, target: text, place: github) {} else { expect(false, "it has no username to fill") }
        expect(Vault.mixed(.unsorted, [github, mail]) != nil, "one place at a time")
        expect(!VaultKind.made.contains(.unsorted) && VaultKind.sortable == [.login, .apiKey, .card], "nobody makes one; it's sorted into these")
        // Sorted as a login for github.com: its password, the same id, and it fills there by itself.
        var login = Vault.sort(old, as: .login)
        expect(login.id == old.id && login.kind == .login && login[.password] == "hunter2-hunter2" && login[.value].isEmpty, "sorted as a login")
        login.sites = ["github.com"]
        expect(Vault.decide(login, .password, target: secure, place: github) == .fill, "then it fills on its own site")
        if case .ask = Vault.decide(login, .password, target: secure, place: mail) {} else { expect(false, "and asks elsewhere, as any login") }
        let key = Vault.sort(old, as: .apiKey), card = Vault.sort(old, as: .card)
        expect(key.kind == .apiKey && key[.value] == "hunter2-hunter2" && card.kind == .card && card[.number] == "hunter2-hunter2",
               "an API key keeps it as its key, a card as its number")
        expect(Vault.sort(login, as: .apiKey) == login && Vault.sort(old, as: .contact) == old, "only an unsorted secret is sorted, only into those")
        // Petal's own export keeps it unsorted.
        expect(Vault.importData(Vault.exportJSON([old]))?.items.first?.kind == .unsorted, "a backup keeps it unsorted")
    }

    /// Buy said for card A, then a Buy card for card B on the same checkout: A's Buy ends before the person answers,
    /// so a Don't (or no answer) leaves no Buy at all. Another window's Buy stays.
    static func buyReplaced() {
        let tab = NSObject()
        let pay = Vault.Place(web: true, frameURL: "https://checkout.shop.example/pay", topURL: "https://checkout.shop.example/pay",
                              tabURL: "https://checkout.shop.example/pay", tab: Vault.Tab(id: "11", page: tab),
                              bundle: "com.google.Chrome", appName: "Chrome", signed: true)
        guard let a = Vault.Checkout(place: pay, window: 7, card: "card-a", turn: "3|"),
              let other = Vault.Checkout(place: pay, window: 9, card: "card-a", turn: "3|") else { return expect(false, "two Buys") }
        let before = [a, other]
        let after = Vault.Checkout.asking(before, window: 7)
        Vault.Checkout.revoke(before, keeping: after)
        expect(after.count == 1 && after[0].window == 9, "a new Buy card for window 7 ends the Buy in it")
        expect(a.token.revoked && !a.covers(pay, window: 7, card: "card-a", turn: "3|"), "card A's Buy covers nothing once card B's is asked")
        expect(!other.token.revoked && other.covers(pay, window: 9, card: "card-a", turn: "3|"), "another window's Buy stays")
    }

    /// Petal's export with two items alike (the same site, username and password) but other notes: each keeps its
    /// own record; "already there" only for one with every field the same as a saved item no other entry took.
    static func petalNotesKept() {
        let then = Date(timeIntervalSince1970: 1_700_000_000), now = Date(timeIntervalSince1970: 1_800_000_000)
        func login(_ notes: String, updated: Date) -> VaultItem {
            var item = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"], updated: updated)
            item[.username] = "ada"; item[.password] = "same-password"; item[.notes] = notes
            return item
        }
        let saved = login("work", updated: then)
        let work = login("work", updated: now), personal = login("personal", updated: now)
        let merged = Vault.merge(existing: [saved], incoming: [work, personal], petal: true, at: now)
        expect(merged.same == 1 && merged.added == 1 && merged.save.count == 1 && merged.save[0].id == personal.id && merged.save[0][.notes] == "personal",
               "the one alike in every field is already there, the other is added with its own notes")
        // The other way round: the first takes the saved item (newer, so its notes), the second is added.
        let reversed = Vault.merge(existing: [saved], incoming: [personal, work], petal: true, at: now)
        var vault = [saved]
        for item in reversed.save { if let at = vault.firstIndex(where: { $0.id == item.id }) { vault[at] = item } else { vault.append(item) } }
        expect(Set(vault.map { $0[.notes] }) == ["work", "personal"] && vault.count == 2, "every note is kept (\(vault.map { $0[.notes] }))")
        // Alike but with other notes isn't "already there".
        let alone = Vault.merge(existing: [saved], incoming: [personal], petal: true, at: now)
        expect(alone.same == 0 && alone.save.first?[.notes] == "personal", "other notes aren't the same thing again")
        // Another app's file: the very same row twice is still one.
        var row = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"]); row[.username] = "ada"; row[.password] = "same-password"; row[.notes] = "work"
        var again = row; again.id = Vault.newID()
        let csv = Vault.merge(existing: [saved], incoming: [row, again])
        expect(csv.same == 2 && csv.added == 0, "another app's same row twice matches the saved one once and repeats")
    }

    /// Petal's own backup of an item (the same id), newer than what's saved: all of it comes back (username,
    /// password, title, sites, notes), not just its password. A login only alike (another id) still changes only
    /// its password (and notes), and gains the sites it didn't have.
    static func petalRestoresWhole() {
        let then = Date(timeIntervalSince1970: 1_700_000_000), now = Date(timeIntervalSince1970: 1_800_000_000)
        var saved = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"], updated: then)
        saved[.username] = "ada"; saved[.password] = "old"; saved[.notes] = "n1"
        var backup = saved
        backup.title = "GitHub (work)"; backup.sites = ["github.com", "gist.github.com"]; backup.updated = now
        backup[.username] = "ada.lovelace"; backup[.password] = "new"; backup[.notes] = "n2"
        let restored = Vault.merge(existing: [saved], incoming: [backup], petal: true, at: now)
        expect(restored.save == [backup] && restored.updated == ["GitHub (work)"], "the whole item comes back as backed up")
        var older = backup; older.updated = then.addingTimeInterval(-10)
        let kept = Vault.merge(existing: [saved], incoming: [older], petal: true, at: now)
        expect(kept.save.isEmpty && kept.older == 1, "an older backup of it changes nothing")
        var tie = backup; tie.updated = then
        let tied = Vault.merge(existing: [saved], incoming: [tie], petal: true, at: now)
        expect(tied.save.isEmpty && tied.conflicts == [tie], "the same date, another password: the whole backup is offered")
        // Matched only by site and username (another id): the narrower rule.
        var alike = backup; alike.id = Vault.newID(); alike[.username] = "ada"
        let inferred = Vault.merge(existing: [saved], incoming: [alike], petal: true, at: now)
        expect(inferred.save.count == 1 && inferred.save[0].id == saved.id && inferred.save[0].title == "GitHub"
               && inferred.save[0].sites == ["github.com", "gist.github.com"] && inferred.save[0][.password] == "new"
               && inferred.save[0][.notes] == "n2" && inferred.widened == 1, "alike by site and username: its password, newer notes and added site")
    }

    /// A 3- or 4-digit secret in any script's digits is found in any script's digits, and what's hidden is the
    /// whole of what the text shows.
    static func anyScriptCodes() {
        let wide = UIMap.SecretIndex(["１２３"])
        expect(wide.matches("CVV: 123") && wide.matches("CVV: １２３") && wide.matches("CVV ١٢٣"), "a code saved in full-width digits, in any digits")
        expect(!wide.matches("1234") && !wide.matches("１２３４") && !wide.matches("Order ٠١٢٣"), "not inside a longer number")
        expect(wide.redacted("CVV: １２３!") == "CVV: \(UIMap.hidden)!" && wide.redacted("cvc 123.") == "cvc \(UIMap.hidden).", "the whole code is hidden, as the text shows it")
        let ascii = UIMap.SecretIndex(["4567"])
        expect(ascii.redacted("PIN ٤٥٦٧ ok") == "PIN \(UIMap.hidden) ok" && ascii.matches("PIN４５６７"), "an ASCII code shown in other digits")
        var card = VaultItem(kind: .card, title: "Visa"); card[.number] = "4111111111111111"; card[.securityCode] = "７３７"
        expect(UIMap.SecretIndex(Vault.secrets(card)).matches("cvc 737"), "a card's full-width security code")
    }

    /// Petal's own export with two items alike (the same site and username) and ids the vault doesn't have: one may
    /// update the saved item that matches, the other is added; neither is lost.
    static func oneToOne() {
        let then = Date(timeIntervalSince1970: 1_700_000_000), now = Date(timeIntervalSince1970: 1_800_000_000)
        var saved = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"], updated: then)
        saved[.username] = "ada"; saved[.password] = "saved-password"
        var first = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"], updated: now)
        first[.username] = "ada"; first[.password] = "first-password"
        var second = VaultItem(kind: .login, title: "GitHub work", sites: ["github.com"], updated: now)
        second[.username] = "ada"; second[.password] = "second-password"
        expect(first.id != second.id && first.id != saved.id, "three ids")
        let merged = Vault.merge(existing: [saved], incoming: [first, second], petal: true, at: now)
        let passwords = Set(merged.save.map { $0[.password] })
        expect(merged.added == 1 && merged.save.count == 2 && passwords == ["first-password", "second-password"],
               "one updates the saved item, the other is added (\(merged.save.map(\.title)))")
        expect(merged.save.first { $0.id == saved.id }?[.password] == "first-password", "the first to match takes the saved item")
        expect(merged.save.contains { $0.id == second.id }, "the second keeps its own id")
        // The same Petal id twice in a file still lands on one item (a later entry wins).
        var again = first
        again[.password] = "first-again"; again.updated = now.addingTimeInterval(5)
        let twice = Vault.merge(existing: [saved], incoming: [first, again], petal: true, at: now)
        expect(twice.added == 0 && twice.save.count == 1 && twice.save[0][.password] == "first-again", "one Petal id twice is one item")
        // Another app's export has no ids to keep apart: its rows for one login still meet on it.
        var csv1 = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"]); csv1[.username] = "ada"; csv1[.password] = "saved-password"
        var csv2 = csv1; csv2.id = Vault.newID()
        let csv = Vault.merge(existing: [saved], incoming: [csv1, csv2])
        expect(csv.added == 0 && csv.same == 2, "another app's rows still match the saved login")
    }

    /// Every export is matched one to one: three CSV rows for one site and username, with three passwords, keep all
    /// three (one a conflict on the saved login, two added); the very same row again is already there.
    static func oneToOneEverywhere() {
        var saved = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"])
        saved[.username] = "ada"; saved[.password] = "saved"
        func row(_ password: String) -> VaultItem {
            var item = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"]); item[.username] = "ada"; item[.password] = password
            return item
        }
        let three = Vault.merge(existing: [saved], incoming: [row("one"), row("two"), row("three")])
        let kept = Set(three.conflicts.map { $0[.password] } + three.save.map { $0[.password] })
        expect(kept == ["one", "two", "three"], "every password in the file is kept (\(kept))")
        expect(three.conflicts.count == 1 && three.conflicts[0].id == saved.id && three.conflicts[0][.password] == "one",
               "the first row is the saved login's conflict")
        expect(three.added == 2 && three.save.count == 2 && !three.save.contains { $0.id == saved.id }, "the other two are added")
        // Into an empty vault: three logins.
        let fresh = Vault.merge(existing: [], incoming: [row("one"), row("two"), row("three")])
        expect(fresh.added == 3 && fresh.same == 0, "three rows, three logins, into an empty vault")
        // The same row twice (another id) is already there; so is a row the vault has, and a repeat of a conflict.
        let dup = Vault.merge(existing: [], incoming: [row("one"), row("one")])
        expect(dup.added == 1 && dup.same == 1, "the very same row twice is one login")
        let again = Vault.merge(existing: [saved], incoming: [row("saved"), row("x"), row("x")])
        expect(again.same == 2 && again.added == 1 && again.conflicts.isEmpty,
               "a row the vault has is already there, the other added once (\(again.same), \(again.added), \(again.conflicts.count))")
        let repeated = Vault.merge(existing: [saved], incoming: [row("x"), row("x")])
        expect(repeated.same == 1 && repeated.added == 0 && repeated.conflicts.count == 1 && repeated.conflicts[0][.password] == "x",
               "a repeat of a conflict is already there")
        // Two saved logins alike: each row takes one of them, never the same one twice.
        var saved2 = saved; saved2.id = Vault.newID(); saved2[.password] = "saved-2"
        let pair = Vault.merge(existing: [saved, saved2], incoming: [row("a"), row("b")])
        expect(Set(pair.conflicts.map(\.id)) == [saved.id, saved2.id] && pair.added == 0, "two rows meet two saved logins, one each")
        // Cards and API keys too.
        var card = VaultItem(kind: .card, title: "Visa"); card[.number] = "4111111111111111"; card[.securityCode] = "737"
        func cardRow(_ code: String) -> VaultItem { var c = card; c.id = Vault.newID(); c[.securityCode] = code; return c }
        let cards = Vault.merge(existing: [card], incoming: [cardRow("111"), cardRow("222")])
        expect(cards.conflicts.count == 1 && cards.added == 1, "two cards with other codes: one conflict, one added")
        // Petal's own export keeps its old behaviour: two alike, one updates, the other is added.
        let petal = Vault.merge(existing: [], incoming: [row("p1"), row("p2")], petal: true)
        expect(petal.added == 2, "Petal's export: two ids, two items")
    }

    /// Only a field one types into is blacked out for its name; a window or page named for passwords isn't.
    static func nameHeuristics() {
        var window = UINode(role: "AXWindow"); window.title = "API keys - OpenAI API"
        expect(UIMap.looksSecret(window) && !UIMap.looksSecretField(window), "a window called API keys isn't covered whole")
        var page = UINode(role: "AXWebArea"); page.title = "Reset your password"
        expect(!UIMap.looksSecretField(page), "nor a page about passwords")
        var heading = UINode(role: "AXHeading"); heading.title = "Password"
        expect(!UIMap.looksSecretField(heading), "nor a heading")
        var field = UINode(role: "AXTextField"); field.placeholder = "API key"
        expect(UIMap.looksSecretField(field), "a text field named for a key is")
        var area = UINode(role: "AXTextArea"); area.label = "Private key"
        expect(UIMap.looksSecretField(area), "a text area")
        var combo = UINode(role: "AXComboBox"); combo.identifier = "cc-csc"
        expect(UIMap.looksSecretField(combo), "a combo box")
        var secure = UINode(role: "AXTextField"); secure.subrole = "AXSecureTextField"; secure.title = "Password"
        expect(UIMap.looksSecretField(secure), "a password field")
        var name = UINode(role: "AXTextField"); name.label = "Name"
        expect(!UIMap.looksSecretField(name), "a name field isn't")
    }

    /// A security code of 3 or 4 digits is caught wherever it isn't part of a longer number.
    static func securityCodes() {
        let index = UIMap.SecretIndex(["1234", "737"])
        expect(index.matches("CVV1234") && index.matches("cvc: 1234") && index.matches("CVV:1234;"), "a 4-digit code run into its label")
        expect(!index.matches("12345") && !index.matches("01234") && !index.matches("Order 112340"), "not inside a longer number")
        expect(index.redacted("CVV1234") == "CVV\(UIMap.hidden)", "only the code is hidden")
        expect(index.matches("cvv737") && !index.matches("17370"), "3 digits as before")
        // Short secrets that aren't 3 or 4 digits keep word boundaries.
        let words = UIMap.SecretIndex(["ab12", "73925"])
        expect(words.matches("PIN ab12") && !words.matches("xab12"), "a short word secret as a word only")
        expect(words.matches("PIN 73925") && !words.matches("A73925"), "a 5-digit secret as a word only")
    }

    /// A card's year as the field wants it: a menu's own items, or what a text field says of itself.
    static func years() {
        let menu4 = ["Year", "2025", "2026", "2027", "2028"], menu2 = ["YY", "25", "26", "27", "28"]
        expect(Vault.pickYear("04/27", from: menu4) == 3, "a 4-digit menu gets 2027")
        expect(Vault.pickYear("04/27", from: menu2) == 3, "a 2-digit menu gets 27")
        expect(Vault.pickYear("04/2027", from: menu4) == 3 && Vault.pickYear("2027-04", from: menu2) == 3, "however it's saved")
        expect(Vault.pickYear("04/31", from: menu4) == nil, "a year the menu doesn't have picks nothing")
        let f = Vault.fourDigitYear
        expect(f(.year, nil, ["YYYY"], nil) == true && f(.year, nil, ["YY"], nil) == false, "the placeholder says")
        expect(f(.expiry, nil, ["MM/YYYY"], nil) == true && f(.expiry, nil, ["MM / YY"], nil) == false && f(.expiry, nil, ["MMYY"], nil) == false, "an expiry's placeholder")
        expect(f(.expiry, nil, ["MM/AAAA"], nil) == true && f(.expiry, nil, ["MM/AA"], nil) == false, "in Spanish or French")
        expect(f(.year, nil, ["e.g. 2027"], nil) == true, "a sample year")
        expect(f(.year, nil, ["Expiry year"], 4) == true && f(.year, nil, ["Expiry year"], 2) == false, "its room")
        expect(f(.expiry, nil, [""], 7) == true && f(.expiry, nil, [""], 5) == false, "an expiry's room")
        expect(f(.year, nil, ["Expiry year"], nil) == nil, "nothing says: the default")
        expect(f(.year, "YYYY", ["YY"], 2) == true && f(.year, "YY", ["YYYY"], nil) == false, "what the AI said wins")
        expect(f(.year, nil, ["Yearly payment"], nil) == nil, "a word ending in yy isn't a format")
        let card = sample()[5]
        expect(Vault.text(card, .year) == "27" && Vault.text(card, .year, fourDigitYear: true) == "2027", "the year typed")
        expect(Vault.text(card, .expiry) == "04/27" && Vault.text(card, .expiry, fourDigitYear: true) == "04/2027"
               && Vault.text(card, .expiry, fourDigitYear: false) == "04/27", "the expiry typed")
    }

    /// A field Petal filled with a secret is hidden whatever it shows now (part of a card number left after the person
    /// cut or edited it): its value in petal_ui, what typing into it reads back, and Copy or a selection in it.
    static func filledFields() {
        let index = UIMap.SecretIndex(sample().flatMap(Vault.secrets))
        var field = UINode(role: "AXTextField")
        field.title = "Billing reference"
        for left in ["4111 11", "1111", "x", "4111 1111 1111 1111"] {
            field.value = left
            expect(UIMap.redact(field, filled: true, secret: index.matches).value == UIMap.hidden, "a filled field's \"\(left)\" is hidden")
            expect(UIMap.holdsSecret(field, filled: true, secret: index.matches), "a filled field holds a secret (Copy stays away)")
            expect(UIMap.selectionHidden(in: field, filled: true, secret: index.matches), "nothing selected in it is told")
            expect(UIMap.typedValue(left, node: field, filled: true, secret: index.matches) == UIMap.hidden, "typing into it reads back hidden")
        }
        field.value = "4111 11"
        expect(UIMap.redact(field, secret: index.matches).value == "4111 11" && !UIMap.holdsSecret(field, secret: index.matches)
               && UIMap.typedValue("4111 11", node: field, filled: false, secret: index.matches) == "4111 11",
               "the same text in a field Petal didn't fill is told as usual")
        field.value = ""
        expect(UIMap.redact(field, filled: true, secret: index.matches).value == "", "an empty filled field shows nothing to hide")
        // Its name may echo what's in it: every text of a filled field is hidden, not only its value.
        var echoing = UINode(role: "AXTextField")
        echoing.title = "Card ending 1111"
        echoing.label = "4111 11"
        echoing.help = "Shown as 4111"
        echoing.placeholder = "1111"
        echoing.value = "4111 11"
        let told = UIMap.redact(echoing, filled: true, secret: index.matches)
        expect([told.title, told.label, told.help, told.placeholder, told.value].allSatisfy { $0 == UIMap.hidden } && UIMap.name(told) == UIMap.hidden,
               "a filled field's title, description, help, placeholder and value are all hidden (\(told))")
        var secure = echoing
        secure.subrole = "AXSecureTextField"
        let secureTold = UIMap.redact(secure, filled: true, secret: index.matches)
        expect(secureTold.value == "" && secureTold.title == UIMap.hidden && secureTold.label == UIMap.hidden,
               "a filled password field: no value at all, and its name hidden")
        let unfilled = UIMap.redact(echoing, secret: index.matches)
        expect(unfilled.title == "Card ending 1111" && unfilled.label == "4111 11", "a field Petal didn't fill keeps its name")
    }

    /// Proton Pass's logins: every site with its rule (autofillUrls) and the older list (urls), in its JSON and its
    /// CSV's structured column; a rule never to fill isn't a site; a pattern Petal can't read is said so.
    static func protonSites() {
        let json = #"""
        {"version":"1.30","encrypted":false,"vaults":{"s1":{"name":"Personal","items":[
          {"state":1,"data":{"type":"login","metadata":{"name":"New","note":""},"content":{"itemUsername":"ada","password":"p1","autofillUrls":[{"url":"https://github.com/login","mode":0},{"url":"https://gist.github.com","mode":1},{"url":"https://evil.example","mode":2},{"url":"https://docs.example/a","mode":6}]}}},
          {"state":1,"data":{"type":"login","metadata":{"name":"Both","note":""},"content":{"itemUsername":"ada","password":"p2","urls":["https://old.example"],"autofillUrls":[{"url":"https://old.example","mode":0},{"url":"https://new.example","mode":3}]}}},
          {"state":1,"data":{"type":"login","metadata":{"name":"Legacy","note":""},"content":{"itemUsername":"ada","password":"p3","urls":["https://legacy.example/"]}}},
          {"state":1,"data":{"type":"login","metadata":{"name":"Pattern","note":""},"content":{"itemUsername":"ada","password":"p4","autofillUrls":[{"url":"*.corp.example","mode":4}]}}},
          {"state":1,"data":{"type":"login","metadata":{"name":"Some","note":""},"content":{"itemUsername":"ada","password":"p5","autofillUrls":[{"url":"https://some.example","mode":0},{"url":"^https://.*","mode":5}]}}},
          {"state":1,"data":{"type":"login","metadata":{"name":"Nowhere","note":""},"content":{"itemUsername":"ada","password":"p6","autofillUrls":[]}}}
        ]}}}
        """#
        guard let parsed = Vault.importData(Data(json.utf8)) else { return expect(false, "Proton Pass JSON with autofillUrls") }
        func sites(_ title: String) -> [String]? { parsed.items.first { $0.title == title }?.sites }
        expect(sites("New") == ["github.com", "gist.github.com", "docs.example"], "autofillUrls read, Never left out (got \(sites("New") ?? []))")
        expect(sites("Both") == ["old.example", "new.example"], "autofillUrls and urls both read, each site once (got \(sites("Both") ?? []))")
        expect(sites("Legacy") == ["legacy.example"], "an older item's urls still read")
        expect(sites("Pattern") == nil, "a login with only sites Petal can't read isn't imported for nowhere")
        expect(sites("Some") == ["some.example"], "one with some readable sites is imported with those")
        expect(sites("Nowhere") == [], "a login saved for no site at all is imported as before")
        expect(parsed.unreadable == ["Pattern (couldn't read its sites)", "Some (couldn't read some of its sites; added with the rest)"],
               "both said in the summary (got \(parsed.unreadable))")
        // Named modes, plain strings and anything else.
        expect(Vault.protonSites([["url": "a.example", "mode": "Exact"], ["url": "b.example", "mode": "Never"], "c.example"] as [Any]) == (["a.example", "c.example"], false),
               "modes by name and plain addresses")
        expect(Vault.protonSites([["url": "a.example", "mode": 9]] as [Any]).unread && Vault.protonSites("[not json").unread, "an unknown mode or broken JSON is unread")
        // Proton's CSV: url holds the default rule's sites, autofillUrls all of them as JSON (or, by hand, addresses).
        let autofill = #"[{""url"":""https://github.com"",""mode"":0},{""url"":""https://api.github.com"",""mode"":1}]"#
        let csv = """
        type,name,url,autofillUrls,email,username,password,note,totp,createTime,modifyTime,vault
        login,GitHub,https://github.com,"\(autofill)",,ada,gh-pass,,,1,2,Personal
        login,Listed,,"https://a.example, https://b.example",,ada,pw2,,,1,2,Personal
        login,Regex,,"[{""url"":""^x$"",""mode"":5}]",,ada,pw3,,,1,2,Personal
        """
        guard let rows = Vault.importCSV(csv) else { return expect(false, "Proton Pass CSV with autofillUrls") }
        func csvSites(_ title: String) -> [String]? { rows.items.first { $0.title == title }?.sites }
        expect(csvSites("GitHub") == ["github.com", "api.github.com"], "the CSV's autofillUrls JSON read with url (got \(csvSites("GitHub") ?? []))")
        expect(csvSites("Listed") == ["a.example", "b.example"], "comma-separated addresses in it read")
        expect(csvSites("Regex") == nil && rows.unreadable == ["Regex (couldn't read its sites)"], "a regular expression alone is said so (got \(rows.unreadable))")
    }

    /// An editor opened before an import (or any other save) doesn't save its older copy over the item.
    static func editorRevision() {
        var item = sample()[5]
        let opened = Vault.openedRevision(item)
        expect(!Vault.editConflict(opened: opened, stored: item), "unchanged: saves")
        expect(!Vault.editConflict(opened: nil, stored: item) && !Vault.editConflict(opened: nil, stored: nil), "a new item never conflicts")
        var stored = item
        stored[.securityCode] = "999"
        stored.updated = Date(timeIntervalSince1970: 1_800_000_000)
        expect(Vault.editConflict(opened: opened, stored: stored), "changed since it opened (an import): refused")
        expect(Vault.editConflict(opened: opened, stored: nil), "deleted since: refused")
        // The editor's copy as the window had it (a card number with spaces) and the stored one (its digits) agree.
        item[.number] = "4111111111111111"
        var spaced = item
        spaced[.number] = "4111 1111 1111 1111"
        expect(!Vault.editConflict(opened: Vault.openedRevision(spaced), stored: Vault.normalized(item)), "the same card written another way isn't a change")
    }

    /// A picture's check (Sensitive.scan): an element gone before it could be read gets no id, so the pieces after it
    /// still point at their own elements, and what's covered is what shows the secret, not a neighbour.
    static func scanSkipsGone() {
        let index = UIMap.SecretIndex(["378282246310005", "4111 1111 1111 1111"])
        func frame(_ x: CGFloat, y: CGFloat = 100) -> CGRect { CGRect(x: x, y: y, width: 60, height: 16) }
        // Walks a window: each entry is an element read (its name, text and frame) under `parent` (a name), or nil
        // for one gone before it could be read.
        func walk(_ steps: [(name: String, text: String, frame: CGRect, parent: String)?]) -> (UIMap.ScanParts<String>, [String]?) {
            var parts = UIMap.ScanParts<String>()
            var ids: [String: Int] = [:]
            var order: [String: Int] = [:]
            ids["window"] = parts.read("window", frame: CGRect(x: 0, y: 0, width: 800, height: 600), parent: -1)
            for step in steps {
                guard let step else { continue }   // gone meanwhile: skipped, no id
                let parent = ids[step.parent] ?? -1
                let id = parts.read(step.name, frame: step.frame, parent: parent)
                ids[step.name] = id
                let place = order[step.parent, default: 0]
                order[step.parent] = place + 1
                if !step.text.isEmpty { parts.shows(step.text, id: id, order: place) }
            }
            return (parts, parts.joined(matches: index.matches).map { $0.map { parts.elements[$0] } })
        }
        // An Amex number as 8 and 7 digits, with elements gone before, between and after.
        let (amexParts, amex) = walk([
            nil,
            ("label", "Card", frame(0, y: 60), "window"),
            nil,
            ("row", "", .zero, "window"),
            ("first", "37828224", frame(40), "row"),
            nil,
            ("second", "6310005", frame(104), "row"),
            nil,
            ("order", "Order 1234", frame(0, y: 400), "window"),
        ])
        expect(Set(amex ?? []) == ["first", "second"], "Amex in 8 and 7 digits, elements gone around it: both pieces, nothing else (\(amex ?? []))")
        expect(amexParts.elements.count == amexParts.frames.count && amexParts.elements.count == amexParts.parents.count,
               "every element read has its frame and parent")
        expect(amexParts.cover(amexParts.elements.firstIndex(of: "row") ?? -1)?.element == "window",
               "a part with no bounds is covered by what holds it, not by a neighbour")
        // A card number in fours, an element gone before each group.
        let groups = ["4111", "1111", "1111", "1111"]
        var steps: [(name: String, text: String, frame: CGRect, parent: String)?] = [("form", "", CGRect(x: 0, y: 90, width: 400, height: 40), "window")]
        for (at, group) in groups.enumerated() {
            steps.append(nil)
            steps.append(("group\(at)", group, frame(40 + CGFloat(at) * 64), "form"))
        }
        steps.append(("total", "Total 12.00", frame(0, y: 300), "window"))
        let (_, fours) = walk(steps)
        expect(Set(fours ?? []) == Set((0..<4).map { "group\($0)" }), "a card in fours, elements gone between: every group (\(fours ?? []))")
        expect(walk([("plain", "Hello", frame(0), "window"), nil, ("other", "1234", frame(70), "window")]).1 == [],
               "ordinary text with an element gone: nothing")
    }

    /// petal_ui and the picture look for a secret shown in pieces in what the controls show as read, before any of it
    /// is hidden: a piece holding part of the secret by itself (8 digits of an Amex) still finds the rest (7 digits).
    static func piecesBeforeRedaction() {
        let index = UIMap.SecretIndex(["378282246310005", "4111 1111 1111 1111"])
        func fields(_ values: [String]) -> [UINode] {
            values.enumerated().map { pair -> UINode in
                var node = UINode(role: "AXStaticText")
                node.value = pair.element
                node.parent = 0
                node.sibling = pair.offset
                node.order = pair.offset + 1
                node.frame = CGRect(x: CGFloat(pair.offset) * 70, y: 100, width: 64, height: 20)
                return node
            }
        }
        let amex = fields(["37828224", "6310005"])
        expect(index.matches("37828224") && !index.matches("6310005"), "the 8 digits hold part of the card alone, the 7 don't")
        let (hidden, whole) = UIMap.joinedHidden(amex, matches: index.matches)
        expect(whole && hidden == [0, 1], "Amex as 8 and 7 digits, as read: both pieces (\(hidden.sorted()))")
        let (shown, any) = UIMap.hideJoined(amex, matches: index.matches)
        expect(any && shown.allSatisfy { $0.value == UIMap.hidden }, "neither is told")
        // Redacted one by one first, the 7 digits would be left: the 8 are no longer a piece to join them with.
        let redacted = amex.map { UIMap.redact($0, secret: index.matches) }
        expect(redacted[0].value != amex[0].value && redacted[1].value == "6310005", "redaction alone hides only the 8")
        let fours = fields(["4111", "1111", "1111", "1111", "Order 1234"])
        let (four, fourWhole) = UIMap.joinedHidden(fours, matches: index.matches)
        expect(fourWhole && four == [0, 1, 2, 3], "a card in fours, as read: the four groups, not the order (\(four.sorted()))")
    }

    /// T3 Code shows a site's page inside its own t3code://app/ page: the site's page is the tab's page, and no
    /// app's own page (t3code://, chrome://, about:) is ever a site.
    static func nestedPages() {
        // Nearest first.
        expect(Vault.pageTop(["https://shop.example/checkout", "t3code://app/"]) == 0, "T3 Code: the site's page, not its shell")
        expect(Vault.pageTop(["https://js.stripe.com/frame", "https://shop.example/checkout", "t3code://app/"]) == 1,
               "T3 Code: a payment frame's page is the shop's, inside the shell")
        expect(Vault.pageTop(["https://js.stripe.com/frame", "https://shop.example/checkout"]) == 1, "a browser: the outermost page")
        expect(Vault.pageTop(["about:blank", "https://shop.example/checkout", "t3code://app/"]) == 1, "an about:blank frame stays in its page")
        expect(Vault.pageTop(["https://evil.example/", "data:text/html,frame"]) == 1, "a data: page around a frame is still the page (not secure)")
        expect(Vault.pageTop(["https://evil.example/", nil]) == 1, "an unread address around a frame is still the page")
        expect(Vault.pageTop(["t3code://app/"]) == 0 && Vault.pageTop([]) == 0, "a field in the app's own page")
        expect(Vault.pageTop(["https://a.example/", "chrome://new-tab-page/"]) == 0, "a browser's own page is never the page")
        for url in ["t3code://app/", "t3code://app.example.com/", "chrome://settings", "about:blank", "file:///Users/x/a.html",
                    "data:text/html,x", "edge://wallet.example.com/"] {
            expect(Vault.siteHost(url) == nil, "\(url) is no site")
        }
        expect(Vault.appPage("t3code://app/") && Vault.appPage("chrome://settings") && !Vault.appPage("about:blank")
               && !Vault.appPage("https://a.example/") && !Vault.appPage(nil), "which pages are an app's own")
        expect(Vault.siteHost("https://shop.example/x") == "shop.example" && Vault.siteHost("http://localhost:3000/") == "localhost", "web addresses are sites")

        // As a field in T3 Code reads: the site's page as the tab's page.
        func t3(_ frame: String, top: String) -> Vault.Place {
            Vault.Place(web: true, frameURL: frame, topURL: top, bundle: "com.t3tools.t3code", appName: "T3 Code", signed: true)
        }
        let checkout = t3("https://shop.example/checkout", top: "https://shop.example/checkout")
        var card = VaultItem(kind: .card, title: "Visa"); card[.number] = "4111111111111111"; card[.expiry] = "04/27"
        let text = Vault.Target(secure: false, text: true), secure = Vault.Target(secure: true, text: true)
        expect(Vault.decide(card, .number, target: text, place: checkout) == .buy(shop: "shop.example"), "T3 Code checkout: the Buy card")
        expect(Vault.decide(card, .number, target: text, place: checkout, checkout: true) == .fill, "T3 Code checkout: fills under Buy")
        var login = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"]); login[.username] = "ada"; login[.password] = "x"
        expect(Vault.decide(login, .password, target: secure, place: t3("https://github.com/login", top: "https://github.com/login")) == .fill,
               "T3 Code login: fills by itself on its site")
        // The shell itself is never a site: nothing fills by itself there.
        let shell = t3("t3code://app.github.com/", top: "t3code://app.github.com/")
        if case .fill = Vault.decide(login, .password, target: secure, place: shell) { expect(false, "the app's own page isn't github.com") }
        if case .refuse = Vault.decide(card, .number, target: text, place: shell) {} else { expect(false, "no payment info in the app's own page") }
        expect(shell.host == nil && shell.shop == nil, "the app's own page names no host")
    }

    /// "Use the imported ones" saves only conflicts whose saved item is still as the import compared it.
    static func importChoiceStale() {
        var a = VaultItem(kind: .login, title: "A", sites: ["a.example"]); a[.password] = "saved-a"
        var b = VaultItem(kind: .login, title: "B", sites: ["b.example"]); b[.password] = "saved-b"
        var c = VaultItem(kind: .login, title: "C", sites: ["c.example"]); c[.password] = "saved-c"
        var fa = a; fa[.password] = "file-a"
        var fb = b; fb[.password] = "file-b"
        var fc = c; fc[.password] = "file-c"
        let compared = [a.id: Vault.openedRevision(a)!, b.id: Vault.openedRevision(b)!, c.id: Vault.openedRevision(c)!]
        // B edited in Settings since the import, C deleted.
        var edited = b; edited[.password] = "edited-b"; edited.updated = Date().addingTimeInterval(5)
        let still = Vault.stillConflicting([fa, fb, fc], compared: compared, stored: [a, edited])
        expect(still.use.map(\.id) == [a.id] && still.skipped == 2, "an edited or deleted item isn't written over or brought back")
        let none = Vault.stillConflicting([fa], compared: [:], stored: [a])
        expect(none.use.isEmpty && none.skipped == 1, "a conflict with no compared version is skipped")
        let all = Vault.stillConflicting([fa, fb], compared: compared, stored: [a, b])
        expect(all.use.count == 2 && all.skipped == 0, "unchanged ones are used")
    }

    /// A request card's answer that was saved fills from the vault at that version; one not saved, as typed.
    static func answeredFromVault() {
        let place = Vault.Place(web: true, frameURL: "https://github.com/login", topURL: "https://github.com/login", bundle: "com.apple.Safari", appName: "Safari", signed: true)
        let secure = Vault.Target(secure: true, text: true), text = Vault.Target(secure: false, text: true)
        var saved = VaultItem(kind: .login, title: "github.com", sites: ["github.com"]); saved[.username] = "ada"; saved[.password] = "typed-secret"
        let values: [VaultField: String] = [.username: "ada", .password: "typed-secret"]
        let plans = Vault.answeredPlans(title: "github.com", fields: [.username, .password], values: values, places: [place, place],
                                        targets: [text, secure], saved: saved)
        expect(plans.count == 2 && plans.allSatisfy { $0.given == nil && $0.itemID == saved.id && $0.revision == Vault.revision(Vault.normalized(saved)) },
               "saved: each plan names the item and its version, never what was typed")
        var later = saved; later[.password] = "edited"
        expect(!Vault.sameRevision(plans[1].revision, later), "an edit while the fill waits doesn't match the plan")
        let unsaved = Vault.answeredPlans(title: "github.com", fields: [.username, .password], values: values, places: [place, place],
                                          targets: [text, secure], saved: nil)
        expect(unsaved.map(\.given) == ["ada", "typed-secret"] && unsaved.allSatisfy { $0.itemID.isEmpty && $0.revision == nil },
               "not saved: what was typed")
    }

    /// Return after payment info could place the order: refused. A login's Return asks to use the app unless the
    /// reply may use it already.
    static func paymentNoSubmit() {
        expect(Vault.submitRefusal(.card) != nil, "no Return after payment info")
        expect(Vault.submitRefusal(.login) == nil && Vault.submitRefusal(.contact) == nil, "Return after a login or a form")
        expect(Vault.fillAdmitted(allowed: true, submit: false, appAllowed: false), "a fill the person allowed types")
        expect(!Vault.fillAdmitted(allowed: true, submit: true, appAllowed: false), "Return after it asks to use the app")
        expect(Vault.fillAdmitted(allowed: false, submit: true, appAllowed: true), "the reply may use the app already")
        expect(!Vault.fillAdmitted(allowed: false, submit: false, appAllowed: false), "nothing allowed: asks")
    }

    /// An expiry month "04" picks April however the menu says it.
    static func monthMenus() {
        let short = ["Month", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        expect(Vault.pickMonth("04", from: short) == 4, "Apr from 04")
        expect(Vault.pickMonth("4", from: short) == 4, "Apr from 4")
        expect(Vault.pickMonth("09", from: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]) == 8, "Sept")
        let full = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        expect(Vault.pickMonth("04", from: full) == 3 && Vault.pickMonth("12", from: full) == 11, "full names")
        expect(Vault.pickMonth("04", from: full.map { $0.uppercased() }) == 3, "any case")
        let numbers = ["MM"] + (1...12).map { String(format: "%02d", $0) }
        expect(Vault.pickMonth("4", from: numbers) == 4 && Vault.pickMonth("04", from: (1...12).map(String.init)) == 3, "numbers")
        let both = (1...12).map { String(format: "%02d", $0) + " - " + short[$0] }
        expect(Vault.pickMonth("04", from: both) == 3, "04 - Apr")
        expect(Vault.pickMonth("05", from: (1...12).map { "\($0) (\(full[$0 - 1]))" }) == 4, "5 (May)")
        let turkish = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"]
        expect(Vault.pickMonth("04", from: turkish) == 3 && Vault.pickMonth("11", from: turkish) == 10 && Vault.pickMonth("02", from: turkish) == 1, "Turkish")
        expect(Vault.pickMonth("08", from: ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"]) == 7, "Turkish short")
        expect(Vault.pickMonth("04", from: ["Month", "Year"]) == nil, "no month: nothing picked")
        expect(Vault.pickMonth("13", from: short) == nil && Vault.pickMonth("x", from: short) == nil, "not a month")
        expect(Vault.pick("04", from: short) == 4, "pick finds a month's short name too")
        expect(Vault.pickMonth("04", from: ["2024", "2025", "2026"]) == nil, "a year menu has no month")
    }

    /// A synthetic Accessibility tree for a select's options.
    final class Node {
        let role: String
        var title = "", value = "", label = ""
        var children: [Node] = []
        init(_ role: String, title: String = "", value: String = "", _ children: [Node] = []) {
            self.role = role; self.title = title; self.value = value; self.children = children
        }
    }

    /// Chromium's select lists its options right under its pop-up button (named only by value), and opens its own
    /// menu as the app's; Safari and AppKit put them in a menu under the button.
    static func selectMenus() {
        func options(_ popup: Node, opened: Bool = false, app: [Node] = []) -> (items: [Node], inMenu: Bool) {
            Vault.selectOptions(popup, opened: opened, appMenus: app, role: { $0.role }, children: { $0.children })
        }
        func pick(_ items: [Node], _ wanted: String) -> Int? {
            Vault.pickOption(titles: items.map(\.title), values: items.map(\.value), labels: items.map(\.label)) { Vault.pick(wanted, from: $0) }
        }
        let countries = ["Germany", "Türkiye", "United States"]
        let chromium = Node("AXPopUpButton", value: "Germany", countries.map { Node("AXMenuItem", value: $0) })
        let direct = options(chromium)
        expect(direct.items.count == 3 && !direct.inMenu, "Chromium: options as direct menu items, without opening")
        expect(pick(direct.items, "Turkey") == 1, "Chromium: picked by value when it has no title")
        let appKit = Node("AXPopUpButton", title: "Country", [Node("AXMenu", countries.map { Node("AXMenuItem", title: $0) })])
        let child = options(appKit)
        expect(child.items.count == 3 && !child.inMenu && pick(child.items, "United States of America") == 2, "a menu under the button")
        let open = Node("AXMenu", ["01", "02", "03"].map { Node("AXMenuItem", title: $0) })
        let native = options(chromium, opened: true, app: [Node("AXMenuBar", [Node("AXMenuBarItem", title: "File")]), open])
        expect(native.inMenu && native.items.count == 3 && pick(native.items, "02") == 1, "opened: the app's own open menu first, never its menu bar")
        let bare = Node("AXPopUpButton", value: "Germany")
        expect(options(bare).items.isEmpty && options(bare, opened: true, app: [Node("AXMenu")]).items.isEmpty, "nothing shown: nothing to press")
        let separated = Node("AXPopUpButton", [Node("AXMenu", [Node("AXMenuItem", title: "A"), Node("AXSplitter"), Node("AXMenuItem", title: "B")])])
        expect(options(separated).items.map(\.title) == ["A", "B"], "only menu items count")
        expect(Vault.pickOption(titles: ["", ""], values: ["", ""], labels: ["Germany", "Turkey"]) { Vault.pick("Türkiye", from: $0) } == 1,
               "named only by description")
        expect(Vault.pickOption(titles: ["x", "y"], values: ["Germany", "Turkey"], labels: []) { Vault.pick("Turkey", from: $0) } == 1,
               "titles that don't match fall back to values")
    }

    /// A Proton Pass identity's note stays with its contact info, from JSON and CSV, and through Petal's own export.
    static func identityNotes() {
        let json = #"""
        {"version":"1.21","encrypted":false,"vaults":{"s1":{"name":"Personal","items":[
          {"state":1,"data":{"type":"identity","metadata":{"name":"Deniz","note":"gate code is on the fridge"},"content":{"fullName":"Deniz Kaya","email":"deniz@example.com","city":"İstanbul"}}},
          {"state":1,"data":{"type":"identity","metadata":{"name":"Only a note","note":"call after 6"},"content":{}}}
        ]}}}
        """#
        guard let parsed = Vault.importData(Data(json.utf8)) else { return expect(false, "Proton identity JSON with a note") }
        let contacts = parsed.items.filter { $0.kind == .contact }
        expect(contacts.first?[.notes] == "gate code is on the fridge", "JSON: metadata.note on the contact info")
        expect(parsed.items.first { $0.kind == .address }?[.notes] == "", "the address doesn't repeat it")
        expect(contacts.last?.title == "Only a note" && contacts.last?[.notes] == "call after 6", "an identity with only a note keeps it")
        let csv = #"""
        type,name,url,autofillUrls,email,username,password,note,totp,createTime,modifyTime,vault
        identity,Home,,,,,,"{""fullName"":""Deniz Kaya"",""email"":""deniz@example.com"",""note"":""spare key with Ayşe""}",,1,2,Personal
        """#
        let row = Vault.importCSV(csv)?.items.first { $0.kind == .contact }
        expect(row?[.notes] == "spare key with Ayşe" && row?[.email] == "deniz@example.com", "CSV: the note inside the identity's content")
        let plain = "type,name,fullName,email,note\r\nidentity,Mum,Ayşe Kaya,ayse@example.com,birthday in May\r\n"
        let mum = Vault.importCSV(plain)?.items.first
        expect(mum?.kind == .contact && mum?[.name] == "Ayşe Kaya" && mum?[.notes] == "birthday in May", "a contact row's plain note")
        if let first = contacts.first {
            let back = Vault.importData(Vault.exportJSON([first]))?.items.first
            expect(back?[.notes] == "gate code is on the fridge" && back?.kind == .contact, "Petal's export round-trips it")
        }
    }

    /// Proton Pass's zip: its data.json, never an attachment's JSON.
    static func protonZip() {
        let names = ["Proton Pass/", "Proton Pass/data.json", "Proton Pass/files/s1_i1_report.json", "Proton Pass/files/s1_i2_cfg.json"]
        expect(Vault.protonZipMember(names) == "Proton Pass/data.json", "the vault's data.json, attachments left")
        expect(Vault.protonZipMember(["data.json", "files/x.json"]) == "data.json", "one data.json at the top")
        expect(Vault.protonZipMember(["Proton Pass/data.pgp", "Proton Pass/files/a.json"]) == nil, "encrypted or attachments only: nothing")
        expect(Vault.protonZipMember(["a.json", "b.json"]) == nil && Vault.protonZipMember([]) == nil, "no data.json: nothing")
        expect(Vault.protonZipMember(["other/data.json"]) == nil, "a data.json elsewhere isn't the vault")
    }
}
