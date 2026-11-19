import LuxCore
import UIKit

/// The long-press menu: reactions and actions over a preview of the bubble itself.
extension ThreadViewController {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath), let message = messages[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            self?.menu(for: message)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        bubblePreview(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        bubblePreview(at: indexPath)
    }

    /// The bubble alone lifts, in its own shape; a plain row, across the row.
    private func bubblePreview(at indexPath: IndexPath) -> UITargetedPreview? {
        (collectionView.cellForItem(at: indexPath) as? MessageCell)?.menuPreview
    }

    /// Reactions on top, then what `MessageAction` offers for the message.
    private func menu(for message: MessageItem) -> UIMenu {
        var children: [UIMenuElement] = []
        if MessageAction.canReact(to: message) {
            let mine = Set(message.reactions.filter(\.isMine).map(\.key))
            let reactions = ThreadModel.quickReactions.map { key in
                UIAction(title: key, image: EmojiImage.image(key), state: mine.contains(key) ? .on : .off) { [weak self] _ in
                    self?.model.toggleReaction(key, on: message.id)
                }
            }
            let more = UIAction(title: String(localized: "More Reactions"), image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.emojiPicker.pick { emoji in self?.model.toggleReaction(emoji, on: message.id) }
            }
            children.append(UIMenu(options: [.displayInline, .displayAsPalette], children: reactions + [more]))
        }
        let actions = MessageAction.available(for: message, inThread: model.thread != nil, pinned: model.pinning(of: message)).map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol), attributes: action.isDestructive ? .destructive : []) {
                [weak self] _ in self?.perform(action, on: message)
            }
        }
        // a shared post's address, whole, to read: the menu's actions copy it.
        children.append(UIMenu(title: message.shared?.url ?? "", options: .displayInline, children: actions))
        return UIMenu(children: children)
    }

    private func perform(_ action: MessageAction, on message: MessageItem) {
        switch action {
        case .reply: model.reply(to: message)
        case .replyInThread: openThread(of: message)
        case .edit: model.edit(message)
        case .copy: UIPasteboard.general.string = message.body
        case .copyLink: UIPasteboard.general.string = message.shared?.url
        case .save: model.save(message)
        case .unsave: model.unsave(message)
        case .pin: model.pin(message, true)
        case .unpin: model.pin(message, false)
        case .retry: model.retry(message.id)
        case .discard: model.discard(message.id)
        case .forward:
            let picker = ChatPickerViewController(session: session, title: String(localized: "Forward To")) { [weak self] target in
                self?.model.forward(message.id, to: target.id)
            }
            present(UINavigationController(rootViewController: picker), animated: true)
        case .delete:
            let alert = UIAlertController(title: String(localized: "Delete this message for everyone?"),
                                          message: String(localized: "It is removed for everyone in the chat, on every network the chat is on."),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
                self?.model.delete(message.id)
            })
            present(alert, animated: true)
        }
    }
}
