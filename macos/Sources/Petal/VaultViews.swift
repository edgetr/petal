import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The card that asks for something

/// What Petal's card asks the person to type for the vault (Assist.Request.form): a login (with "Save to your vault"
/// when Submit also fills the page), contact info, an address, payment info or an API key. What they type goes to
/// Petal only; the AI hears "saved", "filled" or "the person closed it".
struct VaultForm: Equatable {
    var kind: VaultKind
    /// The site (or app) Petal read the fields are on, never one the AI named.
    var place = ""
    /// Submit fills the page's fields too.
    var fills = false
    var title = ""
    var username = ""
    /// An API key's service, Petal's reading of the page to start with.
    var site = ""

    var heading: String {
        switch kind {
        case .login: "Add a login to your vault"
        case .contact: "Add contact info"
        case .address: "Add an address"
        case .card: "Add payment info"
        case .apiKey: "Add an API key"
        }
    }

    var footnote: String {
        switch kind {
        case .login: place.isEmpty ? "Petal AI never sees it." : "Petal AI never sees it. Only filled on \(place)."
        case .card: "Petal AI never sees the card number or security code. Petal asks you before it pays."
        case .apiKey: "Petal AI never sees it."
        case .contact, .address: "Petal AI sees this, so it can fill it in for you."
        }
    }

    static func placeName(_ place: Vault.Place) -> String { place.web ? place.host ?? place.appName : place.appName }

    struct Answer: Equatable {
        var values: [VaultField: String] = [:]
        var save = true
        var title = ""
        var site = ""
    }

    /// Enough to keep: a login's password, a card's number, an API key, an address's first line, a contact's name,
    /// email or phone.
    func complete(_ answer: Answer) -> Bool {
        func has(_ field: VaultField) -> Bool { !(answer.values[field] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        switch kind {
        case .login: return has(.password)
        case .card: return has(.number)
        case .apiKey: return has(.value) && !answer.title.trimmingCharacters(in: .whitespaces).isEmpty
        case .address: return has(.street)
        case .contact: return has(.name) || has(.email) || has(.phone)
        }
    }
}

/// The card's form, in Petal's glass: a heading with ×, labelled fields (a password with an eye), "Save to your
/// vault" on by default when Submit also fills the page, the footnote, and Submit.
struct VaultFormView: View {
    @Environment(PetalApp.self) private var app
    let request: Assist.Request
    let form: VaultForm
    @State private var answer = VaultForm.Answer()
    @State private var showing: Set<VaultField> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark") { app.assist.choose(.no, for: request.id) }
            }
            if !request.detail.isEmpty {
                Text(request.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if [.apiKey, .address].contains(form.kind) {
                labelled(form.kind == .address ? "Label (Home, Work…)" : "Name") { TextField(form.kind == .address ? "Home" : "OpenAI", text: $answer.title) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row, id: \.self) { field in labelled(field.label(form.kind)) { entry(field) } }
                }
            }
            if form.kind == .apiKey {
                labelled("Service (website)") { TextField("platform.openai.com", text: $answer.site) }
            }
            if form.fills && form.kind == .login {
                Toggle("Save to your vault", isOn: $answer.save).toggleStyle(.checkbox).font(.system(size: 13))
            }
            HStack(alignment: .center, spacing: 10) {
                Text(form.footnote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(form.fills ? "Submit" : "Save") { submit() }
                    .buttonStyle(.glassProminent).tint(Color(nsColor: app.accent))
                    .disabled(!form.complete(answer))
            }
        }
        .onAppear {
            answer.title = form.title
            answer.site = form.site
            if !form.username.isEmpty { answer.values[.username] = form.username }
        }
    }

    /// The fields, two to a line where they're short (city and postal code, region and country, expiry and code).
    private var rows: [[VaultField]] {
        switch form.kind {
        case .address: [[.name], [.street], [.street2], [.city, .postalCode], [.region, .country], [.phone]]
        case .card: [[.name], [.number], [.expiry, .securityCode]]
        case .contact: [[.name, .relationship], [.email], [.phone]]
        default: form.kind.fields.map { [$0] }
        }
    }

    private func submit() {
        guard form.complete(answer) else { return }
        var typed = answer
        if !form.fills || form.kind != .login { typed.save = true }
        app.assist.choose(.once, typed: typed, for: request.id)
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder).controlSize(.large)
        }
    }

    private func binding(_ field: VaultField) -> Binding<String> {
        Binding(get: { answer.values[field] ?? "" }, set: { answer.values[field] = $0 })
    }

    @ViewBuilder private func entry(_ field: VaultField) -> some View {
        if field.isSecret {
            HStack(spacing: 6) {
                if showing.contains(field) { TextField("", text: binding(field)).onSubmit(submit) }
                else { SecureField("", text: binding(field)).onSubmit(submit) }
                Button {
                    if showing.contains(field) { showing.remove(field) } else { showing.insert(field) }
                } label: {
                    Image(systemName: showing.contains(field) ? "eye.slash" : "eye").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(showing.contains(field) ? "Hide" : "Show")
            }
        } else {
            TextField(field == .relationship ? "girlfriend, mom, me…" : "", text: binding(field)).onSubmit(submit)
        }
    }
}

// MARK: - Settings › Vault

/// Every item in the vault: tabs by kind with counts, search, a new item of each kind, each editable; showing a
/// password, card number, security code or key asks for Touch ID or the Mac's password first. Import (Apple
/// Passwords, Chrome, Proton Pass, Petal) by button or drop, and export (Petal's file, or logins as CSV) after Touch ID.
struct VaultSettings: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.snapshotting) private var snapshotting
    private var model: VaultModel { VaultModel.shared }
    @State private var tab: VaultKind?
    @State private var search = ""
    @State private var editing: VaultItem?
    @State private var isNew = false
    @State private var imported: VaultModel.Imported?
    @State private var exported: String?
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                tabs
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    Menu {
                        ForEach(VaultKind.allCases) { kind in
                            Button { start(kind) } label: { Label(kind.name, systemImage: kind.symbol) }
                        }
                    } label: {
                        Label("New item", systemImage: "plus")
                    }
                    .menuStyle(.button).buttonStyle(.glass).fixedSize()
                }
            }
            if let editing {
                VaultEditor(item: editing, isNew: isNew) { self.editing = nil }
                    .id(editing.id)
            }
            Card {
                let shown = filtered
                if !model.loaded && !snapshotting {
                    ProgressView().controlSize(.small)
                } else if model.unreadable {
                    HStack {
                        Text("Your vault can't be read right now. The Keychain didn't answer, or the Mac is locked.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try Again") { model.load() }.buttonStyle(.glass)
                    }
                } else if shown.isEmpty {
                    Text(model.items.isEmpty ? "Nothing yet. Add an item, import an export, or let Petal AI ask for what it needs." : "Nothing matches.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(shown) { item in
                    Button { isNew = false; editing = item } label: { VaultRow(item: item, showKind: tab == nil) }
                        .buttonStyle(.plain)
                }
            }
            transfer
            Text("Petal AI never sees a password, card number, security code or key. It sees usernames, contact info and addresses so it can type them in for you.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .onAppear { if !snapshotting { model.load() } }
        .modifier(DropExport(on: !snapshotting, dropping: $dropping) { importFile($0) })
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            tabButton(nil, "All", model.items.count)
            ForEach(VaultKind.allCases) { kind in tabButton(kind, kind.plural, model.items.filter { $0.kind == kind }.count) }
        }
    }

    private func tabButton(_ kind: VaultKind?, _ title: String, _ count: Int) -> some View {
        Button { tab = kind } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: tab == kind ? .semibold : .regular))
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .glassEffect(tab == kind ? .clear.tint(Color(nsColor: app.accent).opacity(0.55)).interactive() : .clear.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [VaultItem] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.items.filter { item in
            guard tab == nil || item.kind == tab else { return false }
            guard !words.isEmpty else { return true }
            let public_ = [item.title, Vault.subtitle(item)] + item.sites + item.kind.fields.filter { !$0.isSecret }.map { item[$0] }
            return public_.contains { $0.lowercased().contains(words) }
        }.sorted { a, b in a.kind != b.kind && tab == nil ? VaultKind.allCases.firstIndex(of: a.kind)! < VaultKind.allCases.firstIndex(of: b.kind)!
            : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
    }

    private func start(_ kind: VaultKind) {
        isNew = true
        editing = VaultItem(kind: kind, title: "")
    }

    // MARK: Import and export

    private var transfer: some View {
        Card(title: "Import and export", footer: "An export holds your passwords, cards and keys as plain text. Keep it somewhere safe, and move it to the Trash once you're done with it.") {
            HStack(spacing: 8) {
                Button("Import…") { chooseImport() }.buttonStyle(.glass)
                Menu("Export…") {
                    Button("Everything, as a Petal file") { export(.petal) }
                    Button("Logins, as CSV (Apple Passwords, Chrome)") { export(.csv) }
                }
                .menuStyle(.button).buttonStyle(.glass).fixedSize()
                Spacer()
                Text(dropping ? "Drop it here" : "Or drop an export on this page")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Apple Passwords, Chrome and Proton Pass exports (CSV, or Proton Pass's unencrypted JSON or zip), and Petal's own file.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let imported { importedRow(imported) }
            if let exported { Text(exported).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private func importedRow(_ result: VaultModel.Imported) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failed = result.failed {
                Text(failed).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(Self.summary(result)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if !result.conflicts.isEmpty {
                    HStack(spacing: 8) {
                        Text(result.usedImported ? "Petal now uses the file's." : Self.conflictText(result.conflicts))
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if !result.usedImported {
                            Button("Use the imported ones") {
                                model.useImported(result.conflicts) { ok in if ok { imported?.usedImported = true } }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            }
            if result.trashed {
                Label("The export is in the Trash.", systemImage: "trash").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if result.failed == nil {
                HStack(spacing: 8) {
                    Text("The file still holds every password as plain text.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Move it to the Trash") {
                        model.trash(result.file) { ok in if ok { imported?.trashed = true } }
                    }
                    .buttonStyle(.glass).controlSize(.small)
                }
            }
        }
    }

    static func summary(_ result: VaultModel.Imported) -> String {
        var parts = ["Added \(result.added) item\(result.added == 1 ? "" : "s")."]
        if result.same > 0 { parts.append("\(result.same) \(result.same == 1 ? "was" : "were") already here.") }
        if !result.updated.isEmpty {
            let names = result.updated.prefix(5).joined(separator: ", ") + (result.updated.count > 5 ? ", …" : "")
            parts.append("\(result.updated.count) had something newer, which Petal kept: \(names).")
        }
        if result.older > 0 { parts.append("\(result.older) \(result.older == 1 ? "was" : "were") older in the file than here: Petal kept yours.") }
        if result.skipped > 0 { parts.append("\(result.skipped) had nothing to keep (notes and the like).") }
        return parts.joined(separator: " ")
    }

    /// "2 logins differ, kept yours: GitHub, Figma."
    static func conflictText(_ items: [VaultItem]) -> String {
        let kinds = Set(items.map(\.kind))
        let noun = kinds == [.login] ? (items.count == 1 ? "login differs" : "logins differ")
            : items.count == 1 ? "item differs" : "items differ"
        let names = items.prefix(5).map(\.title).joined(separator: ", ") + (items.count > 5 ? ", …" : "")
        return "\(items.count) \(noun) from what's saved, so Petal kept yours: \(names)."
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .zip, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a password export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    private func importFile(_ url: URL) {
        imported = nil
        model.importFile(url) { imported = $0 }
    }

    private func export(_ format: VaultModel.ExportFormat) {
        exported = nil
        model.unlock("export your vault", fresh: true) { ok in
            guard ok else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = format == .petal ? "Petal Vault.petalvault.json" : "Petal Logins.csv"
            panel.allowedContentTypes = [format == .petal ? .json : .commaSeparatedText]
            panel.message = "This file will hold your secrets as plain text."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            model.export(format, to: url) { failed in
                exported = failed ?? "Saved to \(url.lastPathComponent). It holds your secrets as plain text: keep it safe, and move it to the Trash once you're done."
            }
        }
    }
}

/// An export dropped on the vault page is imported (not while snapshotting: the drop target draws as a placeholder).
struct DropExport: ViewModifier {
    let on: Bool
    @Binding var dropping: Bool
    let dropped: (URL) -> Void

    func body(content: Content) -> some View {
        if on {
            content.onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { dropped(url) } }
                }
                return true
            }
        } else {
            content
        }
    }
}

struct VaultRow: View {
    let item: VaultItem
    var showKind = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28).glassEffect(.clear, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? item.kind.name : item.title).font(.system(size: 13))
                let subtitle = Vault.subtitle(item)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if showKind { Text(item.kind.name).font(.system(size: 11)).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }
}

/// One item, editable. Its secrets show as dots until Touch ID or the Mac's password (for an item already saved).
struct VaultEditor: View {
    @Environment(PetalApp.self) private var app
    private var model: VaultModel { VaultModel.shared }
    @State var item: VaultItem
    let isNew: Bool
    let close: () -> Void
    @State private var showing: Set<VaultField> = []
    @State private var sites = ""
    @State private var problem: String?

    init(item: VaultItem, isNew: Bool, close: @escaping () -> Void) {
        _item = State(initialValue: item)
        _sites = State(initialValue: item.sites.joined(separator: ", "))
        self.isNew = isNew
        self.close = close
    }

    var body: some View {
        Card(title: isNew ? "New \(item.kind.name.lowercased())" : item.kind.name) {
            row(titleLabel) { TextField(titlePrompt, text: $item.title) }
            if item.kind == .login || item.kind == .apiKey {
                row(item.kind == .login ? "Websites" : "Service (website)") {
                    TextField(item.kind == .login ? "github.com, gist.github.com" : "platform.openai.com", text: $sites)
                }
            }
            if item.kind == .login { apps }
            if item.kind == .address { contactPicker }
            ForEach(item.kind.fields, id: \.self) { field in
                if field == .relationship {
                    row(field.label(item.kind)) {
                        HStack {
                            TextField("girlfriend, mom, friend…", text: binding(field)).disabled(item.isMe)
                            Toggle("This is me", isOn: Binding(get: { item.isMe }, set: { item[.relationship] = $0 ? "me" : "" }))
                                .toggleStyle(.checkbox).fixedSize()
                        }
                    }
                } else {
                    row(field.label(item.kind)) { entry(field) }
                }
            }
            row("Notes") { entry(.notes) }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                if !isNew {
                    Button("Delete", role: .destructive) { model.remove(item.id); close() }.buttonStyle(.glass)
                }
                Spacer()
                Button("Cancel") { close() }.buttonStyle(.glass)
                Button("Save") { save() }.buttonStyle(.glassProminent).tint(Color(nsColor: app.accent))
            }
        }
    }

    private var titleLabel: String {
        switch item.kind {
        case .address: "Label (Home, Work…)"
        case .contact: "Name in your vault"
        default: "Name"
        }
    }

    private var titlePrompt: String {
        switch item.kind {
        case .login: "GitHub"
        case .contact: "Deniz"
        case .address: "Home"
        case .card: "Visa"
        case .apiKey: "OpenAI"
        }
    }

    private var apps: some View {
        row("Apps") {
            HStack(spacing: 6) {
                ForEach(item.apps, id: \.self) { id in
                    HStack(spacing: 4) {
                        LinkedApp(id: id)
                        Button {
                            item.apps.removeAll { $0 == id }
                            item.appSigners[id] = nil
                        } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .glassEffect(.clear, in: .capsule)
                }
                Menu("Add an app") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !item.apps.contains($0.bundleIdentifier ?? "") }
                        .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0, app.processIdentifier) } }.sorted { $0.1 < $1.1 }, id: \.0) { id, name, pid in
                        Button(name) {
                            item.apps.append(id)
                            // Who signed the app running now: the login fills by itself only into a copy signed the same.
                            VaultReader.loadSigner(pid: pid, bundle: id) { team in
                                if let team, item.apps.contains(id) { item.appSigners[id] = team }
                            }
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private var contactPicker: some View {
        row("Contact") {
            Picker("", selection: Binding(get: { item[.contact] }, set: { item[.contact] = $0 })) {
                Text("None").tag("")
                ForEach(model.items.filter { $0.kind == .contact }) { contact in
                    Text(contact.isMe ? "\(contact.title) (me)" : contact.title).tag(contact.id)
                }
            }
            .labelsHidden()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
            content().textFieldStyle(.roundedBorder)
        }
    }

    private func binding(_ field: VaultField) -> Binding<String> {
        Binding(get: { item[field] }, set: { item[field] = $0 })
    }

    @ViewBuilder private func entry(_ field: VaultField) -> some View {
        if field.isSecret {
            HStack(spacing: 6) {
                if showing.contains(field) {
                    TextField("", text: binding(field), axis: field == .notes ? .vertical : .horizontal).lineLimit(field == .notes ? 1...6 : 1...1)
                } else if field == .notes && !item[field].isEmpty {
                    Text("Hidden").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SecureField("", text: binding(field))
                }
                Button { reveal(field) } label: {
                    Image(systemName: showing.contains(field) ? "eye.slash" : "eye").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(showing.contains(field) ? "Hide" : "Show")
            }
        } else {
            TextField("", text: binding(field))
        }
    }

    /// Showing what's saved asks for Touch ID or the Mac's password first (not for what's just been typed).
    private func reveal(_ field: VaultField) {
        if showing.contains(field) { showing.remove(field); return }
        let saved = model.items.first { $0.id == item.id }.map { !$0[field].isEmpty } ?? false
        guard saved else { showing.insert(field); return }
        model.unlock("show your \(field.words)") { ok in if ok { showing.insert(field) } }
    }

    private func save() {
        var item = item
        item.title = item.title.trimmingCharacters(in: .whitespaces)
        let typed = sites.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { VaultSite.host(String($0)) }
        if !sites.trimmingCharacters(in: .whitespaces).isEmpty, typed.isEmpty { problem = "Those don't look like websites (like github.com)."; return }
        item.sites = typed
        if item.title.isEmpty {
            item.title = item.kind == .contact ? (item[.name].isEmpty ? "Contact info" : item[.name]) : item.kind == .address ? "Home"
                : item.kind == .card ? (Vault.brand(item[.number].filter(\.isNumber)) ?? "Card") : item.sites.first ?? item.kind.name
        }
        // One contact is the person themselves.
        if item.isMe {
            for var other in model.items where other.isMe && other.id != item.id {
                other[.relationship] = ""
                model.save(other)
            }
        }
        model.save(item)
        close()
    }
}

// MARK: - Touch ID

extension VaultModel {
    /// Touch ID or the Mac's password, kept for a minute; `fresh` always asks (an export).
    func unlock(_ reason: String, fresh: Bool = false, done: @escaping @MainActor (Bool) -> Void) {
        if !fresh, Date() < unlockedUntil { return done(true) }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return done(false) }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok { self.unlockedUntil = Date().addingTimeInterval(60) }
                    done(ok)
                }
            }
        }
    }
}

/// An app tied to a login: its icon and name as Petal has them, read off the main thread the first time.
private struct LinkedApp: View {
    let id: String
    @State private var name: String?
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon ?? Apps.cachedIcon(id) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app").frame(width: 16, height: 16)
            }
            Text(name ?? Apps.cachedName(id) ?? id).font(.system(size: 12))
        }
        .task(id: id) {
            Apps.loadName(id) { name = $0 }
            Apps.loadIcon(id) { icon = $0 }
        }
    }
}
