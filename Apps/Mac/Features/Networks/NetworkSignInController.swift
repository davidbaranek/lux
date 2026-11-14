import AppKit
import CoreImage.CIFilterBuiltins
import LuxCore

/// Signing in to one network, as a sheet over the window: each step the bridge asks for in turn,
/// the network's website to sign in on (what the bridge needs is read from it), a form, or a QR
/// code or code for the phone while the bridge waits, then a check mark. Cancel cancels it.
final class NetworkSignInController: NSViewController {
    private let signIn: NetworkSignIn
    private let finished: () -> Void
    private var isDone = false
    private let content = NSView()
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private let continueButton = NSButton(title: String(localized: "Continue"), target: nil, action: nil)
    private var reader: WebsiteLoginReader?
    /// The website step the reader reads for.
    private var website: NetworkLoginStep.Website?
    private var form: (step: NetworkLoginStep.Form, fields: [String: NSTextField])?
    private var watching: Timer?

    /// Shows the sign-in as a sheet of `window`; `finished` runs once signed in.
    static func present(_ signIn: NetworkSignIn, over window: NSWindow, finished: @escaping () -> Void) {
        let controller = NetworkSignInController(signIn: signIn, finished: finished)
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled, .resizable]
        window.beginSheet(sheet, completionHandler: nil)
    }

    private init(signIn: NetworkSignIn, finished: @escaping () -> Void) {
        self.signIn = signIn
        self.finished = finished
        super.init(nibName: nil, bundle: nil)
        title = signIn.offer.name
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.keyEquivalent = "\r"
        continueButton.isHidden = true
        let buttons = NSStackView(views: [cancelButton, continueButton])
        content.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            buttons.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        view = root
        show(centered: [spinner()])
        run { try await self.signIn.start() }
    }

    private func run(_ call: @escaping () async throws -> NetworkLoginStep) {
        Task {
            do { show(try await call()) } catch { failed(error) }
        }
    }

    private func show(_ step: NetworkLoginStep) {
        reader?.stop()
        reader = nil
        website = nil
        form = nil
        watching?.invalidate()
        continueButton.isHidden = true
        let offer = signIn.offer
        switch step {
        case .website(let website):
            let reader = WebsiteLoginReader(step: website) { [weak self] values in
                guard let self else { return }
                run { try await self.signIn.answer(website.id, values: values) }
            }
            self.reader = reader
            self.website = website
            let prompt = label(String(localized: "Sign in to \(offer.name). Lux continues by itself once you are in."), size: NSFont.smallSystemFontSize)
            reader.webView.translatesAutoresizingMaskIntoConstraints = false
            reader.webView.isHidden = website.hidden
            replace(with: [prompt, reader.webView], centered: false)
            reader.webView.widthAnchor.constraint(greaterThanOrEqualToConstant: 820).isActive = true
            reader.webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 620).isActive = true
            continueButton.isHidden = false
            continueButton.isEnabled = false
            watching = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.continueButton.isEnabled = self?.reader?.hasRequired == true }
            }
            reader.start()
        case .form(let step):
            var views: [NSView] = []
            if !step.id.instructions.isEmpty { views.append(label(step.id.instructions, size: NSFont.systemFontSize)) }
            var fields: [String: NSTextField] = [:]
            for field in step.fields {
                let text: NSTextField = field.kind == .password ? NSSecureTextField() : NSTextField()
                text.placeholderString = field.name
                text.stringValue = field.defaultValue
                // a large, rounded field, as the system's own sign-in sheets show them.
                text.bezelStyle = .roundedBezel
                text.controlSize = .large
                text.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
                text.widthAnchor.constraint(equalToConstant: 320).isActive = true
                fields[field.id] = text
                views.append(text)
                if !field.description.isEmpty { views.append(label(field.description, size: NSFont.smallSystemFontSize)) }
            }
            form = (step, fields)
            continueButton.isHidden = false
            continueButton.isEnabled = true
            continueButton.title = step.fields.allSatisfy(\.optional) ? String(localized: "Continue or Skip") : String(localized: "Continue")
            show(centered: views)
            view.window?.makeFirstResponder(fields[step.fields.first?.id ?? ""])
        case .show(let shown):
            var views: [NSView] = [logo(), label(shown.id.instructions.isEmpty ? String(localized: "Open \(offer.name) on your phone.") : shown.id.instructions,
                                                 size: NSFont.systemFontSize)]
            switch shown.what {
            case .qrCode(let data):
                let image = NSImageView(image: Self.qrCode(data) ?? NSImage())
                image.imageScaling = .scaleProportionallyUpOrDown
                image.widthAnchor.constraint(equalToConstant: 240).isActive = true
                image.heightAnchor.constraint(equalToConstant: 240).isActive = true
                image.setAccessibilityLabel(String(localized: "QR code to scan with \(offer.name)"))
                views.append(image)
            case .code(let text), .emoji(let text, _):
                let code = NSTextField(labelWithString: text)
                code.font = .monospacedSystemFont(ofSize: 30, weight: .semibold)
                code.isSelectable = true
                views.append(code)
            case .nothing:
                break
            }
            views.append(NSStackView(views: [spinner(), label(String(localized: "Waiting for your phone…"), size: NSFont.smallSystemFontSize)]))
            show(centered: views)
            run { try await self.signIn.wait(shown.id) }
        case .done(let message):
            isDone = true
            let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
            check.symbolConfiguration = .init(pointSize: 48, weight: .regular)
            check.contentTintColor = .systemGreen
            var views: [NSView] = [check, label(String(localized: "\(offer.name) is connected"), size: 17)]
            if !message.isEmpty { views.append(label(message, size: NSFont.smallSystemFontSize)) }
            views.append(label(String(localized: "Its chats and their history arrive over the next minutes."), size: NSFont.smallSystemFontSize))
            show(centered: views)
            cancelButton.title = String(localized: "Done")
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                end()
            }
        case .unsupported:
            failed(BridgeFailure.refused(String(localized: "Lux cannot take this way of signing in yet.")))
        }
    }

    @objc private func continueTapped() {
        if let reader, let website, reader.hasRequired {
            let values = reader.readValues
            reader.stop()
            self.reader = nil
            continueButton.isEnabled = false
            run { try await self.signIn.answer(website.id, values: values) }
        } else if let form {
            let values = form.fields.mapValues(\.stringValue)
            guard form.step.fields.allSatisfy({ $0.accepts(values[$0.id] ?? "") }) else { NSSound.beep(); return }
            continueButton.isEnabled = false
            run { try await self.signIn.answer(form.step.id, values: values) }
        }
    }

    private func failed(_ error: any Error) {
        guard let window = view.window else { return }
        continueButton.isEnabled = true
        let failure = error as? BridgeFailure
        enum Answer { case guide, tryAgain, startOver }
        let answer: Answer = if failure?.isServerSetup == true { .guide }
            else if case .refused? = failure, form != nil { .tryAgain }
            else { .startOver }
        let others = signIn.otherFlows
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not sign in to \(signIn.offer.name)")
        alert.informativeText = error.localizedDescription
        switch answer {
        case .guide:
            alert.addButton(withTitle: String(localized: "How to Set It Up"))
            alert.addButton(withTitle: String(localized: "Close"))
        case .tryAgain:
            // a wrong code or PIN: the form stays, to try again.
            alert.addButton(withTitle: String(localized: "Try Again"))
        case .startOver:
            alert.addButton(withTitle: String(localized: "Start Over"))
            alert.addButton(withTitle: String(localized: "Close"))
            // the network may refuse one way (a password through the bridge) and take another
            // (its website).
            for flow in others {
                alert.addButton(withTitle: String(localized: "Try \(flow.name) Instead"))
            }
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let first = response == .alertFirstButtonReturn
            switch answer {
            case .guide:
                if first { NSWorkspace.shared.open(BridgeSetup.guide) }
                cancel()
            case .tryAgain:
                break
            case .startOver where first:
                show(centered: [spinner()])
                run { try await self.signIn.start() }
            case .startOver where response.rawValue >= NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                let flow = others[response.rawValue - NSApplication.ModalResponse.alertThirdButtonReturn.rawValue]
                show(centered: [spinner()])
                run { try await self.signIn.start(with: flow) }
            case .startOver:
                cancel()
            }
        }
    }

    @objc private func cancel() {
        if !isDone { signIn.cancel() }
        end()
    }

    private func end() {
        reader?.stop()
        watching?.invalidate()
        guard let sheet = view.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
        if isDone { finished() }
    }

    // MARK: Views

    private func show(centered views: [NSView]) { replace(with: views, centered: true) }

    private func replace(with views: [NSView], centered: Bool) {
        content.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = centered ? .centerX : .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: centered ? 32 : 0, bottom: 8, right: centered ? 32 : 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func label(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.alignment = .center
        label.preferredMaxLayoutWidth = 400
        if size < NSFont.systemFontSize { label.textColor = .secondaryLabelColor }
        return label
    }

    private func logo() -> NSImageView {
        let logo = NSImageView(image: NetworkImage.image(signIn.offer.network))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 48).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return logo
    }

    private func spinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        return spinner
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let representation = NSCIImageRep(ciImage: image)
        let result = NSImage(size: representation.size)
        result.addRepresentation(representation)
        return result
    }
}
