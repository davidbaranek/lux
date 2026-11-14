import Intents
import UIKit

/// Tells the system the user wrote in a chat (an outgoing message, as Messages does), so the
/// share sheet suggests it among its people, and the share extension opens with it chosen
/// (`INSendMessageIntent.conversationIdentifier`, the chat's id).
enum ConversationDonation {
    static func sent(chatId: String, name: String, isGroup: Bool, picture: UIImage?) {
        let image = picture?.pngData().map { INImage(imageData: $0) }
        let recipient = INPerson(personHandle: INPersonHandle(value: chatId, type: .unknown), nameComponents: nil, displayName: name,
                                 image: isGroup ? nil : image, contactIdentifier: nil, customIdentifier: chatId)
        let intent = INSendMessageIntent(recipients: [recipient], outgoingMessageType: .outgoingMessageText, content: nil,
                                         speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: name) : nil,
                                         conversationIdentifier: chatId, serviceName: nil, sender: nil, attachments: nil)
        if isGroup, let image { intent.setImage(image, forParameterNamed: \.speakableGroupName) }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate(completion: nil)
    }
}
