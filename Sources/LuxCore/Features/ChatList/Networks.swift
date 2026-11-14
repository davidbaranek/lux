/// How the apps name and draw a chat network, by the core's id for it (`lux_core::network`): a
/// known network's own name and logo, and for any other network a bridge serves, its protocol
/// id made readable and a plain symbol, never another network's logo or "Matrix".
public enum Networks {
    /// The networks with a logo in the asset catalogue (`network-<id>`, `docs/network-logos.md`).
    static let logos: Set<String> = ["whatsapp", "signal", "messenger", "instagram", "telegram", "discord", "linkedin", "matrix"]

    /// The network's name: its brand's own spelling, or a bridge's protocol id in words.
    public static func name(_ id: String) -> String {
        switch id {
        case "whatsapp": "WhatsApp"
        case "signal": "Signal"
        case "messenger": "Messenger"
        case "instagram": "Instagram"
        case "telegram": "Telegram"
        case "discord": "Discord"
        case "linkedin": "LinkedIn"
        case "slack": "Slack"
        case "gmessages": "Google Messages"
        case "imessage": "iMessage"
        case "matrix": "Matrix"
        default: readable(id)
        }
    }

    /// The network's logo in the asset catalogue; nil for a network with none.
    public static func logo(_ id: String) -> String? {
        logos.contains(id) ? "network-\(id)" : nil
    }

    /// The SF Symbol a network without a logo shows in white on a tile like the logos'.
    public static func symbol(_ id: String) -> String {
        switch id {
        case "slack": "number"
        case "gmessages": "text.bubble.fill"
        case "imessage": "message.fill"
        default: "bubble.left.and.bubble.right.fill"
        }
    }

    /// The colour of that tile (`0xRRGGBB`): the network's own, or the system grey of
    /// `network-matrix` for a network the app does not know.
    public static func tint(_ id: String) -> UInt32 {
        switch id {
        case "slack": 0x4A154B
        case "gmessages": 0x1A73E8
        case "imessage": 0x34C759
        default: 0x8E8E93
        }
    }

    /// A protocol id in words: `"bluesky"` is Bluesky, `"google_chat"` Google Chat.
    static func readable(_ id: String) -> String {
        let words = id.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." || $0 == " " })
        guard !words.isEmpty else { return String(localized: "Other") }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
