import Foundation

/// A network the account's server bridges, and where its bridge is.
public struct NetworkOffer: Hashable, Sendable {
    /// The network's id (`"messenger"`, see `Networks`).
    public let network: String
    /// The bridge's provisioning API.
    let provisioning: String

    public var name: String { Networks.name(network) }
}

/// The account on a network's bridge.
public struct NetworkAccount: Sendable {
    public struct Login: Hashable, Sendable {
        public let id: String
        public let name: String
        public let state: State
    }

    public enum State: Hashable, Sendable {
        case connected, connecting, backfilling, badCredentials, loggedOut
        case error(String?)

        public var needsSignIn: Bool { self == .badCredentials || self == .loggedOut }

        public var title: String {
            switch self {
            case .connected: String(localized: "Connected")
            case .connecting: String(localized: "Connecting…")
            case .backfilling: String(localized: "Loading history…")
            case .badCredentials, .loggedOut: String(localized: "Signed out — sign in again")
            case .error(let reason): reason ?? String(localized: "Not working")
            }
        }
    }

    public struct Flow: Hashable, Sendable {
        public let id: String
        public let name: String
        public let description: String
    }

    public let logins: [Login]
    /// The ways to sign in, the bridge's preferred first.
    public let flows: [Flow]
    /// No login yet, or one the network let go.
    public let needsSignIn: Bool
}

/// The sign-in step the bridge asks for.
public enum NetworkLoginStep: Sendable {
    /// Sign in on a website; the app reads what the bridge needs from it.
    case website(Website)
    case form(Form)
    /// Show a QR code or a code while the bridge waits for the phone.
    case show(Shown)
    case done(message: String)
    case unsupported(kind: String)

    /// A step's identity at the bridge: what its answer goes back as.
    public struct ID: Sendable {
        let process: String
        let step: String
        let kind: String
        public let instructions: String
    }

    public struct Website: Sendable {
        public let id: ID
        public let url: URL
        public let userAgent: String?
        public let fields: [Field]
        public let extractJS: String?
        /// The page's address once signed in, as a regular expression.
        public let doneURLPattern: String?
        public let hidden: Bool

        public struct Field: Sendable {
            public let id: String
            public let required: Bool
            public let sources: [Source]
        }

        public enum Source: Sendable {
            case cookie(name: String, domain: String?)
            case localStorage(name: String)
            case script(name: String)
            case unreadable
        }
    }

    public struct Form: Sendable {
        public let id: ID
        public let fields: [Field]

        public struct Field: Sendable {
            public enum Kind: Sendable { case username, password, phoneNumber, email, code, text, choice }
            public let id: String
            public let kind: Kind
            public let name: String
            public let description: String
            public let defaultValue: String
            public let optional: Bool
            public let pattern: String?
            public let choices: [String]

            /// Whether `value` is one the bridge takes: present unless optional, and matching the
            /// pattern when one is given.
            public func accepts(_ value: String) -> Bool {
                if value.isEmpty { return optional }
                // a pattern this device cannot read: the bridge checks the value itself.
                guard let pattern, let expression = bestEffort("network sign-in: a field's pattern", { try Regex(pattern) }) else { return true }
                return value.wholeMatch(of: expression) != nil
            }
        }
    }

    public struct Shown: Sendable {
        public enum What: Sendable {
            case qrCode(String)
            case code(String)
            case emoji(String, imageURL: URL?)
            case nothing
        }

        public let id: ID
        public let what: What
    }
}

/// A network whose history is arriving through its bridge.
public struct CatchUp: Hashable, Sendable {
    public let network: String
    public let chats: Int
    public let messages: Int

    public var title: String {
        String(localized: "\(Networks.name(network)): loading history")
    }

    public var detail: String {
        String(localized: "\(messages) messages in \(chats) chats so far")
    }
}

/// Why something with a network's bridge failed, in the user's words: what the server's admin has
/// to set up says so, a refusal of what the user entered says the bridge's reason.
public enum BridgeFailure: LocalizedError, Equatable, Sendable {
    /// The bridge does not answer at the address the server gives.
    case unreachable
    /// The bridge answered, but not to the app's sign-in (it does not take Matrix sign-ins, or
    /// cannot check them with the server).
    case notAccepted
    /// The bridge does not let this account sign in.
    case notPermitted
    /// No bridge answers at the server's address for it.
    case notFound
    /// The bridge refused what the user entered, in its words.
    case refused(String)
    case account(AccountFailure)

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            String(localized: "The bridge for this network does not answer. Its server may be down, or the address the server gives for it is wrong.")
        case .notAccepted:
            String(localized: "The bridge does not accept Lux's sign-in. The server's admin has to allow Matrix sign-ins for its provisioning API.")
        case .notPermitted:
            String(localized: "The bridge does not let this account sign in to the network. Ask the server's admin.")
        case .notFound:
            String(localized: "No bridge answers at the address the server gives for this network. The server's admin has to fix it.")
        case .refused(let reason):
            reason
        case .account(let failure):
            failure.errorDescription
        }
    }

    /// The server's setup is wrong, not something the user can fix.
    public var isServerSetup: Bool {
        switch self {
        case .unreachable, .notAccepted, .notPermitted, .notFound: true
        case .refused, .account: false
        }
    }
}

/// Where the server's admin reads how to offer networks to Lux.
public enum BridgeSetup {
    public static let guide = URL(string: "https://github.com/davidbaranek/lux/blob/dev/docs/bridges.md")!
}
