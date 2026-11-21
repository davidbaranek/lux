#if os(macOS)
import Foundation
import LuxBindings

/// What an agent's session may do, each more than the one before.
public enum AgentGrant: String, CaseIterable, Sendable, Comparable {
    case read, drafts, send, autoSend

    public var title: String {
        switch self {
        case .read: String(localized: "Read only")
        case .drafts: String(localized: "Read and write drafts")
        case .send: String(localized: "Read, write drafts and ask to send")
        case .autoSend: String(localized: "Read, write drafts and send on its own")
        }
    }

    private var order: Int {
        switch self {
        case .read: 0
        case .drafts: 1
        case .send: 2
        case .autoSend: 3
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }

    var core: CoreAgentGrant {
        switch self {
        case .read: .read
        case .drafts: .drafts
        case .send: .send
        case .autoSend: .autoSend
        }
    }

    init(_ grant: CoreAgentGrant) {
        self = switch grant {
        case .read: .read
        case .drafts: .drafts
        case .send: .send
        case .autoSend: .autoSend
        }
    }
}

/// An agent asking, as the approval dialog shows it.
public struct AgentRequest: Sendable {
    /// Its name, as it says (not proof of who it is: the code is).
    public var client: String
    public var isCLI: Bool
    public var command: String?
    public var folder: String?
    /// The match code the agent shows too.
    public var code: String
    /// What it asks for: the dialog offers it.
    public var grant: AgentGrant
    /// Why, when it asks for more.
    public var reason: String?
}

/// The user's answer in the dialog.
public enum AgentDecision: Sendable {
    case deny
    /// Approved with `grant`; `always` for this client from now on.
    case allow(AgentGrant, always: Bool)
}

/// One call an agent made, for Settings' activity: never the messages' text.
public struct AgentActivity: Sendable, Identifiable {
    public let id = UUID()
    public var date: Date
    public var client: String
    public var tool: String
    public var chats: Int
    public var messages: Int
    public var refused: String?
}

/// What only the app's windows can do for the agents.
@MainActor
public protocol AgentsPresenter: AnyObject {
    /// Asks the user, in front, with the match code.
    func approve(_ request: AgentRequest) async -> AgentDecision
    /// Opens the chat of `roomId` with `text` in its composer: whether it could.
    func showDraft(_ text: String, inRoom roomId: String) async -> Bool
    /// Opens the chat of `roomId` and asks the user whether `text` may be sent, asked by
    /// `client`. The core sends it, on its own: nothing of the composer's goes with it.
    func allowSend(_ text: String, inRoom roomId: String, client: String) async -> Bool
}

/// Agents on this Mac: the `Lux agent` CLI and MCP server reach the account through a socket in
/// the app's container while AI and Agents are on and the account's index is open. Each session
/// is approved by the user; what it may do, the chats kept from it, and every call are the
/// core's to decide and the user's to see.
@MainActor
public final class Agents {
    /// The socket, in the app's container (the CLI, the same app, finds it there).
    nonisolated public static var socket: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agents.sock")
    }

    /// The command that runs the app as the agents' binary.
    public static var command: String {
        (Bundle.main.executablePath ?? "/Applications/Lux.app/Contents/MacOS/Lux") + " agent"
    }

    /// The skill for agents, a `SKILL.md`.
    nonisolated public static var skill: String { agentSkill() }

    /// `Lux agent <arguments>`: the app's executable as the agents' CLI or MCP server over stdio,
    /// reaching the running app's socket. Runs to its end; the process's exit code.
    nonisolated public static func runClient(arguments: [String]) -> Int32 {
        runAgent(arguments: arguments, socketPath: socket.path)
    }

    public weak var presenter: AgentsPresenter? {
        didSet { update() }
    }
    public let changes = Broadcast()
    public private(set) var activity: [AgentActivity] = []

    private let session: Session
    private var running: CoreAgents?
    /// CLI sessions approved for a while, by client and folder: each command is a connection.
    private var recentCLI: [String: (grant: AgentGrant, until: Date)] = [:]
    private var observations: [AnyObject] = []
    private static let cliWhile: TimeInterval = 30 * 60

    init(session: Session) {
        self.session = session
        observations = [
            session.searchChanges.observe { [weak self] in self?.update() },
            session.textActions.changes.observe { [weak self] in self?.update() },
        ]
    }

    /// Agents on (under the AI switch).
    public var isOn: Bool {
        get { session.preferences.aiAgents }
        set {
            session.preferences.aiAgents = newValue
            update()
        }
    }

    /// Whether the socket is open now.
    public var isServing: Bool { running != nil }

    /// The clients approved for always, and what each may do.
    public var approvedClients: [(client: String, grant: AgentGrant)] {
        session.preferences.approvedAgents.compactMap { client, grant in AgentGrant(rawValue: grant).map { (client, $0) } }
            .sorted { $0.client < $1.client }
    }

    public func forget(client: String) {
        session.preferences.approvedAgents[client] = nil
        changes.send()
    }


    /// Whether the socket is on but cannot open yet (the account or its index not open).
    public var isWaiting: Bool { session.textActions.isOn && isOn && running == nil }

    /// Opens or closes the socket as the switches and the account say.
    private func update() {
        let wanted = session.textActions.isOn && isOn && presenter != nil
        guard wanted, let search = session.search else {
            running = nil
            changes.send()
            return
        }
        guard running == nil else { return }
        let store = search.index.store
        let account = session.account
        Task { [weak self] in
            guard let core = await bestEffort("agents: the account", { try await account.value.account }) else { return }
            guard let self, running == nil, session.search === search, session.textActions.isOn, isOn else { return }
            do {
                let agents = try CoreAgents.start(socketPath: Self.socket.path, account: core, store: store,
                                                  host: AgentHost(agents: self, search: search))
                running = agents
            } catch {
                Log.app.error("agents: \(String(describing: error), privacy: .public)")
            }
            changes.send()
        }
    }

    // MARK: The host's calls, on the main actor

    fileprivate func approve(_ approval: CoreAgentApproval) async -> AgentDecision {
        guard session.textActions.isOn, isOn, let presenter else { return .deny }
        let wanted = approval.grant.map(AgentGrant.init)
        if let approved = session.preferences.approvedAgents[approval.client].flatMap(AgentGrant.init(rawValue:)),
           approval.reason == nil, wanted.map({ $0 <= approved }) ?? true {
            return .allow(approved, always: true)
        }
        let key = "\(approval.client)\u{0}\(approval.folder ?? "")"
        if approval.isCli, approval.reason == nil, let recent = recentCLI[key], recent.until > .now,
           wanted.map({ $0 <= recent.grant }) ?? true {
            return .allow(recent.grant, always: false)
        }
        let request = AgentRequest(client: approval.client, isCLI: approval.isCli, command: approval.command,
                                   folder: approval.folder, code: approval.code, grant: wanted ?? .read, reason: approval.reason)
        let decision = await presenter.approve(request)
        if case .allow(let grant, let always) = decision {
            if always { session.preferences.approvedAgents[approval.client] = grant.rawValue }
            if approval.isCli { recentCLI[key] = (grant, .now + Self.cliWhile) }
            changes.send()
        }
        return decision
    }

    fileprivate func showDraft(_ text: String, inRoom room: String) async -> Bool {
        await presenter?.showDraft(text, inRoom: room) ?? false
    }

    fileprivate func allowSend(_ text: String, inRoom room: String, client: String) async -> Bool {
        await presenter?.allowSend(text, inRoom: room, client: client) ?? false
    }

    fileprivate func record(_ entry: CoreAgentLogEntry) {
        activity.insert(AgentActivity(date: .now, client: entry.client, tool: entry.tool, chats: entry.chats.count,
                                      messages: Int(entry.messages), refused: entry.refused), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
        changes.send()
    }
}

/// The core's calls into the app, from its threads: each goes to the main actor. It lives as long
/// as the socket the core serves (`Agents.running`), which ends with the search it reads.
private final class AgentHost: CoreAgentHost {
    private let agents: Agents
    private let search: MessageSearch

    @MainActor init(agents: Agents, search: MessageSearch) {
        self.agents = agents
        self.search = search
    }

    func approve(approval: CoreAgentApproval, reply: CoreAgentApprovalReply) {
        Task { @MainActor [agents] in
            switch await agents.approve(approval) {
            case .deny: reply.refuse(reason: String(localized: "The user did not allow it in Lux."))
            case .allow(let grant, _): reply.grant(grant: grant.core)
            }
        }
    }

    func embed(words: String, reply: CoreAgentEmbeddingReply) {
        Task { @MainActor [search] in
            if let meaning = await search.meaningOfQuery(words) {
                reply.embedding(embedding: meaning.embedding, minSimilarity: meaning.minSimilarity)
            } else {
                reply.none()
            }
        }
    }

    func networkName(network: String) -> String {
        Networks.name(network)
    }

    func showDraft(roomId: String, text: String, reply: CoreAgentDraftReply) {
        Task { @MainActor [agents] in
            if await agents.showDraft(text, inRoom: roomId) {
                reply.shown()
            } else {
                reply.failed(reason: "Lux could not open the chat")
            }
        }
    }

    func confirmSend(roomId: String, text: String, client: String, reply: CoreAgentSendReply) {
        Task { @MainActor [agents] in
            reply.answer(allowed: await agents.allowSend(text, inRoom: roomId, client: client))
        }
    }

    func log(entry: CoreAgentLogEntry) {
        Task { @MainActor [agents] in agents.record(entry) }
    }
}
#endif
