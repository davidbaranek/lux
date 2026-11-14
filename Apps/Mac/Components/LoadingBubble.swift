import AppKit

/// A small Liquid Glass capsule with a spinner, at the top of a view while it loads.
final class LoadingBubble: NSView {
    private let glass = NSGlassEffectView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.stringValue = text
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
        glass.contentView = stack
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.heightAnchor.constraint(equalToConstant: 30),
        ])
        wantsLayer = true
        alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Fades in or out; shows only after a short wait, so a fast load shows nothing.
    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    private var wanted = false

    func set(visible: Bool) {
        wanted = visible
        Task {
            if visible { try? await Task.sleep(for: .milliseconds(250)) }
            guard wanted == visible else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                animator().alphaValue = visible ? 1 : 0
            }, completionHandler: nil)
        }
    }
}
