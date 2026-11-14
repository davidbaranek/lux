import AppKit
import LuxCore

/// An image view for a picture the pipeline loads: from memory at once when it is there, else when
/// it is decoded. A reused view drops the load of the picture it showed before.
final class RemoteImageView: NSView {
    private(set) var ref: ImageRef?
    private var load: Task<Void, Never>?
    /// Called when a picture appears or goes (a placeholder behind it can hide or show).
    var onImage: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var hasImage: Bool { layer?.contents != nil }

    private func set(_ image: CGImage?) {
        layer?.contents = image
        onImage?(image != nil)
    }

    func show(_ ref: ImageRef?, pixels: Int, shape: ImagePipeline.Shape = .original, images: ImagePipeline?) {
        guard ref != self.ref || !hasImage else { return }
        self.ref = ref
        load?.cancel()
        guard let ref, let images else { set(nil); return }
        if let cached = images.cached(ref, pixels: pixels, shape: shape) {
            set(cached)
            return
        }
        set(nil)
        load = Task { [weak self] in
            guard let decoded = await images.image(ref, pixels: pixels, shape: shape), !Task.isCancelled, self?.ref == ref else { return }
            self?.set(decoded)
        }
    }
}

/// A round picture over the name's initials. The picture arrives already round and the colour
/// circle is a plain rounded layer, so nothing clips (no offscreen pass).
final class AvatarView: NSView {
    private let image = RemoteImageView()
    private let initials = NSTextField(labelWithString: "")
    private let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = side / 2
        initials.font = .systemFont(ofSize: side * 0.38, weight: .semibold)
        initials.textColor = .white
        initials.alignment = .center
        image.onImage = { [weak self] shown in self?.placeholder(hidden: shown) }
        for view in [initials, image] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            initials.centerXAnchor.constraint(equalTo: centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor),
            image.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A group with no picture: two members' pictures, one up left and one down right over it
    /// (Messenger's way). Empty shows the picture or the initials as usual.
    func show(_ ref: ImageRef?, name: String, members: [ImageRef], images: ImagePipeline?) {
        let collage = ref == nil && members.count >= 2
        if collage {
            let small = (side * 0.68).rounded()
            let pair = self.pair ?? makePair(side: small)
            pair.0.show(members[0], name: name, images: images)
            pair.1.show(members[1], name: name, images: images)
            initials.isHidden = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        // the two circles reach past the round outline: no clipping to it while they show.
        clipsToBounds = !collage
        layer?.masksToBounds = !collage
        layer?.cornerRadius = collage ? 0 : side / 2
        pair?.0.isHidden = !collage
        pair?.1.isHidden = !collage
        image.isHidden = collage
        if !collage { show(ref, name: name, images: images) }
    }

    private var pair: (AvatarView, AvatarView)?

    /// The collage's two circles of `small` points, made the first time a group needs them.
    private func makePair(side small: CGFloat) -> (AvatarView, AvatarView) {
        let made = (AvatarView(side: small), AvatarView(side: small))
        // the view is flipped-agnostic: frames from the bottom left.
        made.0.frame = NSRect(x: 0, y: side - small, width: small, height: small)
        made.1.frame = NSRect(x: side - small, y: 0, width: small, height: small)
        // a clear gap round the front circle, cut from the back one: whatever is behind the row
        // (its selection too) shows through.
        let front = made.1.frame.offsetBy(dx: -made.0.frame.minX, dy: -made.0.frame.minY).insetBy(dx: -2, dy: -2)
        let path = CGMutablePath()
        path.addRect(made.0.bounds)
        path.addEllipse(in: front)
        let mask = CAShapeLayer()
        mask.path = path
        mask.fillRule = .evenOdd
        made.0.layer?.mask = mask
        addSubview(made.0)
        addSubview(made.1)
        pair = made
        return made
    }

    func show(_ ref: ImageRef?, name: String, images: ImagePipeline?) {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        initials.stringValue = String(words.prefix(2).compactMap(\.first)).uppercased()
        color = Self.color(name)
        image.show(ref, pixels: Int(side * (window?.backingScaleFactor ?? 2)), shape: .circle, images: images)
        placeholder(hidden: image.hasImage)
    }

    private var color: NSColor = .clear

    /// The initials and their colour only while there is no picture: a picture with transparent
    /// parts would show them through.
    private func placeholder(hidden: Bool) {
        initials.isHidden = hidden
        layer?.backgroundColor = (hidden ? NSColor.clear : color).cgColor
    }

    private static let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemIndigo, .systemRed]

    static func color(_ name: String) -> NSColor {
        palette[Int(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ $1.value) % 9_973 }) % palette.count]
    }
}
