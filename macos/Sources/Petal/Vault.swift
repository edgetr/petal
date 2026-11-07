import Foundation

/// The vault's pure side: its items, what Petal AI is told of them, which sites and apps an item belongs to, reading
/// and writing exports, making passwords, and when Petal fills something by itself. Nothing here touches the
/// Keychain, Accessibility or the screen (VaultStore.swift and VaultFill.swift do), so `macos/checks/run.sh` checks it.

enum VaultKind: String, Codable, CaseIterable, Identifiable {
    case login, contact, address, card, apiKey
    /// A secret from before kinds (or of a kind this Petal doesn't know): Petal can't tell what it is or where it
    /// belongs, so filling it asks every time, anywhere, until the person sorts it in Settings › Vault.
    case unsorted
    var id: String { rawValue }

    /// The kinds a person or Petal AI makes: never unsorted.
    static let made: [VaultKind] = [.login, .contact, .address, .card, .apiKey]
    /// What an unsorted secret can be sorted into (Vault.sort says where its secret goes).
    static let sortable: [VaultKind] = [.login, .apiKey, .card]

    var name: String {
        switch self {
        case .login: "Login"
        case .contact: "Contact info"
        case .address: "Address"
        case .card: "Payment info"
        case .apiKey: "API key"
        case .unsorted: "Unsorted"
        }
    }

    var plural: String {
        switch self {
        case .login: "Logins"
        case .contact: "Contact info"
        case .address: "Addresses"
        case .card: "Payment info"
        case .apiKey: "API keys"
        case .unsorted: "Unsorted"
        }
    }

    var symbol: String {
        switch self {
        case .login: "key.fill"
        case .contact: "person.crop.circle.fill"
        case .address: "house.fill"
        case .card: "creditcard.fill"
        case .apiKey: "chevron.left.forwardslash.chevron.right"
        case .unsorted: "questionmark.square.dashed"
        }
    }

    /// The fields it keeps, in the order a form shows them.
    var fields: [VaultField] {
        switch self {
        case .login: [.username, .password]
        case .contact: [.name, .relationship, .email, .phone]
        case .address: [.name, .street, .street2, .city, .region, .postalCode, .country, .phone]
        case .card: [.name, .number, .expiry, .securityCode]
        case .apiKey, .unsorted: [.value]
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
        case .value: kind == .unsorted ? "Secret" : "Key"
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
    /// Who signed each of those apps when the login was tied to it (its Team ID, or "apple" for Apple's own): the
    /// login fills by itself only into a copy signed the same way. An app with none saved asks first.
    var appSigners: [String: String] = [:]
    var fields: [String: String] = [:]
    var updated: Date = Date()

    init(id: String = Vault.newID(), kind: VaultKind, title: String, sites: [String] = [], apps: [String] = [],
         appSigners: [String: String] = [:], fields: [String: String] = [:], updated: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sites = sites
        self.apps = apps
        self.appSigners = appSigners
        self.fields = fields
        self.updated = updated
    }

    // Lenient: a field Petal adds later is missing from older items, never a reason to lose one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // A kind this Petal doesn't know is unsorted: asked about wherever it goes, never filled by itself.
        kind = (try? c.decode(VaultKind.self, forKey: .kind)) ?? .unsorted
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        sites = (try? c.decode([String].self, forKey: .sites)) ?? []
        apps = (try? c.decode([String].self, forKey: .apps)) ?? []
        appSigners = (try? c.decode([String: String].self, forKey: .appSigners)) ?? [:]
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
    /// service; an unsorted secret's title only. Never a password, card number, security code, key or notes.
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
        case .unsorted:
            break
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
        case .unsorted: return "Not sorted yet"
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

    /// Before kinds, the vault kept a secret under a name ("OpenAI key", "GitHub password" → the secret), with
    /// nothing saying what it is or where it belongs. Each becomes unsorted, with that name as its title: `petal_vault`
    /// callers that use the name still find it, and filling it asks every time, anywhere (Vault.decide), until the
    /// person sorts it in Settings › Vault.
    static func migrate(_ old: [(name: String, secret: String)]) -> [VaultItem] {
        old.filter { !$0.secret.isEmpty }.map { pair in
            var item = VaultItem(kind: .unsorted, title: pair.name.isEmpty ? "Secret" : pair.name)
            item[.value] = pair.secret
            return item
        }
    }

    /// An unsorted secret as the kind the person says it is, its secret where that kind keeps it (a login's
    /// password, a key, a card's number), the same id. Its site, service or app is the person's to add.
    static func sort(_ item: VaultItem, as kind: VaultKind) -> VaultItem {
        guard item.kind == .unsorted, VaultKind.sortable.contains(kind) else { return item }
        var sorted = item
        sorted.kind = kind
        let secret = item[.value]
        sorted.fields[VaultField.value.rawValue] = nil
        switch kind {
        case .login: sorted[.password] = secret
        case .card: sorted[.number] = secret
        default: sorted[.value] = secret
        }
        return sorted
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

    /// Which tab a page is in, as Petal read it itself: the browser's own id for the tab (Chromium's tab id, Safari's
    /// tab index) when it gave one, and the tab's page (its outermost web area, as Accessibility gives it: each tab has
    /// its own, and most navigations make a new one).
    struct Tab: Equatable {
        var id: String?
        var page: AnyObject?

        static func == (a: Tab, b: Tab) -> Bool { a.id == b.id && UIMap.same(a.page, b.page) }
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
        /// The tab itself (a web page only).
        var tab = Tab()
        var bundle = ""
        var appName = ""
        /// The app's code signature is valid, from Apple's certificates, and names this bundle id.
        var signed = false
        /// Who signed it, checked against its running code: its Team ID, or "apple" for Apple's own.
        var team: String?
        /// In a browser Petal doesn't trust (one whose maker it doesn't know, or whose signature didn't check out) or
        /// another app's web view, or in a browser's own controls: which page it is can't be believed. Nothing fills
        /// there by itself, and nothing is saved for the app.
        var unverified = false
        /// The address that page gives for itself, unverified: said on the card, never trusted.
        var claimedURL: String?

        /// The host shown to the person: the page's (or frame's).
        var host: String? { frameURL.flatMap(VaultSite.host) }
        /// Where a purchase is made: the tab's whole page (a card form often sits in a payment company's frame).
        var shop: String? { (topURL ?? frameURL).flatMap(VaultSite.host) }
        var where_: String { web ? host ?? appName : appName }
    }

    /// What a field is in, from what Petal read around it: a page of a browser it trusts (`web`), a page it can't
    /// verify or a browser's own controls (`unverified`), or an app.
    enum Surface: Equatable { case web, unverified, app }

    /// `webArea`: a web page holds the field; `trusted`: the app is a browser on Petal's list, signed now by its
    /// maker; `browser`: the app is any browser Petal knows of (trusted or not).
    static func surface(webArea: Bool, trusted: Bool, browser: Bool) -> Surface {
        if webArea && trusted { return .web }
        return webArea || browser ? .unverified : .app
    }

    /// Why a page Petal can't verify gets nothing by itself, naming the address it gives as unverified.
    static func unverifiedWhy(_ place: Place) -> String {
        let said = place.claimedURL.flatMap(VaultSite.host).map { " The page says it's \($0), but Petal can't check that." } ?? ""
        return "\(place.appName) isn't a browser Petal can verify pages in, so it can't tell which site this is.\(said) Fill only if you're sure of the address."
    }

    enum Decision: Equatable {
        case fill
        /// A card asks the person first, Don't the default: the place doesn't match.
        case ask(title: String, detail: String)
        /// Payment info before this checkout was allowed: one "Buy?" card for the shop (the page's exact host).
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
    ///   Buy (`checkout`, which Checkout.covers decides): before that, nothing of the card goes into the page;
    /// - contact info and addresses fill freely: they aren't secrets;
    /// - an unsorted secret (Petal doesn't know what it is or where it belongs) always asks, wherever it is;
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
            return .ask(title: question(item, [field], place: place), detail: why)
        case .apiKey:
            guard let why = keyMismatch(item, place) else { return .fill }
            return .ask(title: question(item, [field], place: place), detail: why)
        case .card:
            guard place.web, let frame = place.frameURL, VaultSite.scheme(frame) == "https",
                  VaultSite.scheme(place.topURL ?? frame) == "https", let shop = place.shop else {
                return .refuse("Petal fills payment info only on secure web pages (https).")
            }
            if let tab = place.tabURL.flatMap(VaultSite.host), tab != shop {
                return .refuse("Petal couldn't confirm the page (the tab says \(tab), the page says \(shop)), so it fills no payment info here.")
            }
            return checkout ? .fill : .buy(shop: shop)
        case .contact, .address:
            return .fill
        case .unsorted:
            return .ask(title: question(item, [field], place: place), detail: unsortedWhy(item, place))
        }
    }

    /// Why an unsorted secret is asked about wherever it goes, with what Petal can tell of the place.
    static func unsortedWhy(_ item: VaultItem, _ place: Place) -> String {
        let what = "Petal doesn't know what “\(item.title)” is or where it belongs (it was saved before the vault sorted things), so it can't tell this is the right place. Fill it only if you're sure, and sort it in Settings › Vault so Petal can tell next time."
        if place.unverified { return what + " " + unverifiedWhy(place) }
        if place.web, let problem = pageProblem(place) { return what + " " + problem }
        return what
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
        if place.unverified { return unverifiedWhy(place) }
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
        guard place.signed, let team = place.team else { return "Petal couldn't verify \(place.appName) is the real app (its signature didn't check out)." }
        guard let saved = item.appSigners[place.bundle] else {
            return "Petal doesn't know who made the \(place.appName) this login was saved for, so it can't tell this copy is the same app."
        }
        guard saved == team else { return "This \(place.appName) is signed by someone other than the one the login was saved in: it may be an app made to look like it." }
        return nil
    }

    /// Why an API key doesn't belong where the field is, or nil: it goes into any app, onto this Mac's own pages, and
    /// onto its service's site.
    static func keyMismatch(_ item: VaultItem, _ place: Place) -> String? {
        guard place.web else { return place.unverified ? unverifiedWhy(place) : nil }
        // Only a web page on this Mac (http or https), never a file:// or other address naming localhost.
        let local = { (url: String?) in
            url.map { ["http", "https"].contains(VaultSite.scheme($0) ?? "") && (VaultSite.host($0).map(VaultSite.isLocal) ?? false) } ?? false
        }
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

    /// What's typed for a field: a card's month or year from its expiry, else what's saved. `fourDigitYear`: the
    /// year as the field wants it ("2027" or "27"; nil when it doesn't say: two digits for a year field, the expiry
    /// as saved).
    static func text(_ item: VaultItem, _ field: VaultField, fourDigitYear: Bool? = nil) -> String? {
        switch field {
        case .month: return expiryParts(item[.expiry])?.month
        case .year: return expiryParts(item[.expiry]).map { fourDigitYear == true ? $0.year4 : $0.year2 }
        case .expiry:
            if let four = fourDigitYear, let parts = expiryParts(item[.expiry]) { return "\(parts.month)/\(four ? parts.year4 : parts.year2)" }
            fallthrough
        default: let value = typed(field, item[field]); return value.isEmpty ? nil : value
        }
    }

    /// What goes into a field for `value`: a card number or security code as ASCII digits only (whatever script or
    /// grouping it was saved in: "4111 1111 1111 1111" would not fit a 16-character field); anything else as it is.
    static func typed(_ field: VaultField, _ value: String) -> String {
        guard field == .number || field == .securityCode else { return value }
        return String(value.compactMap { UIMap.SecretIndex.digit($0).map { Character(String($0)) } })
    }

    /// The item as it's kept: a card number or security code that is only digits and separators ("4111 1111 …",
    /// "４１１１-…") as ASCII digits. One with letters in it stays as typed.
    static func normalized(_ item: VaultItem) -> VaultItem {
        guard item.kind == .card else { return item }
        var item = item
        for field in [VaultField.number, .securityCode] {
            let value = item[field]
            guard value.contains(where: { UIMap.SecretIndex.digit($0) != nil }),
                  value.allSatisfy({ UIMap.SecretIndex.digit($0) != nil || !($0.isLetter || $0.isNumber) }) else { continue }
            item[field] = typed(field, value)
        }
        return item
    }

    /// After typing `typed` (a card number or security code's digits), whether the field holds all of it: its text
    /// (`value`, read only to count its digits; nil for a secure field) has as many digits, else it holds as many
    /// characters (`count`). nil when the field says neither, so Petal can't tell.
    static func fits(_ typed: String, value: String?, count: Int?) -> Bool? {
        if let value { return value.filter { UIMap.SecretIndex.digit($0) != nil }.count >= typed.count }
        if let count { return count >= typed.count }
        return nil
    }

    /// Whether a year (or an expiry's year) goes in as four digits: as the AI said (`format` "YYYY" or "YY"), else as
    /// the field says of itself (a placeholder or label like "MM/YYYY", "YY", "AAAA" or "2027"), else by its room (4
    /// or 2 characters for a year, 7 or 5 for an expiry). nil when nothing says.
    static func fourDigitYear(_ field: VaultField, format: String?, hints: [String], maxLength: Int?) -> Bool? {
        func style(_ text: String) -> Bool? {
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                if ["yyyy", "aaaa", "jjjj"].contains(where: { token.hasSuffix($0) }) { return true }
                if ["yy", "aa", "jj"].contains(where: { token.hasSuffix($0) }) && (token.count == 2 || token.hasPrefix("mm")) { return false }
            }
            return nil
        }
        if let format, let said = style(format) { return said }
        for hint in hints {
            if let said = style(hint) { return said }
            // A sample year ("2027", "MM/2027").
            if hint.range(of: #"(^|[^0-9])20[0-9]{2}([^0-9]|$)"#, options: .regularExpression) != nil { return true }
        }
        switch (field, maxLength) {
        case (.year, 4?), (.expiry, 7?): return true
        case (.year, 2?), (.expiry, 5?): return false
        default: return nil
        }
    }

    /// Which of a year menu's items is the card's year, whether the menu says "2027" or "27".
    static func pickYear(_ expiry: String, from options: [String]) -> Int? {
        guard let parts = expiryParts(expiry) else { return nil }
        return pick(parts.year4, from: options) ?? pick(parts.year2, from: options)
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
        // An unsorted secret is one value, whatever the AI calls it.
        if kind == .unsorted, [.password, .value].contains(found) { return .value }
        return found
    }

    /// Why the place a field is in now isn't the one Petal decided on (another page, another app, another tab), or
    /// nil: read again right before filling, so a page that moved on meanwhile never gets it. `samePage`: the tab's
    /// page must also still be at the same path (payment info: the checkout page Buy was said on).
    static func moved(from then: Place, to now: Place, samePage: Bool = false) -> String? {
        if then.web != now.web || then.bundle != now.bundle || then.unverified != now.unverified {
            return "That field isn't in the same app or page anymore; nothing was filled. Call petal_ui again."
        }
        func origin(_ url: String?) -> String { url.map { "\(VaultSite.scheme($0) ?? "")://\(VaultSite.host($0) ?? "")" } ?? "" }
        guard then.web else {
            // A page Petal can't verify: at least the address it gave when the person said yes.
            if then.unverified, origin(then.claimedURL) != origin(now.claimedURL) {
                return "The page changed (it says \(now.claimedURL.flatMap(VaultSite.host) ?? "another page") now); nothing was filled. Call petal_ui again."
            }
            return then.team == now.team ? nil : "Petal couldn't verify \(now.appName) is the same app anymore; nothing was filled."
        }
        if origin(then.frameURL) != origin(now.frameURL) || origin(then.topURL) != origin(now.topURL)
            || (then.tab.page != nil && !UIMap.same(then.tab.page, now.tab.page))
            || (samePage && path(then.topURL ?? then.frameURL) != path(now.topURL ?? now.frameURL)) {
            return "The page changed (it's \(now.host ?? "another page") now); nothing was filled. Call petal_ui again."
        }
        return nil
    }

    /// An address's path ("/checkout/payment"), without its query or fragment; "" when it has none or can't be read.
    static func path(_ url: String?) -> String {
        url.flatMap { URLComponents(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))?.path } ?? ""
    }

    /// The one question for filling `fields` of `item` where it doesn't match: "Fill your github.com username and
    /// password on githuh.com?".
    static func question(_ item: VaultItem, _ fields: [VaultField], place: Place) -> String {
        if [.apiKey, .unsorted].contains(item.kind) { return "Fill your “\(item.title)” \(place.web ? "on" : "in") \(place.where_)?" }
        var words: [String] = []
        for field in fields where !words.contains(field.words) { words.append(field.words) }
        let list = words.count <= 1 ? words.joined() : words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        return "Fill your \(item.sites.first ?? item.title) \(list) \(place.web ? "on" : "in") \(place.where_)?"
    }

    /// Where a field's value goes, to tell one fill's fields apart: a page's origin (for payment info, the shop's:
    /// a card form's fields often sit in a payment company's frames), or an app.
    static func destination(_ kind: VaultKind, _ place: Place) -> String {
        if place.unverified {
            let claimed = place.claimedURL.map { "\(VaultSite.scheme($0) ?? "")://\(VaultSite.host($0) ?? "")" } ?? ""
            return "unverified:\(place.bundle):\(claimed)"
        }
        guard place.web else { return "app:" + place.bundle }
        let url = kind == .card ? place.topURL ?? place.frameURL : place.frameURL
        return url.map { "\(VaultSite.scheme($0) ?? "")://\(VaultSite.host($0) ?? "")" } ?? "unreadable"
    }

    /// Why one fill's fields can't go together, or nil: a login's, key's or card's fields in more than one page or
    /// app (a login form with its password in another site's frame). One card answers for one place only.
    static func mixed(_ kind: VaultKind, _ places: [Place]) -> String? {
        guard [.login, .apiKey, .card, .unsorted].contains(kind) else { return nil }
        var seen: [String] = [], names: [String] = []
        for place in places where !seen.contains(destination(kind, place)) {
            seen.append(destination(kind, place))
            let name = kind == .card ? place.shop ?? place.where_ : place.where_
            if !names.contains(name) { names.append(name) }
        }
        guard seen.count > 1 else { return nil }
        let said = names.count > 1 ? " (\(names.joined(separator: ", ")))" : ""
        return "Those fields are in different pages or apps\(said): Petal fills one place at a time, so nothing was filled. Fill each place's fields on their own."
    }

    /// The first field of a fill Petal won't do by itself (`index`, and why), or nil: what new_login checks before it
    /// makes, saves and fills a password. Asking isn't enough there: every field must fill by itself.
    static func unasked(_ item: VaultItem, _ fields: [VaultField], targets: [Target], places: [Place]) -> (index: Int, why: String)? {
        if let mixed = mixed(item.kind, places) { return (0, mixed) }
        for index in fields.indices {
            switch decide(item, fields[index], target: targets[index], place: places[index]) {
            case .fill: continue
            case .refuse(let why), .ask(_, let why): return (index, why)
            case .buy: return (index, "Payment info waits for the Buy card.")
            }
        }
        return nil
    }

    /// What a login typed into Petal's card is saved for: the page Petal read, or the app once Petal confirmed who
    /// signed it. Never a browser (or a page it can't verify): a login there is for no app at all.
    static func bind(_ item: inout VaultItem, to place: Place) {
        if place.web {
            if let host = place.host { item.sites = [host] }
        } else if !place.unverified, place.signed, let team = place.team {
            item.apps = [place.bundle]
            item.appSigners = [place.bundle: team]
        }
    }

    /// Before a request card that fills fields: a field Petal won't fill whatever's typed (`refusal`, its index), or
    /// what doesn't match where the fields are (`warning`, said on the card). `saved`: the field whose place the
    /// answer is saved for (a login's password field's).
    struct Requested: Equatable {
        var refusal: String?
        var index = 0
        var warning: String?
    }

    static func request(_ kind: VaultKind, _ fields: [VaultField], targets: [Target], places: [Place], saved: Int) -> Requested {
        guard !fields.isEmpty else { return Requested() }
        if let mixed = mixed(kind, places) { return Requested(refusal: mixed) }
        var probe = VaultItem(kind: kind, title: "x")
        bind(&probe, to: places[saved])
        for field in kind.fields { probe[field] = "x" }
        probe[.expiry] = "01/30"
        var warnings: [String] = []
        for index in fields.indices {
            switch decide(probe, fields[index], target: targets[index], place: places[index]) {
            case .fill: continue
            case .refuse(let why): return Requested(refusal: why, index: index)
            case .buy: return Requested(refusal: "Payment info waits for the Buy card: Petal doesn't fill it from a request.", index: index)
            case .ask(_, let why): if !warnings.contains(why) { warnings.append(why) }
            }
        }
        return Requested(warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    /// After a request card was answered: what the completed item (the site or service the person typed, the login
    /// bound to the page) does where its fields are, decided as any fill is, before a key goes. What the request card
    /// already warned about (`warned`) isn't asked again; anything else that doesn't match is one card, Don't the
    /// default.
    enum Recheck: Equatable {
        case fill
        case ask(title: String, detail: String)
        case refuse(index: Int, why: String)
    }

    static func recheck(_ item: VaultItem, _ fields: [VaultField], targets: [Target], places: [Place], warned: String?) -> Recheck {
        if let mixed = mixed(item.kind, places) { return .refuse(index: 0, why: mixed) }
        var asked: [VaultField] = [], reasons: [String] = []
        var at: Place?
        for index in fields.indices {
            switch decide(item, fields[index], target: targets[index], place: places[index]) {
            case .fill: continue
            case .refuse(let why): return .refuse(index: index, why: why)
            case .buy: return .refuse(index: index, why: "Payment info waits for the Buy card: Petal doesn't fill it from a request.")
            case .ask(_, let why):
                if let warned, warned.contains(why) { continue }
                asked.append(fields[index])
                if !reasons.contains(why) { reasons.append(why) }
                at = at ?? places[index]
            }
        }
        guard let at else { return .fill }
        return .ask(title: question(item, asked, place: at), detail: reasons.joined(separator: " "))
    }

    /// The person said Buy on one "Buy on <host>?" card: payment info fills there with that card, in that window
    /// and tab, on that page, for the rest of that reply. Another host (a subdomain or another shop), page, tab,
    /// window, card or reply asks again; the window showing anything else (another page or tab, even of the same
    /// shop) ends it, and coming back doesn't bring it back.
    struct Checkout: Equatable {
        /// This Buy's own: revoked the moment the Buy is over (its window moved on or closed, another Buy replaced it,
        /// its reply ended), which stops every payment fill made under it, queued or under way.
        let token = BuyToken()
        /// The shop's exact host (the tab's whole page).
        var host: String
        /// The shop page's path when Buy was said.
        var path: String
        var window: UInt32
        /// The tab Buy was said in: the browser's own id for it (if it gave one then) and its page.
        var tab: Tab
        var card: String
        var turn: String

        init(host: String, path: String, window: UInt32, tab: Tab, card: String, turn: String) {
            self.host = host
            self.path = path
            self.window = window
            self.tab = tab
            self.card = card
            self.turn = turn
        }

        /// The Buy for `place`, or nil when Petal can't tell which tab and page it is.
        init?(place: Place, window: UInt32, card: String, turn: String) {
            guard place.web, let host = place.shop, place.tab.page != nil else { return nil }
            self.init(host: host, path: Vault.path(place.topURL ?? place.frameURL), window: window, tab: place.tab, card: card, turn: turn)
        }

        /// `place` is still the tab and page Buy was said on: its page the same (and the browser's id for the tab,
        /// when it gave one then), on the same host and path, the browser's own answer agreeing.
        func same(_ place: Place) -> Bool {
            guard place.web, place.shop == host, Vault.path(place.topURL ?? place.frameURL) == path else { return false }
            if let tabHost = place.tabURL.flatMap(VaultSite.host), tabHost != host { return false }
            if tab.id != nil, place.tab.id != tab.id { return false }
            guard let page = tab.page, let now = place.tab.page else { return false }
            return UIMap.same(page, now)
        }

        func covers(_ place: Place, window: UInt32?, card: String, turn: String) -> Bool {
            !token.revoked && turn == self.turn && card == self.card && window == self.window && same(place)
        }

        /// Its window, seen showing anything but the tab and page Buy was said on: the checkout is over.
        func left(_ place: Place, window: UInt32?) -> Bool {
            window == self.window && !same(place)
        }

        /// What's left of `checkouts` once `window` was seen showing `place` (by any read or act, or after its title
        /// changed): a Buy whose window shows another tab or page is over, and coming back doesn't bring it back.
        static func seen(_ checkouts: [Checkout], place: Place, window: UInt32?) -> [Checkout] {
            checkouts.filter { !$0.left(place, window: window) }
        }

        /// What's left of `checkouts` once a new Buy card is about to show for `window` (another card on the same
        /// checkout, say): every Buy in that window ends then, whatever the person answers (Buy, Don't, closing the
        /// card, or no answer), so an earlier card's Buy never stays usable beside a Don't.
        static func asking(_ checkouts: [Checkout], window: UInt32) -> [Checkout] {
            checkouts.filter { $0.window != window }
        }

        /// Revokes every Buy in `before` that isn't in `after` (however it went), so nothing filled under it goes on.
        static func revoke(_ before: [Checkout], keeping after: [Checkout]) {
            let kept = Set(after.map { ObjectIdentifier($0.token) })
            for gone in before where !kept.contains(ObjectIdentifier(gone.token)) { gone.token.revoke() }
        }
    }

    /// A Buy's token: valid until revoked, for good. Read on the act queue, revoked on the main thread.
    final class BuyToken: Equatable, @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var revoked: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func revoke() { lock.lock(); flag = true; lock.unlock() }
        static func == (a: BuyToken, b: BuyToken) -> Bool { a === b }
    }

    /// Every way a value typed into a field may show up in text (a card number in its forms), for the redaction.
    static func secrets(_ field: VaultField, _ value: String) -> [String] {
        guard field.isSecret else { return [] }
        var item = VaultItem(kind: field == .password ? .login : field == .value ? .apiKey : .card, title: "")
        item.fields[field.rawValue] = value
        return secrets(item)
    }

    /// One vault record in the Keychain, as read: an item (its account `item:<id>`, its data the item as JSON, marked
    /// as Petal's own format or proven by its id), else a secret from before kinds kept under a name (which may
    /// itself start with "item:"). Never lost: what doesn't read as an item is an old secret.
    enum Stored: Equatable {
        case item(VaultItem)
        case legacy(name: String, secret: String)
        case unreadable
    }

    /// The Keychain attribute (kSecAttrGeneric) Petal marks its items' format with.
    static let format = "petal.vault.item.1"

    static func stored(account: String, data: Data, marked: Bool) -> Stored {
        if account.hasPrefix("item:"), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["kind"] is String, let item = try? JSONDecoder().decode(VaultItem.self, from: data),
           marked || account == "item:" + item.id {
            return .item(item)
        }
        guard let secret = String(data: data, encoding: .utf8) else { return .unreadable }
        return .legacy(name: account, secret: secret)
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
        /// Petal's own export: its items keep their ids, and two with different ids are never the same.
        var petal = false
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
        case "unsorted": return .unsorted
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
        if let export = try? JSONDecoder().decode(Export.self, from: data), export.petalVault >= 1 { return Imported(items: export.items, petal: true) }
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

    /// The same thing saved twice: the same id (Petal's own export), else a login for the same site or app and username,
    /// a card with the same number, contact info with the same email (or name), an address with every line, city,
    /// region, postal code and country the same (case, accents and spacing aside) for the same contact, an API key
    /// with the same title.
    static func same(_ a: VaultItem, _ b: VaultItem) -> Bool {
        if a.id == b.id { return true }
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .login:
            // The same username for the same site or app; logins saved for nowhere are never the same as each other.
            guard a.username.lowercased() == b.username.lowercased() else { return false }
            let left = Set(a.sites.map { "site:" + VaultSite.plain($0) } + a.apps.map { "app:" + $0.lowercased() })
            let right = Set(b.sites.map { "site:" + VaultSite.plain($0) } + b.apps.map { "app:" + $0.lowercased() })
            return !left.isEmpty && !left.isDisjoint(with: right)
        case .card:
            let digits = a[.number].filter(\.isNumber)
            return !digits.isEmpty && digits == b[.number].filter(\.isNumber)
        case .contact:
            if !a[.email].isEmpty || !b[.email].isEmpty { return a[.email].lowercased() == b[.email].lowercased() }
            return !a[.name].isEmpty && a[.name].lowercased() == b[.name].lowercased()
        case .address:
            let parts: [VaultField] = [.street, .street2, .city, .region, .postalCode, .country]
            guard parts.contains(where: { !a[$0].isEmpty }) else { return false }
            return parts.allSatisfy { addressPart(a[$0], $0) == addressPart(b[$0], $0) } && a[.contact] == b[.contact]
        case .apiKey, .unsorted:
            return a.title.lowercased() == b.title.lowercased()
        }
    }

    /// A line of an address as compared: case, accents and spacing aside, a country by one of its names.
    static func addressPart(_ text: String, _ field: VaultField) -> String {
        let folded = fold(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard field == .country else { return folded }
        return countryNames.first { $0.contains(folded) }?.first ?? folded
    }

    struct Merge {
        /// New items, and saved ones the import changed, to save.
        var save: [VaultItem] = []
        var added = 0
        /// Already there, and changed: Petal's own export newer than what's saved, or details that hold no secret.
        /// Their titles, to say so.
        var updated: [String] = []
        var same = 0
        /// Saved items the import would give another password, security code or key with nothing reliable to say
        /// which is newer (another app's export, or Petal's with the same date): kept as they are. Each as the import
        /// would make it (the saved item's id, the import's secret), to save instead if the person says so.
        var conflicts: [VaultItem] = []
        /// In Petal's own export but older than what's saved: kept as they are.
        var older = 0
        /// Saved logins the import added sites or apps to (the same login, also kept for somewhere else).
        var widened = 0
    }

    /// An import against what's saved. Something already there changes nothing unless it differs. Matched by its id
    /// (Petal's own export, which keeps ids and dates): a newer entry is the whole item again (every field, its
    /// title, sites and apps), restored as it was backed up. Matched by what it holds (the same site and username,
    /// card number, …): a login takes only the import's password, the sites and apps the saved one doesn't have yet
    /// (and its notes where none are saved, or Petal's newer ones; another app's other title or notes are offered as a
    /// conflict, never dropped); anything else takes the import's fields. Either way a secret (a password, security
    /// code or key) is replaced only when Petal's own export says it's newer: from any other export, a different secret is a
    /// conflict, kept as it is and said. Petal's export older than what's saved changes nothing. An entry repeated
    /// with the same id (Petal's export) lands on one item, the later winning.
    /// Matching is one to one, whatever the export: each entry is the saved item with its id, else one alike that no
    /// other entry took; when every one alike is taken, it's added as an item of its own. So nothing in a file is
    /// lost: only the very same thing again (every field, secrets and the rest, the same as a saved item no other
    /// entry took, or as an earlier entry of a file from another app) counts as already there, and each conflict is
    /// its own entry's. Petal's export's items with different ids stay apart however alike, each with its own
    /// record and details; an imported address whose contact turned out to be one already saved is linked to that one.
    static func merge(existing: [VaultItem], incoming: [VaultItem], petal: Bool = false, at date: Date = Date()) -> Merge {
        var result = Merge()
        // Card numbers and codes compared as they're kept (digits only), however each side wrote them.
        var current = existing.map(normalized)
        let incoming = incoming.map(normalized)
        let fromFile = Set(incoming.map(\.id))
        var touched: [String: Int] = [:]   // item id → index in result.save
        var renamed: [String: String] = [:]   // an imported contact's id → the saved one's
        // A saved item matched by what it holds (not its id) → the entry in the file that took it: one each, so two
        // of the file's entries alike (the same site and username) never fold into one or fight over one conflict.
        var claimed: [String: String] = [:]
        // Another app's file: its entries so far, as the file has them (its rows have no ids to tell repeats apart).
        var earlier: [VaultItem] = []
        func free(_ saved: VaultItem, for item: VaultItem) -> Bool {
            !fromFile.contains(saved.id) && (claimed[saved.id] ?? item.id) == item.id
        }
        // Contacts first, so addresses can follow their contact.
        let ordered = incoming.filter { $0.kind != .address } + incoming.filter { $0.kind == .address }
        for var item in ordered {
            if item.kind == .address, let link = renamed[item[.contact]] { item[.contact] = link }
            defer { if !petal { earlier.append(item) } }
            var index = current.firstIndex { $0.id == item.id }
            let byID = petal && index != nil
            if index == nil {
                // The very same thing again: a row this file already had, or a saved item no other entry took.
                if let twin = earlier.first(where: { identical($0, item) }) {
                    if item.kind == .contact { renamed[item.id] = renamed[twin.id] ?? twin.id }
                    result.same += 1
                    continue
                }
                if let saved = current.first(where: { free($0, for: item) && identical($0, item) }) {
                    claimed[saved.id] = item.id
                    if saved.kind == .contact { renamed[item.id] = saved.id }
                    result.same += 1
                    continue
                }
                // One alike that no other entry took; one an entry of the file has by its id is that entry's.
                index = current.firstIndex { free($0, for: item) && same($0, item) }
            }
            if let index {
                let saved = current[index]
                if saved.id != item.id { claimed[saved.id] = item.id }
                if saved.kind == .contact { renamed[item.id] = saved.id }
                var next = saved
                // Another app's login whose title or notes differ from what's kept: the import's as well, offered as
                // a conflict, so its details are never dropped without a word.
                var detailed: VaultItem?
                // A login the import only adds sites or apps to: said as such, not as something newer.
                var onlyPlaces = false
                if byID {
                    // Petal's own backup of this very item: all of it, as backed up.
                    next = item
                } else if saved.kind == .login {
                    if !item[.password].isEmpty { next[.password] = item[.password] }
                    let newer = petal && item.updated > saved.updated
                    if next[.notes].isEmpty || (newer && !item[.notes].isEmpty) { next[.notes] = item[.notes] }
                    let before = next
                    next = withPlaces(next, from: item)
                    onlyPlaces = identical(before, saved) && !identical(next, saved)
                    if !petal { detailed = withDetails(next, from: item) }
                } else {
                    next.fields = saved.fields.merging(item.fields) { _, new in new }
                    next.sites = saved.sites + item.sites.filter { !saved.sites.contains($0) }
                    next.title = item.title.isEmpty ? saved.title : item.title
                }
                guard !identical(next, saved) || detailed != nil else { result.same += 1; continue }
                let replaces = replacesSecret(saved, with: next)
                if petal {
                    // Petal's own dates say which is newer.
                    if item.updated < saved.updated || (item.updated == saved.updated && !replaces) { result.older += 1; continue }
                    if item.updated == saved.updated {
                        result.conflicts.removeAll { $0.id == next.id }
                        result.conflicts.append(next)
                        continue
                    }
                    next.updated = item.updated
                } else if replaces {
                    // Only this entry has this saved item, so the conflict is its own (a repeat of it replaces it).
                    var offered = detailed ?? next
                    result.conflicts.removeAll { $0.id == offered.id }
                    offered.updated = date
                    result.conflicts.append(offered)
                    continue
                } else {
                    next.updated = date
                }
                // A later entry with the same id that's taken wins over its earlier conflict.
                result.conflicts.removeAll { $0.id == next.id }
                if !identical(next, saved) {
                    if saved.kind == .login, !byID, !identical(withPlaces(saved, from: item), saved) { result.widened += 1 }
                    current[index] = next
                    if !onlyPlaces, !result.updated.contains(next.title) { result.updated.append(next.title) }
                    if let at = touched[next.id] { result.save[at] = next } else { touched[next.id] = result.save.count; result.save.append(next) }
                }
                if var detailed {
                    // The secrets agree; the title or notes don't: yours stay, the import's are offered.
                    detailed.updated = date
                    result.conflicts.append(detailed)
                }
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

    /// `saved` with the sites and apps `item` has that it doesn't (a site compared without its scheme or "www.", an
    /// app case aside). An app added this way has no signer saved, so it asks before it fills there.
    static func withPlaces(_ saved: VaultItem, from item: VaultItem) -> VaultItem {
        var out = saved
        var sites = Set(saved.sites.map(VaultSite.plain)), apps = Set(saved.apps.map { $0.lowercased() })
        for site in item.sites where sites.insert(VaultSite.plain(site)).inserted { out.sites.append(site) }
        for app in item.apps where apps.insert(app.lowercased()).inserted { out.apps.append(app) }
        return out
    }

    /// `merged` with `item`'s title and notes where `item` has them, or nil when that changes nothing.
    static func withDetails(_ merged: VaultItem, from item: VaultItem) -> VaultItem? {
        var detailed = merged
        if !item.title.isEmpty { detailed.title = item.title }
        if !item[.notes].isEmpty { detailed[.notes] = item[.notes] }
        return identical(detailed, merged) ? nil : detailed
    }

    /// The very same item, its id and date aside: its kind, title, every field (secrets, notes and the rest), sites,
    /// apps and who signed them.
    static func identical(_ a: VaultItem, _ b: VaultItem) -> Bool {
        a.kind == b.kind && a.title == b.title && a.fields == b.fields && Set(a.sites) == Set(b.sites)
            && Set(a.apps) == Set(b.apps) && a.appSigners == b.appSigners
    }

    /// `next` has a secret `saved` holds, different (not one `saved` didn't have yet).
    static func replacesSecret(_ saved: VaultItem, with next: VaultItem) -> Bool {
        VaultField.allCases.contains { $0.isSecret && $0 != .notes && !saved[$0].isEmpty && saved[$0] != next[$0] }
    }
}

/// Which site a web address is, and whether something saved for one site belongs on a page.
enum VaultSite {
    /// The Public Suffix List (publicsuffix.org, its ICANN and private sections; `macos/Resources`, copied into the
    /// app by build.sh): the names under which anyone can register one of their own ("co.uk", "uk.com", "github.io",
    /// every "*.ck" but "www.ck"), so "a.co.uk" and "b.co.uk", or "me.github.io" and "evil.github.io", are strangers.
    struct Suffixes {
        private var rules = Set<String>()
        /// "ck" for "*.ck".
        private var wildcards = Set<String>()
        /// "www.ck" for "!www.ck".
        private var exceptions = Set<String>()
        /// The top-level names the list has rules for: any other is a name it doesn't cover.
        private var tops = Set<String>()

        init(_ text: String) {
            for line in text.split(whereSeparator: \.isNewline) {
                // A rule is a line's first word; comments start with //.
                guard let word = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, !word.hasPrefix("//") else { continue }
                let rule = word.lowercased()
                if rule.hasPrefix("!") { exceptions.insert(String(rule.dropFirst())) }
                else if rule.hasPrefix("*.") { wildcards.insert(String(rule.dropFirst(2))) }
                else { rules.insert(rule) }
                if let top = rule.split(separator: ".").last { tops.insert(String(top)) }
            }
        }

        var isEmpty: Bool { rules.isEmpty && wildcards.isEmpty }

        /// The public suffix of `host` by the list's own algorithm (an exception wins, else the longest rule, else
        /// the top-level name); nil when the list has no rule for its top-level name.
        func suffix(of host: String) -> String? {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard let top = labels.last, tops.contains(top), !labels.contains(where: \.isEmpty) else { return nil }
            for start in labels.indices where exceptions.contains(labels[start...].joined(separator: ".")) {
                return labels[(start + 1)...].joined(separator: ".")
            }
            for start in labels.indices {
                let candidate = labels[start...].joined(separator: ".")
                if rules.contains(candidate) { return candidate }
                if start + 1 < labels.count, wildcards.contains(labels[(start + 1)...].joined(separator: ".")) { return candidate }
            }
            return top
        }

        /// The name someone registered: one label more than the suffix; nil for a public suffix itself or a name
        /// the list doesn't cover.
        func registrable(_ host: String) -> String? {
            guard let suffix = suffix(of: host), host != suffix, host.hasSuffix("." + suffix) else { return nil }
            let rest = host.dropLast(suffix.count + 1)
            guard let label = rest.split(separator: ".").last else { return nil }
            return "\(label).\(suffix)"
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var list: Suffixes?
    nonisolated(unsafe) private static var loading = false

    /// The list, once read; the first ask starts reading it (off the main thread) from the app's copy. Until then,
    /// nil: a login fills by itself only on its saved host and what's under it.
    static func suffixes() -> Suffixes? {
        lock.lock()
        defer { lock.unlock() }
        if list == nil, !loading, let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat") {
            loading = true
            DispatchQueue.global(qos: .utility).async { load(url) }
        }
        return list
    }

    /// Reads the list from `url` (on the caller's thread; never the main one). False when it isn't there.
    @discardableResult
    static func load(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let read = Suffixes(text)
        lock.lock()
        if !read.isEmpty { list = read }
        lock.unlock()
        return !read.isEmpty
    }

    /// Starts reading the list now, so it's there by the time a field is filled.
    static func preload() { _ = suffixes() }

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

    /// The name someone registered: "github.com" for "gist.github.com", "example.co.uk" for "www.example.co.uk",
    /// "me.github.io" for "me.github.io". Conservative: until the list is read, or for a name it doesn't cover, the
    /// host itself (fewer pages match).
    static func registrable(_ text: String) -> String {
        guard let host = host(text) else { return text.lowercased() }
        if isAddress(host) || isLocal(host) { return host }
        return suffixes()?.registrable(host) ?? host
    }

    /// A page on `host` belongs to something saved for `saved`: the same host, or under the saved site's registrable
    /// name ("accounts.github.com" for "github.com"). An IP address, this Mac, or a public suffix saved as a site
    /// ("github.io") only matches itself. Until the list is read, or for a name it doesn't cover: the saved host and
    /// what's under it only.
    static func matches(host: String, saved: String) -> Bool {
        guard let page = self.host(host), let site = self.host(saved) else { return false }
        if page == site { return true }
        if isAddress(page) || isAddress(site) || isLocal(site) || isLocal(page) { return false }
        guard let list = suffixes(), list.suffix(of: site) != nil, list.suffix(of: page) != nil else { return page.hasSuffix("." + site) }
        guard let root = list.registrable(site) else { return false }
        return page == root || page.hasSuffix("." + root)
    }
}
