import LuxCore
import UIKit

/// An image view for a picture the pipeline loads: from memory at once when it is there, else when
/// it is decoded. A reused view drops the load of the picture it showed before.
final class RemoteImageView: UIImageView {
    private(set) var ref: ImageRef?
    private var load: Task<Void, Never>?
    /// The picture came (true) or went (false).
    var onImage: ((Bool) -> Void)?

    override var image: UIImage? {
        didSet { if (image == nil) != (oldValue == nil) { onImage?(image != nil) } }
    }

    func show(_ ref: ImageRef?, pixels: Int, shape: ImagePipeline.Shape = .original, images: ImagePipeline?) {
        guard ref != self.ref || image == nil else { return }
        self.ref = ref
        load?.cancel()
        guard let ref, let images else { image = nil; return }
        if let cached = images.cached(ref, pixels: pixels, shape: shape) {
            image = UIImage(cgImage: cached)
            return
        }
        image = nil
        load = Task { [weak self] in
            guard let decoded = await images.image(ref, pixels: pixels, shape: shape), !Task.isCancelled, self?.ref == ref else { return }
            self?.image = UIImage(cgImage: decoded)
        }
    }
}

/// A round picture over the name's initials, which show until (or unless) the picture comes. The
/// picture arrives already round, and the colour circle is a plain rounded layer: nothing clips.
final class AvatarView: UIView {
    private let imageView = RemoteImageView()
    private let initials = UILabel()
    var side: CGFloat = 52

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        initials.textAlignment = .center
        initials.textColor = .white
        initials.font = .systemFont(ofSize: 20, weight: .semibold)
        imageView.onImage = { [weak self] shown in self?.placeholder(hidden: shown) }
        for view in [initials, imageView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        // the initials scale with the circle (a list's 52 pt, a chat's 28 pt).
        initials.font = .systemFont(ofSize: max(bounds.width * 0.38, 10), weight: .semibold)
    }

    /// A group with no picture: two members' pictures, one up left and one down right over it
    /// (Messenger's way). Empty shows the picture or the initials as usual.
    func show(_ ref: ImageRef?, name: String, members: [ImageRef], images: ImagePipeline?) {
        let collage = ref == nil && members.count >= 2
        if collage {
            let pair = self.pair ?? makePair()
            let small = (side * 0.68).rounded()
            for (view, member, origin) in [(pair.0, members[0], CGPoint.zero), (pair.1, members[1], CGPoint(x: side - small, y: side - small))] {
                view.side = small
                view.frame = CGRect(origin: origin, size: CGSize(width: small, height: small))
                view.show(member, name: name, images: images)
            }
            // a clear gap round the front circle, cut from the back one: whatever is behind the
            // row (its selection too) shows through.
            pair.0.layer.mask = Self.cutout(pair.0.bounds, around: pair.1.frame.offsetBy(dx: -pair.0.frame.minX, dy: -pair.0.frame.minY))
            initials.isHidden = true
            backgroundColor = .clear
            imageView.isHidden = true
        }
        // the two circles reach past the round outline: no clipping to it while they show.
        clipsToBounds = false
        pair?.0.isHidden = !collage
        pair?.1.isHidden = !collage
        imageView.isHidden = collage
        if !collage { show(ref, name: name, images: images) }
    }

    private var pair: (AvatarView, AvatarView)?

    /// A mask of `bounds` without a circle round `front`, two points wider.
    private static func cutout(_ bounds: CGRect, around front: CGRect) -> CAShapeLayer {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: front.insetBy(dx: -2, dy: -2)))
        let mask = CAShapeLayer()
        mask.path = path.cgPath
        mask.fillRule = .evenOdd
        return mask
    }

    /// The collage's two circles, made the first time a group needs them.
    private func makePair() -> (AvatarView, AvatarView) {
        let made = (AvatarView(), AvatarView())
        addSubview(made.0)
        addSubview(made.1)
        pair = made
        return made
    }

    func show(_ ref: ImageRef?, name: String, images: ImagePipeline?) {
        initials.text = Self.initials(name)
        color = Self.color(name)
        imageView.show(ref, pixels: Self.pixels(side, traitCollection), shape: .circle, images: images)
        placeholder(hidden: imageView.image != nil)
    }

    /// A picture had without the pipeline (the share extension's), over the name's initials.
    func show(_ image: UIImage?, name: String) {
        initials.text = Self.initials(name)
        color = Self.color(name)
        imageView.image = image
        placeholder(hidden: image != nil)
    }

    private var color: UIColor = .clear

    /// The initials and their colour only while there is no picture: a picture with transparent
    /// parts would show them through.
    private func placeholder(hidden: Bool) {
        initials.isHidden = hidden
        backgroundColor = hidden ? .clear : color
    }

    static func pixels(_ side: CGFloat, _ traits: UITraitCollection) -> Int { Int(side * traits.displayScale) }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    private static let palette: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemIndigo, .systemRed]

    static func color(_ name: String) -> UIColor {
        palette[Int(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ $1.value) % 9_973 }) % palette.count]
    }
}
