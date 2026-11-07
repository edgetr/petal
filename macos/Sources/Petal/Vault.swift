import Foundation

/// The vault's pure side: its items, what Petal AI is told of them, which sites and apps an item belongs to, reading
/// and writing exports, making passwords, and when Petal fills something by itself. Nothing here touches the
/// Keychain, Accessibility or the screen (VaultStore.swift and VaultFill.swift do), so `macos/checks/run.sh` checks it.

enum VaultKind: String, Codable, CaseIterable, Identifiable {
    case login, contact, address, card, apiKey
    var id: String { rawValue }

    var name: String {
        switch self {
        case .login: "Login"
        case .contact: "Contact info"
        case .address: "Address"
        case .card: "Payment info"
        case .apiKey: "API key"
        }
    }

    var plural: String {
        switch self {
        case .login: "Logins"
        case .contact: "Contact info"
        case .address: "Addresses"
        case .card: "Payment info"
        case .apiKey: "API keys"
        }
    }

    var symbol: String {
        switch self {
        case .login: "key.fill"
        case .contact: "person.crop.circle.fill"
        case .address: "house.fill"
        case .card: "creditcard.fill"
        case .apiKey: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The fields it keeps, in the order a form shows them.
    var fields: [VaultField] {
        switch self {
        case .login: [.username, .password]
        case .contact: [.name, .relationship, .email, .phone]
        case .address: [.name, .street, .street2, .city, .region, .postalCode, .country, .phone]
        case .card: [.name, .number, .expiry, .securityCode]
        case .apiKey: [.value]
        }
    }

    /// What Petal can type into a page for it (a card's expiry also as month and year, for forms with two boxes).
    var fillable: [VaultField] {
        switch self {
        case .card: [.name, .number, .expiry, .month, .year, .securityCode]
        case .contact: [.name, .email, .phone]
        default: fields
        }
    }
}

/// A field of an item, by the name the AI uses for it.
enum VaultField: String, CaseIterable, Codable {
    case username, password
    case name, relationship, email, phone
    case street, street2, city, region, postalCode, country
    /// An address's contact, by the contact's id.
    case contact
    case number, expiry, month, year, securityCode
    case value, notes

    /// Never told to the AI, never shown in Petal without Touch ID or the Mac's password, and searched for in
    /// everything Petal AI reads (UIMap.SecretIndex), except notes.
    var isSecret: Bool { [.password, .number, .securityCode, .value, .notes].contains(self) }

    func label(_ kind: VaultKind) -> String {
        switch self {
        case .username: "Email or username"
        case .password: "Password"
        case .name: kind == .card ? "Name on card" : kind == .address ? "Recipient" : "Name"
        case .relationship: "Who they are to you"
        case .email: "Email"
        case .phone: "Phone"
        case .street: "Address line 1"
        case .street2: "Address line 2"
        case .city: "City"
        case .region: "State or region"
        case .postalCode: "Postal code"
        case .country: "Country"
        case .contact: "Contact"
        case .number: "Card number"
        case .expiry: "Expiry (MM/YY)"
        case .month: "Expiry month"
        case .year: "Expiry year"
        case .securityCode: "Security code"
        case .value: "Key"
        case .notes: "Notes"
        }
    }

    /// The words the history and the pointer's chip use ("password", "card number").
    var words: String {
        switch self {
        case .securityCode: "security code"
        case .postalCode: "postal code"
        case .number: "card number"
        case .value: "key"
        case .street: "address"
        case .street2: "address line 2"
        case .month: "expiry month"
        case .year: "expiry year"
        default: rawValue
        }
    }
}

struct VaultItem: Codable, Equatable, Identifiable {
    var id: String
    var kind: VaultKind
    /// A login's or key's name, a contact's ("Deniz"), an address's label ("Home").
    var title: String
    /// Web hosts it belongs to ("github.com"): a login's sites, an API key's service.
    var sites: [String] = []
    /// Apps a login belongs to, by bundle id.
    var apps: [String] = []
    var fields: [String: String] = [:]
    var updated: Date = Date()

    init(id: String = Vault.newID(), kind: VaultKind, title: String, sites: [String] = [], apps: [String] = [], fields: [String: String] = [:],
         updated: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sites = sites
        self.apps = apps
        self.fields = fields
        self.updated = updated
    }

    // Lenient: a field Petal adds later is missing from older items, never a reason to lose one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(VaultKind.self, forKey: .kind)) ?? .apiKey
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        sites = (try? c.decode([String].self, forKey: .sites)) ?? []
        apps = (try? c.decode([String].self, forKey: .apps)) ?? []
        fields = (try? c.decode([String: String].self, forKey: .fields)) ?? [:]
        updated = (try? c.decode(Date.self, forKey: .updated)) ?? Date(timeIntervalSince1970: 0)
    }

    subscript(_ field: VaultField) -> String {
        get { fields[field.rawValue] ?? "" }
        set {
            let clean = field.isSecret ? newValue : newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            fields[field.rawValue] = clean.isEmpty ? nil : clean
        }
    }

    var username: String { self[.username] }
    /// The contact who is the person themselves.
    var isMe: Bool { kind == .contact && self[.relationship].lowercased() == "me" }
}

enum Vault {
    /// A short id, the same for the item's life: the AI names items by it.
    static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
    }

    // MARK: What Petal AI sees

    /// What the AI is told of an item: its kind, title, sites and apps, a login's username, a card's name, last four
    /// digits and expiry, contact info and addresses whole (with an address's contact), an API key's title and
    /// service. Never a password, card number, security code, key or notes.
    static func shown(_ item: VaultItem, in items: [VaultItem] = []) -> [String: Any] {
        var out: [String: Any] = ["id": item.id, "kind": item.kind.rawValue, "title": item.title]
        if !item.sites.isEmpty { out["sites"] = item.sites }
        if !item.apps.isEmpty { out["apps"] = item.apps }
        switch item.kind {
        case .login:
            if !item.username.isEmpty { out["username"] = item.username }
            out["hasPassword"] = !item[.password].isEmpty
        case .card:
            if !item[.name].isEmpty { out["name"] = item[.name] }
            let digits = item[.number].filter(\.isNumber)
            if digits.count >= 12 { out["last4"] = String(digits.suffix(4)) }
            if let brand = brand(digits) { out["brand"] = brand }
            if !item[.expiry].isEmpty { out["expiry"] = item[.expiry] }
        case .contact, .address:
            for field in item.kind.fields where !item[field].isEmpty { out[field.rawValue] = item[field] }
            if item.isMe { out["me"] = true }
            if item.kind == .contact {
                let homes = items.filter { $0.kind == .address && $0[.contact] == item.id }
                if !homes.isEmpty { out["addresses"] = homes.map { ["id": $0.id, "label": $0.title] } }
            }
            if item.kind == .address, !item[.contact].isEmpty {
                out["contact"] = item[.contact]
                if let contact = items.first(where: { $0.id == item[.contact] }) { out["contactName"] = contact[.name].isEmpty ? contact.title : contact[.name] }
            }
        case .apiKey:
            out["hasKey"] = !item[.value].isEmpty
        }
        return out
    }

    /// What a person reads in a list: a login's username, a card's "Visa •••• 4242", an address's first line.
    static func subtitle(_ item: VaultItem) -> String {
        switch item.kind {
        case .login: return item.username.isEmpty ? item.sites.first ?? "" : item.username
        case .card: return cardName(item)
        case .contact: return [item.isMe ? "Me" : item[.relationship].capitalized, item[.email], item[.phone]].filter { !$0.isEmpty }.joined(separator: " · ")
        case .address: return [item[.name], item[.street], item[.city]].filter { !$0.isEmpty }.joined(separator: ", ")
        case .apiKey: return item.sites.first ?? "Any app"
        }
    }

    /// "Visa •••• 4242".
    static func cardName(_ item: VaultItem) -> String {
        let digits = item[.number].filter(\.isNumber)
        let end = digits.count >= 4 ? "•••• " + String(digits.suffix(4)) : ""
        let words = [brand(digits) ?? "", end].filter { !$0.isEmpty }.joined(separator: " ")
        return words.isEmpty ? item.title : words
    }

    static func brand(_ digits: String) -> String? {
        guard digits.count >= 12 else { return nil }
        let two = Int(digits.prefix(2)) ?? 0, four = Int(digits.prefix(4)) ?? 0
        if digits.hasPrefix("4") { return "Visa" }
        if (51...55).contains(two) || (2221...2720).contains(four) { return "Mastercard" }
        if two == 34 || two == 37 { return "Amex" }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") { return "Discover" }
        if digits.hasPrefix("9792") { return "Troy" }
        return nil
    }

    /// Every way an item's secrets may show up in text, for UIMap.SecretIndex: a password and key whole, a card
    /// number as typed, as digits and in fours (with spaces and dashes), and the security code. Not notes (they're the
    /// person's words, too common to hide).
    static func secrets(_ item: VaultItem) -> [String] {
        var out: [String] = []
        for field in [VaultField.password, .value, .securityCode] where !item[field].isEmpty { out.append(item[field]) }
        let number = item[.number]
        if !number.isEmpty {
            let digits = number.filter(\.isNumber)
            out += [number, digits, groups(digits, by: 4, " "), groups(digits, by: 4, "-")]
        }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func groups(_ text: String, by size: Int, _ separator: String) -> String {
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count == size { parts.append(current); current = "" }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.joined(separator: separator)
    }

    /// The item `ref` names: its id, else its title (case aside), when only one has it.
    static func find(_ items: [VaultItem], _ ref: String) -> VaultItem? {
        let wanted = ref.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        if let item = items.first(where: { $0.id == wanted }) { return item }
        let titled = items.filter { $0.title.caseInsensitiveCompare(wanted) == .orderedSame }
        return titled.count == 1 ? titled[0] : nil
    }

    /// The logins saved for a page's host, or for an app.
    static func logins(_ items: [VaultItem], host: String?, bundle: String?) -> [VaultItem] {
        items.filter { item in
            guard item.kind == .login else { return false }
            if let host, item.sites.contains(where: { VaultSite.matches(host: host, saved: $0) }) { return true }
            if let bundle, !bundle.isEmpty, item.apps.contains(bundle) { return true }
            return false
        }
    }

    // MARK: Old items

    /// Before kinds, the vault kept a secret under a name ("OpenAI key" → the secret). Each becomes an API key with
    /// that name as its title, so `petal_vault` callers that use the name still find it.
    static func migrate(_ old: [(name: String, secret: String)]) -> [VaultItem] {
        old.filter { !$0.secret.isEmpty }.map { pair in
            var item = VaultItem(kind: .apiKey, title: pair.name.isEmpty ? "Key" : pair.name)
            item[.value] = pair.secret
            return item
        }
    }

    // MARK: Passwords

    static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    static let symbols = Array("!@#$%^&*-_=+?.")

    /// A strong password: `length` characters (12 to 64; 20 by default) with at least one lower and upper case
    /// letter and digit, and a symbol unless `symbols` is false; `allowed` instead limits the symbols to those a site
    /// takes. `random` gives that many random bytes (SecRandomCopyBytes); picks are unbiased (bytes past the last
    /// whole multiple are drawn again). Look-alikes (l, I, O, 0, 1) are left out.
    static func password(length: Int = 20, symbols useSymbols: Bool = true, allowed: String? = nil,
                         random: (Int) -> [UInt8]) -> String {
        let size = min(64, max(12, length))
        var marks: [Character] = []
        if let allowed { marks = Array(Set(allowed.filter { $0.isASCII && !$0.isLetter && !$0.isNumber && !$0.isWhitespace })).sorted() }
        else if useSymbols { marks = symbols }
        let sets = [lower, upper, digits] + (marks.isEmpty ? [] : [marks])
        let all = sets.flatMap { $0 }
        var pool: [UInt8] = []
        func pick(_ count: Int) -> Int {
            let limit = 256 - 256 % count
            while true {
                if pool.isEmpty { pool = random(64) }
                guard let byte = pool.popLast() else { continue }
                if Int(byte) < limit { return Int(byte) % count }
            }
        }
        var out = sets.map { $0[pick($0.count)] }
        while out.count < size { out.append(all[pick(all.count)]) }
        // Fisher–Yates, so the guaranteed ones aren't always first.
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            let j = pick(i + 1)
            out.swapAt(i, j)
        }
        return String(out)
    }

    // MARK: Filling: when Petal does it by itself

    /// The field Petal would type into, as Accessibility describes it.
    struct Target: Equatable {
        var secure = false
        /// A text field, text area, combo box or search field.
        var text = true
        /// A pop-up menu (a web page's select): Petal picks one of its items.
        var popup = false
    }

    /// Where it is, as Petal read it itself (never from the AI).
    struct Place: Equatable {
        /// Inside a web page.
        var web = false
        /// The address of the page (or frame) the field is in: its nearest web area's.
        var frameURL: String?
        /// The address of the tab's whole page: the outermost web area's.
        var topURL: String?
        /// The browser's own answer for the tab, where it gives one.
        var tabURL: String?
        var bundle = ""
        var appName = ""
        /// The app's code signature is valid, from Apple's certificates, and names this bundle id.
        var signed = false

        /// The host shown to the person: the page's (or frame's).
        var host: String? { frameURL.flatMap(VaultSite.host) }
        /// Where a purchase is made: the tab's whole page (a card form often sits in a payment company's frame).
        var shop: String? { (topURL ?? frameURL).flatMap(VaultSite.host) }
        var where_: String { web ? host ?? appName : appName }
    }

    enum Decision: Equatable {
        case fill
        /// A card asks the person first, Don't the default: the place doesn't match.
        case ask(title: String, detail: String)
        /// Payment info before this checkout was allowed: one "Buy?" card for the shop (its registrable name).
        case buy(shop: String)
        case refuse(String)
    }

    /// Whether Petal fills `field` of `item` into `target` at `place` by itself, asks the person first, or won't:
    /// - a login fills by itself only on a page of a site it's saved for (https, or http on this Mac: localhost,
    ///   127.0.0.1, [::1]; the page's address and the tab's agreeing), or in an app it's saved for whose signature
    ///   checks out; anywhere else asks, with what doesn't match said plainly;
    /// - an API key fills by itself on its service's site (the same rule), on this Mac's own pages, or into an app;
    ///   any other site asks the same way;
    /// - payment info only on secure web pages (https), and only once this checkout's one "Buy?" card was answered
    ///   Buy (`checkout`): before that, nothing of the card goes into the page;
    /// - contact info and addresses fill freely: they aren't secrets;
    /// - a password only into a password field; a card number, security code or key into a password field or a
    ///   text field; a country or region also by picking from a pop-up menu; the rest into text fields.
    static func decide(_ item: VaultItem, _ field: VaultField, target: Target, place: Place, checkout: Bool = false) -> Decision {
        guard item.kind.fillable.contains(field) else {
            return .refuse("\(item.title) is \(item.kind.name.lowercased()): it has no \(field.words). It can fill \(item.kind.fillable.map(\.rawValue).joined(separator: ", ")).")
        }
        switch field {
        case .month, .year: guard expiryParts(item[.expiry]) != nil else { return .refuse("\(item.title) has no expiry saved.") }
        default: guard !item[field].isEmpty else { return .refuse("\(item.title) has no \(field.words) saved.") }
        }
        if field == .password, !target.secure { return .refuse("Petal fills a password only into a password field. Pick the password field's id from petal_ui.") }
        let maySecure: Set<VaultField> = [.password, .number, .securityCode, .value]
        if target.secure, !maySecure.contains(field) { return .refuse("That's a password field: the \(field.words) doesn't go there.") }
        let mayPick: Set<VaultField> = [.country, .region, .month, .year]
        if target.popup, !mayPick.contains(field) { return .refuse("That's a pop-up menu: Petal picks only a country, region or expiry month or year from one.") }
        if !target.secure, !target.text, !target.popup { return .refuse("That isn't a field Petal can type into. Pick a text field's id from petal_ui.") }

        switch item.kind {
        case .login:
            guard let why = mismatch(item, place) else { return .fill }
            let saved = item.sites.first ?? item.title
            return .ask(title: "Fill your \(saved) \(field.words) \(place.web ? "on" : "in") \(place.where_)?", detail: why)
        case .apiKey:
            guard let why = keyMismatch(item, place) else { return .fill }
            return .ask(title: "Fill your “\(item.title)” on \(place.where_)?", detail: why)
        case .card:
            guard place.web, let frame = place.frameURL, VaultSite.scheme(frame) == "https",
                  VaultSite.scheme(place.topURL ?? frame) == "https", let shop = place.shop else {
                return .refuse("Petal fills payment info only on secure web pages (https).")
            }
            if let tab = place.tabURL.flatMap(VaultSite.host), tab != shop {
                return .refuse("Petal couldn't confirm the page (the tab says \(tab), the page says \(shop)), so it fills no payment info here.")
            }
            return checkout ? .fill : .buy(shop: VaultSite.registrable(shop))
        case .contact, .address:
            return .fill
        }
    }

    /// An https page, or one on this Mac (http://localhost, 127.0.0.1, [::1]).
    static func secure(_ url: String) -> Bool {
        switch VaultSite.scheme(url) {
        case "https": return true
        case "http": return VaultSite.host(url).map(VaultSite.isLocal) ?? false
        default: return false
        }
    }

    /// What's wrong with a web page's address, or nil: unreadable, not secure, or the tab says another page.
    private static func pageProblem(_ place: Place) -> String? {
        guard let frame = place.frameURL, let host = VaultSite.host(frame) else { return "Petal couldn't read which page this field is on." }
        guard secure(frame) else { return "\(host) isn't a secure page (it's not https): what's typed there can be read on the way." }
        if let top = place.topURL {
            guard secure(top) else { return "The page around this field isn't secure (it's not https)." }
            if let tab = place.tabURL, let tabHost = VaultSite.host(tab), let topHost = VaultSite.host(top), tabHost != topHost {
                return "Petal couldn't confirm the page: the tab says \(tabHost), the page says \(topHost)."
            }
        }
        return nil
    }

    /// Why a login's place isn't one it's saved for, in plain words, or nil when it is.
    static func mismatch(_ item: VaultItem, _ place: Place) -> String? {
        if item.sites.isEmpty && item.apps.isEmpty { return "This login isn't saved for any site yet, so Petal can't tell it's the right place." }
        if place.web {
            if let problem = pageProblem(place) { return problem }
            let host = place.host ?? ""
            if item.sites.contains(where: { VaultSite.matches(host: host, saved: $0) }) { return nil }
            let saved = item.sites.isEmpty ? "an app" : item.sites.joined(separator: ", ")
            return "This login is saved for \(saved). This page is \(host): if it only looks like \(item.sites.first.map(VaultSite.registrable) ?? item.title), it may be trying to take your password."
        }
        guard item.apps.contains(place.bundle) else {
            return "This login is saved for \((item.sites + item.apps).joined(separator: ", ")), not \(place.appName)."
        }
        guard place.signed else { return "Petal couldn't verify \(place.appName) is the real app (its signature didn't check out)." }
        return nil
    }

    /// Why an API key doesn't belong where the field is, or nil: it goes into any app, onto this Mac's own pages, and
    /// onto its service's site.
    static func keyMismatch(_ item: VaultItem, _ place: Place) -> String? {
        guard place.web else { return nil }
        let local = { (url: String?) in url.flatMap(VaultSite.host).map(VaultSite.isLocal) ?? false }
        if local(place.frameURL), local(place.topURL ?? place.frameURL), place.tabURL.map({ local($0) }) ?? true { return nil }
        if let problem = pageProblem(place) { return problem }
        let host = place.host ?? ""
        if item.sites.contains(where: { VaultSite.matches(host: host, saved: $0) }) { return nil }
        if item.sites.isEmpty { return "This key isn't saved for a service, and \(host) isn't a page on this Mac." }
        return "This key is for \(item.sites.joined(separator: ", ")). This page is \(host): a page that only looks like \(VaultSite.registrable(item.sites[0])) may be trying to take it."
    }

    /// "04/27", "4/2027", "04-27", "2027-04" as ("04", "27", "2027").
    static func expiryParts(_ text: String) -> (month: String, year2: String, year4: String)? {
        var parts = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].count == 4 { parts.swapAt(0, 1) }   // year first
        guard let month = Int(parts[0]), (1...12).contains(month) else { return nil }
        let year = parts[1]
        guard year.count == 2 || year.count == 4 else { return nil }
        let year4 = year.count == 2 ? "20" + year : year
        return (String(format: "%02d", month), String(year4.suffix(2)), year4)
    }

    /// What's typed for a field: a card's month or year from its expiry, else what's saved.
    static func text(_ item: VaultItem, _ field: VaultField, fourDigitYear: Bool = false) -> String? {
        switch field {
        case .month: return expiryParts(item[.expiry])?.month
        case .year: return expiryParts(item[.expiry]).map { fourDigitYear ? $0.year4 : $0.year2 }
        default: let value = item[field]; return value.isEmpty ? nil : value
        }
    }

    /// Countries' other names, for picking from a menu: what's saved on one side, what a menu may say on the other.
    static let countryNames: [[String]] = [
        ["turkey", "türkiye", "turkiye", "tr", "tur"], ["united states", "united states of america", "usa", "us", "u.s.", "america"],
        ["united kingdom", "uk", "gb", "great britain", "britain", "england"], ["germany", "deutschland", "de"],
        ["netherlands", "the netherlands", "holland", "nl"], ["south korea", "korea, republic of", "republic of korea", "korea", "kr"],
        ["czech republic", "czechia", "cz"], ["russia", "russian federation", "ru"], ["united arab emirates", "uae", "ae"],
        ["france", "fr"], ["spain", "españa", "es"], ["italy", "italia", "it"], ["japan", "jp"], ["canada", "ca"], ["australia", "au"],
    ]

    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ı", with: "i").folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which of a menu's items is `wanted` (a country, a region, a month): the same words, another name for the same
    /// country, the same number ("04" for "4", "April"'s month), or the one item that starts with it. nil when unsure.
    static func pick(_ wanted: String, from options: [String]) -> Int? {
        let want = fold(wanted)
        guard !want.isEmpty else { return nil }
        let folded = options.map(fold)
        if let exact = folded.firstIndex(of: want) { return exact }
        if let names = countryNames.first(where: { $0.contains(want) }), let index = folded.firstIndex(where: names.contains) { return index }
        if let number = Int(want) {
            let same = folded.indices.filter { Int(folded[$0]) == number || folded[$0].hasPrefix(String(format: "%02d", number) + " ") }
            if same.count == 1 { return same[0] }
            if (1...12).contains(number) {
                let month = DateFormatter().monthSymbols[number - 1].lowercased()
                let named = folded.indices.filter { folded[$0] == month || folded[$0].hasPrefix(month) || folded[$0].contains("- " + month) }
                if named.count == 1 { return named[0] }
            }
        }
        let starts = folded.indices.filter { folded[$0].hasPrefix(want) }
        return starts.count == 1 ? starts[0] : nil
    }

    /// The field the AI names, in its own words ("cvv", "zip", "line1"); a login's email is its username.
    static func field(_ text: String, kind: VaultKind? = nil) -> VaultField? {
        let word = text.lowercased().filter { $0.isLetter || $0.isNumber }
        let found: VaultField?
        switch word {
        case "username", "user", "login", "account", "userid": found = .username
        case "password", "pass", "pw", "passwd", "newpassword", "confirmpassword": found = .password
        case "number", "cardnumber", "cc", "ccnumber", "pan": found = .number
        case "cvc", "cvv", "csc", "cvv2", "cvc2", "securitycode": found = .securityCode
        case "expiry", "expiration", "exp", "expirydate", "expirationdate": found = .expiry
        case "month", "expmonth", "expirymonth": found = .month
        case "year", "expyear", "expiryyear": found = .year
        case "name", "fullname", "cardholder", "nameoncard", "cardname", "recipient": found = .name
        case "email", "mail", "emailaddress": found = .email
        case "phone", "tel", "telephone", "mobile", "phonenumber": found = .phone
        case "street", "address", "address1", "line1", "streetaddress", "addressline1": found = .street
        case "street2", "address2", "line2", "apartment", "suite", "addressline2": found = .street2
        case "city", "town": found = .city
        case "region", "state", "province", "county": found = .region
        case "postalcode", "postcode", "zip", "zipcode": found = .postalCode
        case "country", "countryorregion": found = .country
        case "value", "secret", "key", "token", "apikey": found = .value
        default: found = nil
        }
        if kind == .login, found == .email { return .username }
        return found
    }

    /// Why the place a field is in now isn't the one Petal decided on (another page, another app), or nil: read
    /// again right before filling, so a page that moved on meanwhile never gets it.
    static func moved(from then: Place, to now: Place) -> String? {
        if then.web != now.web || then.bundle != now.bundle { return "That field isn't in the same app or page anymore; nothing was filled. Call petal_ui again." }
        guard then.web else { return nil }
        func origin(_ url: String?) -> String { url.map { "\(VaultSite.scheme($0) ?? "")://\(VaultSite.host($0) ?? "")" } ?? "" }
        if origin(then.frameURL) != origin(now.frameURL) || origin(then.topURL) != origin(now.topURL) {
            return "The page changed (it's \(now.host ?? "another page") now); nothing was filled. Call petal_ui again."
        }
        return nil
    }

    // MARK: Import and export

    /// Petal's own export: every item, every field (and each address's contact), as JSON. It holds the secrets as
    /// plain text.
    struct Export: Codable {
        var petalVault = 1
        var exported: Date
        var items: [VaultItem]
    }

    static func exportJSON(_ items: [VaultItem], at date: Date = Date()) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(Export(exported: date, items: items))) ?? Data()
    }

    /// Logins as a CSV in Chrome's format (name, url, username, password, note), which Apple Passwords and Chrome
    /// both import. It holds the passwords as plain text.
    static func exportCSV(_ items: [VaultItem]) -> String {
        var lines = ["name,url,username,password,note"]
        for item in items where item.kind == .login {
            let url = item.sites.first.map { "https://\($0)/" } ?? ""
            lines.append([item.title, url, item.username, item[.password], item[.notes]].map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func csvField(_ text: String) -> String {
        let special = text.contains { $0 == "," || $0 == "\"" || $0.isNewline } || text.first == " " || text.last == " "
        return special ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    /// Comma-separated values (RFC 4180): quoted fields may hold commas, quotes ("") and line breaks; rows end in
    /// CRLF or LF; a byte-order mark is dropped.
    static func csv(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var characters = Array(text)
        if characters.first == "\u{FEFF}" { characters.removeFirst() }
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < characters.count, characters[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c.isNewline {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// A header's words for matching: "Login_Username" and "login username" as "loginusername".
    static func key(_ header: String) -> String { header.lowercased().filter { $0.isLetter || $0.isNumber } }

    struct Imported: Equatable {
        var items: [VaultItem] = []
        /// Rows or entries with nothing Petal keeps (a note, an empty row, one in the trash).
        var skipped = 0
    }

    /// A password export as CSV, by its header's names in any order: Apple Passwords (Title, URL, Username, Password,
    /// Notes), Chrome (name, url, username, password, note), Proton Pass (type, name, url, email, username, password,
    /// note; logins, credit cards and identities), Firefox and Bitwarden. 2FA columns are left out. nil when the first
    /// row isn't a header Petal knows.
    static func importCSV(_ text: String) -> Imported? {
        let rows = csv(text)
        guard let header = rows.first?.map(key) else { return nil }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        let password = column(["password", "loginpassword"])
        let number = column(["number", "cardnumber", "ccnumber"])
        let type = column(["type", "itemtype"])
        guard password != nil || number != nil || type != nil else { return nil }
        let title = column(["title", "name", "itemname"]), url = column(["url", "loginuri", "website", "urls", "origin"])
        let user = column(["username", "loginusername", "login", "user", "itemusername"]), email = column(["email", "itememail", "emailaddress"])
        let notes = column(["notes", "note", "extra", "comment", "comments"])
        let holder = column(["cardholdername", "cardholder", "nameoncard"]), expiry = column(["expirationdate", "expiry", "expiration", "exp"])
        let code = column(["verificationcode", "cvv", "cvc", "securitycode", "csc"])
        let full = column(["fullname"]), phone = column(["phone", "phonenumber", "mobile"])
        let street = column(["streetaddress", "street", "address", "address1"]), street2 = column(["address2", "floor", "street2"])
        let city = column(["city"]), region = column(["stateorprovince", "state", "region", "province"])
        let postal = column(["ziporpostalcode", "postalcode", "zip", "zipcode", "postcode"]), country = column(["countryorregion", "country"])
        var result = Imported()
        for row in rows.dropFirst() {
            func value(_ index: Int?) -> String { index.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            let kind = type.map { kindNamed(value($0)) } ?? (value(password).isEmpty && !value(number).isEmpty ? .card : .login)
            switch kind {
            case .login?:
                guard !value(password).isEmpty else { result.skipped += 1; continue }
                let host = VaultSite.host(value(url).split(separator: ",").first.map(String.init) ?? "")
                var item = VaultItem(kind: .login, title: value(title).trimmingCharacters(in: .whitespaces))
                if item.title.isEmpty { item.title = host ?? "Login" }
                if let host { item.sites = [host] }
                item[.username] = value(user).isEmpty ? value(email) : value(user)
                item[.password] = value(password)
                item[.notes] = value(notes)
                result.items.append(item)
            case .card?:
                guard !value(number).isEmpty else { result.skipped += 1; continue }
                var item = VaultItem(kind: .card, title: value(title).isEmpty ? "Card" : value(title))
                item[.name] = value(holder)
                item[.number] = value(number)
                item[.expiry] = Self.expiry(value(expiry))
                item[.securityCode] = value(code)
                item[.notes] = value(notes)
                result.items.append(item)
            case .contact?:
                let found = person(title: value(title), name: value(full), email: value(email), phone: value(phone),
                                   address: [.street: value(street), .street2: value(street2), .city: value(city), .region: value(region),
                                             .postalCode: value(postal), .country: value(country)])
                if found.isEmpty { result.skipped += 1 } else { result.items += found }
            default:
                result.skipped += 1
            }
        }
        return result
    }

    /// An identity as Petal keeps it: contact info, and its address as an Address linked to it.
    static func person(title: String, name: String, email: String, phone: String, address: [VaultField: String]) -> [VaultItem] {
        var contact = VaultItem(kind: .contact, title: title.isEmpty ? (name.isEmpty ? "Contact info" : name) : title)
        contact[.name] = name
        contact[.email] = email
        contact[.phone] = phone
        var home = VaultItem(kind: .address, title: "Home")
        for (field, value) in address { home[field] = value }
        let hasAddress = !home.fields.isEmpty
        guard !contact.fields.isEmpty || hasAddress else { return [] }
        guard hasAddress else { return [contact] }
        home[.name] = name
        home[.phone] = phone
        home[.contact] = contact.id
        return [contact, home]
    }

    /// A row's or entry's type, in Proton Pass's and Petal's words; nil for what Petal doesn't keep (notes, aliases).
    static func kindNamed(_ text: String) -> VaultKind? {
        switch key(text) {
        case "", "login", "password": return .login
        case "creditcard", "card", "paymentinfo", "payment": return .card
        case "identity", "contact", "contactinfo": return .contact
        case "address": return .address
        case "apikey": return .apiKey
        default: return nil
        }
    }

    /// "2027-04" (Proton Pass) as "04/27"; anything else as it was.
    static func expiry(_ text: String) -> String {
        guard let parts = expiryParts(text) else { return text.trimmingCharacters(in: .whitespaces) }
        return "\(parts.month)/\(parts.year2)"
    }

    /// Petal's own export, or Proton Pass's unencrypted JSON (its logins, credit cards and identities, an identity's
    /// address as an Address linked to it; what's in its trash is left). nil when it's neither.
    static func importJSON(_ data: Data) -> Imported? {
        if let export = try? JSONDecoder().decode(Export.self, from: data), export.petalVault >= 1 { return Imported(items: export.items) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let vaults = root["vaults"] as? [String: Any] else { return nil }
        var result = Imported()
        for case let vault as [String: Any] in vaults.values {
            for case let entry as [String: Any] in vault["items"] as? [Any] ?? [] {
                guard (entry["state"] as? Int ?? 1) == 1, let data = entry["data"] as? [String: Any] else { result.skipped += 1; continue }
                let meta = data["metadata"] as? [String: Any] ?? [:]
                let content = data["content"] as? [String: Any] ?? [:]
                func text(_ names: String...) -> String { names.lazy.compactMap { content[$0] as? String }.first { !$0.isEmpty } ?? "" }
                let title = meta["name"] as? String ?? ""
                let note = meta["note"] as? String ?? ""
                switch kindNamed(data["type"] as? String ?? "") {
                case .login?:
                    let password = text("password")
                    guard !password.isEmpty else { result.skipped += 1; continue }
                    var hosts: [String] = []
                    for host in (content["urls"] as? [String] ?? []).compactMap(VaultSite.host) where !hosts.contains(host) { hosts.append(host) }
                    var item = VaultItem(kind: .login, title: title.isEmpty ? hosts.first ?? "Login" : title, sites: hosts)
                    item[.username] = text("itemUsername", "username", "itemEmail", "email")
                    item[.password] = password
                    item[.notes] = note
                    result.items.append(item)
                case .card?:
                    guard !text("number").isEmpty else { result.skipped += 1; continue }
                    var item = VaultItem(kind: .card, title: title.isEmpty ? "Card" : title)
                    item[.name] = text("cardholderName")
                    item[.number] = text("number")
                    item[.expiry] = expiry(text("expirationDate"))
                    item[.securityCode] = text("verificationCode")
                    item[.notes] = note
                    result.items.append(item)
                case .contact?:
                    let full = text("fullName")
                    let parts = [text("firstName"), text("lastName")].filter { !$0.isEmpty }.joined(separator: " ")
                    let found = person(title: title, name: full.isEmpty ? parts : full, email: text("email"), phone: text("phoneNumber", "phone"),
                                       address: [.street: text("streetAddress"), .street2: text("floor"), .city: text("city"),
                                                 .region: text("stateOrProvince"), .postalCode: text("zipOrPostalCode"), .country: text("countryOrRegion")])
                    if found.isEmpty { result.skipped += 1 } else { result.items += found }
                default:
                    result.skipped += 1
                }
            }
        }
        return result
    }

    /// Any export Petal reads: JSON (Petal's, Proton Pass's) or CSV.
    static func importData(_ data: Data) -> Imported? {
        if let json = importJSON(data) { return json }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return importCSV(text)
    }

    /// The same thing saved twice: the same id (Petal's own export), else a login for the same site and username,
    /// a card with the same number, contact info with the same email (or name), an address with the same first line
    /// and postal code, an API key with the same title.
    static func same(_ a: VaultItem, _ b: VaultItem) -> Bool {
        if a.id == b.id { return true }
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .login:
            guard a.username.lowercased() == b.username.lowercased() else { return false }
            let left = Set(a.sites.map(VaultSite.plain)), right = Set(b.sites.map(VaultSite.plain))
            return left == right || !left.isDisjoint(with: right)
        case .card:
            let digits = a[.number].filter(\.isNumber)
            return !digits.isEmpty && digits == b[.number].filter(\.isNumber)
        case .contact:
            if !a[.email].isEmpty || !b[.email].isEmpty { return a[.email].lowercased() == b[.email].lowercased() }
            return !a[.name].isEmpty && a[.name].lowercased() == b[.name].lowercased()
        case .address:
            return !a[.street].isEmpty && fold(a[.street]) == fold(b[.street]) && fold(a[.postalCode]) == fold(b[.postalCode])
        case .apiKey:
            return a.title.lowercased() == b.title.lowercased()
        }
    }

    struct Merge {
        /// New items, and saved ones the import changed, to save.
        var save: [VaultItem] = []
        var added = 0
        /// Already there, and changed: a login's password differed (the import's, newer, is kept), or another kind's
        /// details. Their titles, to say so.
        var updated: [String] = []
        var same = 0
    }

    /// An import against what's saved. Something already there changes nothing unless it differs: a login only when
    /// its password does (then the import's, newer, is kept); anything else takes the import's fields. A later entry
    /// of the same file wins over an earlier one. Petal's own export keeps its ids and dates; an imported address
    /// whose contact turned out to be one already saved is linked to that one.
    static func merge(existing: [VaultItem], incoming: [VaultItem], at date: Date = Date()) -> Merge {
        var result = Merge()
        var current = existing
        var touched: [String: Int] = [:]   // item id → index in result.save
        var renamed: [String: String] = [:]   // an imported contact's id → the saved one's
        // Contacts first, so addresses can follow their contact.
        let ordered = incoming.filter { $0.kind != .address } + incoming.filter { $0.kind == .address }
        for var item in ordered {
            if item.kind == .address, let link = renamed[item[.contact]] { item[.contact] = link }
            if let index = current.firstIndex(where: { same($0, item) }) {
                var saved = current[index]
                if saved.kind == .contact { renamed[item.id] = saved.id }
                if saved.kind == .login {
                    guard saved[.password] != item[.password], !item[.password].isEmpty else { result.same += 1; continue }
                    saved[.password] = item[.password]
                    if saved[.notes].isEmpty { saved[.notes] = item[.notes] }
                } else {
                    let fields = saved.fields.merging(item.fields) { _, new in new }
                    let sites = saved.sites + item.sites.filter { !saved.sites.contains($0) }
                    guard fields != saved.fields || sites != saved.sites || saved.title != item.title else { result.same += 1; continue }
                    saved.fields = fields
                    saved.sites = sites
                    saved.title = item.title.isEmpty ? saved.title : item.title
                }
                saved.updated = date
                current[index] = saved
                if !result.updated.contains(saved.title) { result.updated.append(saved.title) }
                if let at = touched[saved.id] { result.save[at] = saved } else { touched[saved.id] = result.save.count; result.save.append(saved) }
            } else {
                if item.updated == Date(timeIntervalSince1970: 0) { item.updated = date }
                current.append(item)
                touched[item.id] = result.save.count
                result.save.append(item)
                result.added += 1
            }
        }
        return result
    }
}

/// Which site a web address is, and whether something saved for one site belongs on a page.
enum VaultSite {
    /// Suffixes under which anyone can have a name of their own (so "a.co.uk" and "b.co.uk" are strangers), beyond
    /// the rule below; and hosting sites where every customer is a subdomain (anyone can have evil.github.io).
    static let suffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "nhs.uk", "police.uk",
        "com.tr", "net.tr", "org.tr", "edu.tr", "gov.tr", "k12.tr", "bel.tr", "av.tr", "gen.tr", "biz.tr", "info.tr", "web.tr",
        "tv.tr", "pol.tr", "tsk.tr", "name.tr", "bbs.tr", "dr.tr", "kep.tr",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "ed.jp", "gr.jp", "lg.jp",
        "co.nz", "org.nz", "net.nz", "ac.nz", "govt.nz", "geek.nz", "school.nz",
        "co.za", "org.za", "gov.za", "ac.za", "web.za", "net.za",
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.hk", "org.hk", "edu.hk", "gov.hk", "net.hk", "com.sg", "edu.sg", "gov.sg", "org.sg", "net.sg",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in", "ac.in", "edu.in", "gov.in",
        "co.kr", "or.kr", "ac.kr", "go.kr", "ne.kr", "com.mx", "org.mx", "gob.mx", "edu.mx", "net.mx",
        "co.il", "org.il", "ac.il", "gov.il", "com.tw", "org.tw", "edu.tw", "gov.tw", "co.id", "ac.id", "go.id", "or.id",
        "co.th", "ac.th", "go.th", "in.th", "com.pl", "net.pl", "org.pl", "co.at", "or.at", "com.es", "com.pt", "com.gr",
        // Hosting: every customer has a subdomain.
        "github.io", "gitlab.io", "bitbucket.io", "herokuapp.com", "vercel.app", "now.sh", "netlify.app", "netlify.com",
        "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "appspot.com", "blogspot.com", "azurewebsites.net",
        "cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "ngrok.io", "ngrok-free.app", "ngrok.app", "glitch.me",
        "repl.co", "replit.app", "onrender.com", "fly.dev", "surge.sh", "wixsite.com", "myshopify.com", "notion.site",
        "carrd.co", "web.core.windows.net", "azurestaticapps.net", "deno.dev", "railway.app", "up.railway.app",
        "framer.app", "webflow.io", "squarespace.com", "wordpress.com", "tumblr.com", "translate.goog", "googleusercontent.com",
        "sharepoint.com", "my.salesforce.com", "force.com", "zendesk.com", "atlassian.net", "readthedocs.io", "gitbook.io",
        "substack.com", "medium.com", "itch.io", "neocities.org", "codeberg.page", "pythonanywhere.com", "streamlit.app",
        "hf.space", "csb.app", "stackblitz.io", "lovable.app",
    ]
    /// Under a country's own two letters, these second words are shared suffixes too ("com.tr", "co.uk", "ac.jp").
    static let shared: Set<String> = ["com", "co", "net", "org", "edu", "gov", "ac", "or", "ne", "go", "gob", "mil", "nom", "ltd",
                                      "plc", "sch", "k12", "gen", "biz", "info", "nic", "res", "gv", "mi", "ed"]

    /// The host of an address, or of a bare host ("github.com"), lower case, without a port, brackets or a trailing dot.
    static func host(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") {
            // A bare IPv6 address ("::1") goes in brackets, as in an address.
            if trimmed.filter({ $0 == ":" }).count > 1, !trimmed.hasPrefix("[") { trimmed = "[" + trimmed + "]" }
            trimmed = "https://" + trimmed
        }
        guard let parts = URLComponents(string: trimmed), var host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard host.contains(".") || host.contains(":") || host == "localhost" else { return nil }
        return host
    }

    static func scheme(_ text: String) -> String? {
        URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
    }

    /// This Mac itself: localhost, 127.0.0.1, ::1.
    static func isLocal(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost")
    }

    /// A host without a leading "www.", for telling two logins apart.
    static func plain(_ text: String) -> String {
        let h = host(text) ?? text.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Under which anyone can register a name: "co.uk", "github.io".
    static func isSuffix(_ host: String) -> Bool {
        if suffixes.contains(host) { return true }
        let labels = host.split(separator: ".").map(String.init)
        return labels.count == 2 && labels[1].count == 2 && shared.contains(labels[0])
    }

    /// The name someone registered: "github.com" for "gist.github.com", "example.co.uk" for "www.example.co.uk",
    /// "me.github.io" for "me.github.io". Conservative: when unsure, the longer name (fewer pages match).
    static func registrable(_ text: String) -> String {
        guard let host = host(text) else { return text.lowercased() }
        if isAddress(host) || isLocal(host) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        // The longest known suffix, then one label more.
        for take in stride(from: min(4, labels.count - 1), through: 2, by: -1) {
            let suffix = labels.suffix(take).joined(separator: ".")
            if suffixes.contains(suffix) { return labels.suffix(take + 1).joined(separator: ".") }
        }
        let last = labels[labels.count - 1], second = labels[labels.count - 2]
        if last.count == 2, shared.contains(second) { return labels.suffix(3).joined(separator: ".") }
        return labels.suffix(2).joined(separator: ".")
    }

    /// A page on `host` belongs to something saved for `saved`: the same host, or under the saved site's registrable
    /// name ("accounts.github.com" for "github.com"). An IP address, this Mac, or a shared suffix saved as a site
    /// ("github.io") only matches itself.
    static func matches(host: String, saved: String) -> Bool {
        guard let page = self.host(host), let site = self.host(saved) else { return false }
        if page == site { return true }
        if isAddress(page) || isAddress(site) || isSuffix(site) || isLocal(site) || isLocal(page) { return false }
        let root = registrable(site)
        return page == root || page.hasSuffix("." + root)
    }
}
