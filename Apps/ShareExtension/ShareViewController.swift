import Intents
import LuxCore
import UIKit
import UniformTypeIdentifiers

/// What another app shares, sent to one chat: the chats as the app last listed them (a chat the
/// system suggested chosen already), a line to add, the shared photos, videos, files and links
/// shown above it. Sending waits until the server has it; what the extension cannot wait for goes
/// out when the app opens next.
final class ShareViewController: UIViewController {
    private let list = UITableView(frame: .zero, style: .insetGrouped)
    private let search = UISearchBar()
    private let preview = SharePreviewView()
    private let message = UITextField()
    private var sender: ShareSender?
    private var chats: [ShareChat] = []
    private var shown: [ShareChat] = []
    private var chosen: ShareChat? { didSet { navigationItem.rightBarButtonItem?.isEnabled = chosen != nil && !sending } }
    private var sending = false
    /// The shared items, read from their providers.
    private var items = SharedItems()
    private var pictures: [String: UIImage] = [:]
    /// Pictures on their way: a row drawn again does not ask for its picture a second time.
    private var loading: Set<String> = []
    /// Draws a chat's picture for its row.
    private let avatar = AvatarView()
    private static let chatCell = "chat"
    /// Where the shared files are copied for sending: the extension's own temporary folder.
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Send to")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        let send = UIBarButtonItem(title: String(localized: "Send"), primaryAction: UIAction { [weak self] _ in self?.send() })
        send.style = .prominent
        send.isEnabled = false
        navigationItem.rightBarButtonItem = send

        message.placeholder = String(localized: "Add a message")
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.borderStyle = .none
        message.returnKeyType = .done
        message.addAction(UIAction { [weak self] _ in self?.message.resignFirstResponder() }, for: .editingDidEndOnExit)
        search.searchBarStyle = .minimal
        search.placeholder = String(localized: "Search")
        search.delegate = self
        list.dataSource = self
        list.delegate = self
        list.register(UITableViewCell.self, forCellReuseIdentifier: Self.chatCell)
        avatar.side = 36
        avatar.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        list.keyboardDismissMode = .onDrag

        let card = UIStackView(arrangedSubviews: [preview, message])
        card.axis = .vertical
        card.spacing = 12
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        for view in [card, search, list] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            list.topAnchor.constraint(equalTo: search.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        Task { await load() }
    }

    /// Reads the shared items and opens the account, together.
    private func load() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let opening = Task { try await ShareSender.open() }
        do {
            items = try await SharedItems.read(providers, into: folder)
        } catch {
            Log.app.error("share: \(String(describing: error), privacy: .public)")
            fail(String(localized: "What you shared could not be read."), retry: false)
            return
        }
        do {
            sender = try await opening.value
        } catch {
            Log.app.error("share: \(String(describing: error), privacy: .public)")
        }
        preview.show(items)
        if message.text?.isEmpty ?? true { message.text = items.text }
        guard let sender else {
            fail(String(localized: "Sign in to Lux first."), retry: false)
            return
        }
        chats = sender.chats
        // the chat the system suggested (a conversation the app donated), chosen already.
        if let suggested = (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier {
            chosen = chats.first { $0.id == suggested }
        }
        filter("")
    }

    private func filter(_ text: String) {
        let words = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        shown = words.isEmpty ? chats : chats.filter {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(words)
        }
        list.reloadData()
    }

    private func picture(for chat: ShareChat) -> UIImage? {
        guard let ref = chat.avatar ?? chat.memberAvatars.first, case .person(let url) = ref else { return nil }
        if let picture = pictures[url] { return picture }
        guard loading.insert(url).inserted else { return nil }
        // decoded off the main thread at the row's size: a full-size bitmap per chat would cost the
        // extension memory it does not have.
        let pixels = CGSize(width: avatar.side * traitCollection.displayScale, height: avatar.side * traitCollection.displayScale)
        Task { [weak self] in
            guard let data = await self?.sender?.picture(ref),
                  let image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: pixels),
                  let self else { return }
            pictures[url] = image
            // only the rows that show it draw again.
            let rows = shown.indices.filter { [shown] in
                guard let ref = shown[$0].avatar ?? shown[$0].memberAvatars.first, case .person(let shownURL) = ref else { return false }
                return shownURL == url
            }
            list.reconfigureRows(at: rows.map { IndexPath(row: $0, section: 0) })
        }
        return nil
    }

    private func send() {
        guard let chat = chosen, let sender, !sending else { return }
        sending = true
        message.resignFirstResponder()
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.rightBarButtonItem?.customView = spinner
        let text = message.text ?? ""
        Task {
            do {
                var attachments: [OutgoingAttachment] = []
                for file in items.files {
                    attachments.append(try await AttachmentMaker.prepare(file, in: folder.appendingPathComponent("outgoing", isDirectory: true)))
                }
                try await sender.send(to: chat, text: text, attachments: attachments)
                ConversationDonation.sent(chatId: chat.id, name: chat.name, isGroup: chat.isGroup, picture: picture(for: chat))
                finish()
            } catch {
                Log.app.error("share send: \(String(describing: error), privacy: .public)")
                sending = false
                navigationItem.rightBarButtonItem?.customView = nil
                chosen = chat
                fail(String(localized: "The message could not be sent."), retry: true)
            }
        }
    }

    private func fail(_ text: String, retry: Bool) {
        let alert = UIAlertController(title: text, message: nil, preferredStyle: .alert)
        if retry { alert.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .default) { [weak self] _ in self?.send() }) }
        alert.addAction(UIAlertAction(title: String(localized: "Close"), style: .cancel) { [weak self] _ in self?.cancel() })
        present(alert, animated: true)
    }

    private func finish() {
        bestEffort("share: the copied files stay") { try FileManager.default.removeItemIfPresent(at: folder) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        bestEffort("share: the copied files stay") { try FileManager.default.removeItemIfPresent(at: folder) }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

extension ShareViewController: UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.chatCell, for: indexPath)
        let chat = shown[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = chat.name
        content.secondaryText = Networks.name(chat.network)
        content.secondaryTextProperties.color = .secondaryLabel
        avatar.show(picture(for: chat), name: chat.name)
        content.image = avatar.snapshot()
        content.imageProperties.maximumSize = CGSize(width: 36, height: 36)
        cell.contentConfiguration = content
        cell.accessoryType = chat.id == chosen?.id ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !sending else { return }
        let before = chosen.flatMap { old in shown.firstIndex { $0.id == old.id } }
        chosen = shown[indexPath.row]
        tableView.reconfigureRows(at: [before, indexPath.row].compactMap { $0 }.map { IndexPath(row: $0, section: 0) })
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { filter(searchText) }
}

private extension UIView {
    /// The view drawn into an image (a cell's picture).
    func snapshot() -> UIImage {
        UIGraphicsImageRenderer(bounds: bounds).image { layer.render(in: $0.cgContext) }
    }
}

/// The extension's root: the chooser in a navigation bar, as a share sheet shows it.
@objc(ShareNavigationController)
final class ShareNavigationController: UINavigationController {
    init() { super.init(rootViewController: ShareViewController()) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
