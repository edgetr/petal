import AppKit
import Observation
import SwiftUI

/// The person's grants: an agent may use a vault item in a project (and everything in it) without asking. Kept in
/// Application Support/Petal/agent-grants.json (`PETAL_AGENT_GRANTS` points elsewhere for testing), with no secret
/// in it: the item's id and title, the project's folder and the agent.
@MainActor @Observable
final class AgentGrants {
    static let shared = AgentGrants()

    private(set) var grants: [AgentAccess.Grant] = []
    private(set) var loaded = false

    nonisolated static var file: URL {
        if let path = ProcessInfo.processInfo.environment["PETAL_AGENT_GRANTS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Petal/agent-grants.json")
    }

    nonisolated private static let queue = DispatchQueue(label: "petal.agent-grants", qos: .utility)
    nonisolated static func flush() { queue.sync {} }

    /// Read off the main thread, once.
    func load() {
        guard !loaded else { return }
        Self.queue.async {
            // A grant for an agent Petal can't verify (opencode, from an older Petal) counts for nothing: left out.
            let read = ((try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([AgentAccess.Grant].self, from: $0) } ?? []).filter(\.storable)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.loaded else { return }
                    // A grant made before the file was read is kept with what was there.
                    self.grants = read + self.grants.filter { new in !read.contains { $0.id == new.id } }
                    self.loaded = true
                }
            }
        }
    }

    /// Adds a grant, or finds the same one already there: its id (nil: a grant that's never kept).
    @discardableResult
    func add(_ grant: AgentAccess.Grant) -> String? {
        guard grant.storable else { return nil }
        if let same = grants.first(where: { $0.item == grant.item && $0.project == grant.project && $0.agent == grant.agent }) { return same.id }
        grants.append(grant)
        save()
        return grant.id
    }

    /// Removes a grant, and ends every operation relying on it, even one waiting on a card.
    func remove(_ id: String) {
        grants.removeAll { $0.id == id }
        for pass in passes.allObjects where AgentAccess.revokedBy(pass.authorization, removing: id) { pass.revoke() }
        save()
    }

    // MARK: Operations under way

    /// Every pass not yet done with (held weakly: an operation that ended lets go of its own).
    @ObservationIgnored private let passes = NSHashTable<AgentPass>.weakObjects()
    /// The Allow once cards whose operation is done: never good again.
    @ObservationIgnored private var spent: Set<String> = []

    /// A pass for one operation, under `authorization`.
    func pass(_ authorization: AgentAccess.Authorization, caller: AgentAccess.Caller) -> AgentPass {
        let pass = AgentPass(authorization, caller: caller)
        passes.add(pass)
        return pass
    }

    /// Right before a field is filled or a key handed over: the pass is still good for `item` in its operation,
    /// by the grants as they are now.
    func still(_ pass: AgentPass, item: String) -> Bool {
        !pass.revoked && AgentAccess.stillAllowed(pass.authorization, item: item, caller: pass.caller, operation: pass.operation,
                                                  grants: grants, spent: spent)
    }

    /// The operation is done: its Allow once is spent, and the pass is good for nothing more.
    func finish(_ pass: AgentPass) {
        if case .allowOnce(let card) = pass.authorization.kind { spent.insert(card) }
        pass.revoke()
        passes.remove(pass)
    }

    /// Made-up grants, for `Petal --snapshot`: nothing is read or written.
    func preview(_ list: [AgentAccess.Grant]) {
        grants = list
        loaded = true
        snapshot = true
    }
    @ObservationIgnored private var snapshot = false

    private func save() {
        guard !snapshot else { return }
        let list = grants
        Self.queue.async {
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.file, options: .atomic) }
        }
    }

    /// Grants are read before the first answer that needs them.
    func whenLoaded(_ then: @escaping @MainActor () -> Void) {
        if loaded { return then() }
        load()
        func wait(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { self.loaded || tries > 60 ? then() : wait(tries + 1) }
            }
        }
        wait(0)
    }
}

extension Assist {
    var home: String { NSHomeDirectory() }

    /// Before an agent outside Petal uses a vault item (`grant`: the item's id, or new logins): what it's allowed.
    /// `who` is the identity read off the socket when the request came in, carried with it: with none, nothing
    /// goes on. Petal's own chats keep their rules (no grant). A verified agent with a grant for this item in this
    /// project goes on; any other asks the person with a card: Always for this project (only for Claude Code or
    /// Codex signed by its maker, never the home folder), Allow once, or Don't (the default). Every use is kept in
    /// What Petal AI did.
    /// `go` gets the operation's pass (nil for Petal's own chats): the fill checks it again right before each field
    /// (`AgentGrants.still`), and it ends the moment the grant it relies on is removed. The caller finishes it
    /// (`AgentGrants.finish`) once the operation is done. `live`: the request is still wanted (its reply not stopped,
    /// its asker still there), checked once the grants are read, before any card shows.
    func agentGate(_ caller: String, who identity: AgentAccess.Caller?, grant item: String, title: String, what: String, task: String, did done: String,
                   live: @escaping () -> Bool, fail: @escaping (String) -> Void, go: @escaping (AgentPass?) -> Void) {
        let who: AgentAccess.Caller
        switch AgentAccess.gate(identity) {
        case .petal: return go(nil)
        case .refuse: return fail("Petal couldn't tell who's asking, so it used nothing from the vault. Try again.")
        case .check(let caller): who = caller
        }
        let grants = AgentGrants.shared
        let operation = UUID().uuidString
        grants.whenLoaded { [self] in
            guard live() else { return fail(ComputerUse.stoppedText) }
            let place = AgentAccess.shown(who.project, home: home)
            let said = AgentAccess.clipped(task, 120)
            let record = "\(who.label) \(done) in \(place)" + (said.isEmpty ? "" : ": “\(said)”")
            if let grant = AgentAccess.granted(grants.grants, item: item, caller: who) {
                did(record)
                return go(grants.pass(.init(kind: .grant(grant.id), operation: operation, item: item), caller: who))
            }
            let keep = who.grantable && !AgentAccess.tooBroad(who.project, home: home)
            let card = UUID().uuidString
            var kept: String?
            ask("agent-vault", AgentAccess.fillQuestion(who, what: what, home: home), detail: agentDetail(who, said: said, how: "It never sees the secret: Petal fills it in itself."), always: true, warn: true,
                allow: "Allow once", owner: caller, keep: keep ? "Always for this project" : nil, mark: who.agent,
                kept: { kept = grants.add(AgentAccess.Grant(item: item, title: title, project: who.project, agent: who.agent)) }) { allowed in
                guard allowed else { return fail("The person didn't let \(who.label) use “\(title)”. Don't find another way; ask them.") }
                self.did(record)
                // Always: the grant just made, which the person may remove again before the fill; else this card.
                go(grants.pass(.init(kind: kept.map { .grant($0) } ?? .allowOnce(card: card), operation: operation, item: item), caller: who))
            }
        }
    }

    /// The card's second line: what the agent says it's for (its words, marked as such), what Petal can't tell about
    /// it, and `how` it uses the secret without seeing it.
    func agentDetail(_ who: AgentAccess.Caller, said: String, how: String) -> String {
        var lines: [String] = []
        if !said.isEmpty { lines.append("It says: “\(said)”.") }
        switch who.agent {
        case .unknown: lines.append("Petal can't tell what this program is: it isn't an agent Petal knows, signed by its maker.")
        case .opencode: lines.append("Petal knows opencode by its name only; it can't confirm who made it, so it's allowed once at a time.")
        case .command: lines.append("Petal sees no agent it can confirm above this command, so it's allowed once at a time.")
        default: break
        }
        lines.append(how)
        return lines.joined(separator: " ")
    }

    // MARK: petal run

    /// `petal run` asks for keys (["agentKeys", json]): {"keys": [{"ref", "env"}], "command", "stdin"}. Only to
    /// Petal's own `petal run`, which puts them in the command's variables (or input) and takes them out of what it
    /// prints; the agent that ran it never sees them. Asks first as `agentGate` does, one card for every key.
    /// `request`: `petal run` ended or gave up waiting (its socket closed), its card is answered Don't and no key goes.
    func agentKeys(_ json: String, from who: AgentAccess.Caller, request: IPC.Pending, reply: @escaping @MainActor (String) -> Void) {
        let owner = "mcp-\(who.pid)"
        request.waiting = { [unowned self] in pending?.owner == owner }
        request.onHangUp { [unowned self] in decline(owner: owner) }
        let send = { (object: [String: Any]) in
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            reply(String(decoding: data, as: UTF8.self))
        }
        let fail = { (text: String) in send(["error": text]) }
        guard who.peerIsPetal else {
            return fail("Only Petal's own `petal run` is handed a key. Run the command with `petal run --key \"<title>\" -- <command>`.")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let wanted = (args["keys"] as? [[String: Any]] ?? []).compactMap { entry -> AgentAccess.Run.Key? in
            guard let ref = entry["ref"] as? String, !ref.isEmpty else { return nil }
            return .init(ref: ref, variable: (entry["env"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        let command = AgentAccess.clipped(args["command"] as? String ?? "", 200)
        let stdin = args["stdin"] as? Bool ?? false
        guard !wanted.isEmpty else { return fail("Say which key with --key.") }
        VaultStore.load { [self] read in
            guard case .success(let items) = read else { return fail(VaultStore.unreadableText + " Try again in a moment.") }
            let keys = items.filter { $0.kind == .apiKey }
            var found: [(item: VaultItem, variable: String?)] = []
            for want in wanted {
                guard let item = Vault.find(keys, want.ref) else {
                    let titles = keys.map(\.title).sorted()
                    return fail("There's no API key “\(want.ref)” in the vault." + (titles.isEmpty ? " It has none yet: the person adds them in Petal's settings, Vault."
                        : " Its API keys: " + titles.joined(separator: ", ") + "."))
                }
                guard !item[.value].isEmpty else { return fail("“\(item.title)” has no key saved.") }
                // A key too short to find in every form it can be printed in is never handed to a command.
                if AgentAccess.Redactor.tooShort(item[.value]) { return fail("“\(item.title)”: " + AgentAccess.Redactor.tooShortText) }
                if let variable = want.variable, !AgentAccess.validVariable(variable) { return fail("\(variable) can't hold a key.") }
                let variable = want.variable ?? (stdin ? nil : AgentAccess.variable(sites: item.sites, title: item.title))
                if variable == nil, !stdin {
                    return fail("Petal doesn't know which variable “\(item.title)” goes in: say it with --env NAME after its --key.")
                }
                found.append((item, variable))
            }
            // Before asking: two keys never go in one variable, where the second would quietly replace the first.
            if let clash = AgentAccess.sameVariable(found.map { ($0.item.title, $0.variable) }) { return fail(clash) }
            let titles = found.map(\.item.title)
            let place = AgentAccess.shown(who.project, home: home)
            let record = "\(who.label) used your \(titles.joined(separator: ", ")) key\(titles.count == 1 ? "" : "s")"
                + (command.isEmpty ? "" : " for “\(AgentAccess.clipped(command, 60))”") + " in \(place)"
            // Read again right before the keys go (the card may have waited): each item still there as it was when
            // Petal asked (its revision), and still allowed by what let it go on (`passes`, by item): the grant must
            // still be there and cover it, and an Allow once is good for this run only. Edited, replaced, deleted or no
            // longer granted: no key is given at all.
            let grants = AgentGrants.shared
            let operation = UUID().uuidString
            let give = { (passes: [String: AgentPass]) in
                let done = { passes.values.forEach(grants.finish) }
                VaultStore.load { read in
                    defer { done() }
                    guard !request.hungUp else { return fail("petal run stopped waiting: no key was given.") }
                    guard case .success(let now) = read else { return fail(VaultStore.unreadableText + " No key was given; try again in a moment.") }
                    var keys: [[String: Any]] = []
                    for pair in found {
                        guard let item = now.first(where: { $0.id == pair.item.id }), item.kind == .apiKey,
                              Vault.sameRevision(Vault.revision(pair.item), item), !item[.value].isEmpty else {
                            return fail("“\(pair.item.title)” changed in the vault while Petal asked (edited, replaced or deleted): no key was given. Run the command again, so the person is asked about it as it is now.")
                        }
                        if AgentAccess.Redactor.tooShort(item[.value]) { return fail("“\(item.title)”: " + AgentAccess.Redactor.tooShortText) }
                        guard let pass = passes[item.id], grants.still(pass, item: item.id) else {
                            return fail("The person no longer lets \(who.label) use “\(item.title)” here: no key was given. Don't find another way; ask them.")
                        }
                        var key: [String: Any] = ["title": item.title, "secret": item[.value]]
                        if let variable = pair.variable { key["env"] = variable }
                        keys.append(key)
                    }
                    self.did(record)
                    send(["keys": keys])
                }
            }
            @MainActor func pass(_ kind: AgentAccess.Authorization.Kind, _ item: String) -> AgentPass {
                grants.pass(.init(kind: kind, operation: operation, item: item), caller: who)
            }
            if who.agent == .petal {
                return give(Dictionary(found.map { ($0.item.id, pass(.petal, $0.item.id)) }, uniquingKeysWith: { a, _ in a }))
            }
            grants.whenLoaded {
                guard !request.hungUp else { return fail("petal run stopped waiting: no key was given.") }
                var passes: [String: AgentPass] = [:]
                for pair in found {
                    if let grant = AgentAccess.granted(grants.grants, item: pair.item.id, caller: who) { passes[pair.item.id] = pass(.grant(grant.id), pair.item.id) }
                }
                let missing = found.filter { passes[$0.item.id] == nil }
                guard !missing.isEmpty else { return give(passes) }
                let keep = who.grantable && !AgentAccess.tooBroad(who.project, home: self.home)
                let it = missing.count == 1 ? "it" : "them"
                let card = UUID().uuidString
                var kept: [String: String] = [:]
                let detail = self.agentDetail(who, said: "", how: "It never sees \(it): Petal gives \(it) to the command and takes \(it) out of what the command prints.")
                self.ask("agent-key", AgentAccess.keyQuestion(who, titles: missing.map(\.item.title), command: command, home: self.home), detail: detail,
                         always: true, warn: true, allow: "Allow once", owner: owner, keep: keep ? "Always for this project" : nil, mark: who.agent,
                         kept: {
                             for pair in missing {
                                 kept[pair.item.id] = grants.add(AgentAccess.Grant(item: pair.item.id, title: pair.item.title, project: who.project, agent: who.agent))
                             }
                         }) { allowed in
                    guard allowed else {
                        passes.values.forEach(grants.finish)
                        return fail("The person didn't let \(who.label) use \(missing.count == 1 ? "that key" : "those keys"). Don't find another way; ask them.")
                    }
                    // Always: the grants just made, which the person may remove again before the keys go; else this card.
                    for pair in missing { passes[pair.item.id] = pass(kept[pair.item.id].map { .grant($0) } ?? .allowOnce(card: card), pair.item.id) }
                    give(passes)
                }
            }
        }
    }
}

/// One agent's vault operation (a fill, a `petal run`), from the card or grant that let it go on to the moment the
/// secret is used: checked again then (`AgentGrants.still`), and revoked (stopping a fill as a Stop would) when the
/// grant it relies on is removed or the operation is done.
final class AgentPass: @unchecked Sendable {
    let authorization: AgentAccess.Authorization
    let caller: AgentAccess.Caller
    /// The operation this pass is for (a fill, a `petal run`); a use in any other is never covered by it.
    let operation: String
    private let lock = NSLock()
    private var ended = false

    init(_ authorization: AgentAccess.Authorization, caller: AgentAccess.Caller) {
        self.authorization = authorization
        self.caller = caller
        operation = authorization.operation
    }

    var revoked: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    func revoke() { lock.lock(); ended = true; lock.unlock() }

    static let revokedText = "The person no longer lets this agent use that item here (its grant was removed): nothing more was filled. Don't find another way; ask them."
}

// MARK: - Settings › Vault › Agents

/// The agents allowed to use the vault without asking: each grant (an item, a project, an agent) with Remove, and
/// adding one ahead of time, so an agent working while the person is away is never stuck on a card.
struct AgentsCard: View {
    @Environment(\.snapshotting) private var snapshotting
    private var grants: AgentGrants { AgentGrants.shared }
    private var model: VaultModel { VaultModel.shared }
    @State private var adding = false
    @State private var item = ""
    @State private var agent: AgentAccess.Agent = .claude
    @State private var project: String?
    @State private var problem: String?

    var body: some View {
        Card(title: "Agents",
             footer: "Your agents in T3 Code or a terminal use the vault without seeing a password or key: Petal fills it in, or gives the key to the command they run and takes it out of what it prints. Each asks first in a project unless it's allowed here. A command made to show a key still can, so allow only agents you trust.") {
            if grants.grants.isEmpty {
                Text("No agent uses your vault without asking yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(grants.grants.sorted { ($0.project, $0.title) < ($1.project, $1.title) }) { grant in
                HStack(spacing: 10) {
                    AgentMark(agent: grant.agent).frame(width: 16, height: 16).frame(width: 28, height: 28).glassEffect(.clear, in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(itemName(grant)).font(.system(size: 13))
                        Text("\(grant.agent.name) · \(AgentAccess.shown(grant.project, home: NSHomeDirectory()))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("Remove") { grants.remove(grant.id) }.buttonStyle(.glass)
                }
            }
            if adding { form } else {
                Button { adding = true } label: { Label("Allow an agent…", systemImage: "plus") }.buttonStyle(.glass)
            }
        }
        .onAppear { if !snapshotting { grants.load() } }
    }

    /// What a grant is for, by the item's title now (it may have been renamed), or as granted.
    private func itemName(_ grant: AgentAccess.Grant) -> String {
        if grant.item == AgentAccess.Grant.newLogins { return "Make new logins" }
        guard let item = model.items.first(where: { $0.id == grant.item }) else { return grant.title }
        return item.title + (item.kind == .apiKey ? " key" : item.kind == .login ? " login" : "")
    }

    /// The API keys and logins an agent may use, and making new logins.
    private var choices: [(id: String, title: String)] {
        let items = model.items.filter { [.apiKey, .login].contains($0.kind) }
            .sorted { ($0.kind == .apiKey ? 0 : 1, $0.title.lowercased()) < ($1.kind == .apiKey ? 0 : 1, $1.title.lowercased()) }
        return items.map { ($0.id, $0.kind == .apiKey ? "\($0.title) key" : "\($0.title) login") }
            + [(AgentAccess.Grant.newLogins, "Make new logins")]
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Agent", selection: $agent) {
                    ForEach(AgentAccess.Agent.grantable, id: \.self) { Text($0.name).tag($0) }
                }
                .fixedSize()
                Picker("May use", selection: $item) {
                    Text("Choose…").tag("")
                    ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                Button(project.map { AgentAccess.shown($0, home: NSHomeDirectory()) } ?? "Choose the project…") { chooseProject() }
                    .buttonStyle(.glass)
                Spacer()
                Button("Cancel") { reset() }.buttonStyle(.glass)
                Button("Allow") { add() }.buttonStyle(.glassProminent).disabled(item.isEmpty || project == nil)
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the project the agent works in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        // A folder in a repository is that repository (a worktree is its main checkout); read off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AgentAccess.project(url.resolvingSymlinksInPath().path, files: AgentCallers.disk)
            DispatchQueue.main.async {
                if AgentAccess.tooBroad(found, home: NSHomeDirectory()) {
                    project = nil
                    problem = "That's your whole home folder or more: choose one project's folder."
                } else {
                    project = found
                }
            }
        }
    }

    private func add() {
        guard let project, let choice = choices.first(where: { $0.id == item }) else { return }
        let title = model.items.first { $0.id == item }?.title ?? choice.title
        grants.add(AgentAccess.Grant(item: item, title: title, project: project, agent: agent))
        reset()
    }

    private func reset() {
        adding = false
        item = ""
        project = nil
        problem = nil
    }
}

/// An agent's mark: Claude's or OpenAI's, else a terminal.
struct AgentMark: View {
    let agent: AgentAccess.Agent

    var body: some View {
        switch agent {
        case .claude: ProviderMark(provider: .claude)
        case .codex: ProviderMark(provider: .codex)
        case .unknown: Image(systemName: "questionmark.circle").resizable().scaledToFit().foregroundStyle(.secondary)
        case .any: Image(systemName: "sparkles").resizable().scaledToFit().foregroundStyle(.secondary)
        default: Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}
