import LuxCore
import UIKit

/// A file in a bubble, as Messages draws one: its kind's symbol in a rounded square, its name
/// (one line, truncated in the middle) and its size or length under it. Laid out by hand.
final class FileRowView: UIView {
    private let tile = UIView()
    private let symbol = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()
    private let metrics: BubbleMetrics

    init(metrics: BubbleMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        tile.layer.cornerRadius = 9
        tile.layer.cornerCurve = .continuous
        symbol.contentMode = .center
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        for view in [tile, symbol, name, detail] { addSubview(view) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ file: MessageItem.File, own: Bool, text: MessageText) {
        let ink: UIColor = own ? .white : .label
        tile.backgroundColor = own ? UIColor.white.withAlphaComponent(0.22) : .systemGray4
        symbol.image = UIImage(systemName: file.symbol)
        symbol.tintColor = ink
        name.font = text.fileName
        name.textColor = ink
        name.text = file.name
        detail.font = text.footer
        detail.textColor = own ? UIColor.white.withAlphaComponent(0.75) : .secondaryLabel
        detail.text = file.detailText
        accessibilityLabel = "\(file.name), \(file.detailText)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = metrics.fileIconSide
        tile.frame = CGRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        symbol.frame = tile.frame
        let x = side + metrics.fileGap, width = max(0, bounds.width - x)
        let nameHeight = ceil(name.font.lineHeight), detailHeight = ceil(detail.font.lineHeight)
        let top = (bounds.height - nameHeight - detailHeight) / 2
        name.frame = CGRect(x: x, y: top, width: width, height: nameHeight)
        detail.frame = CGRect(x: x, y: top + nameHeight, width: width, height: detailHeight)
    }
}

/// Over a video's poster: a play symbol in its middle and its length in a corner.
final class VideoBadgeView: UIView {
    private let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let length = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        play.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor.black.withAlphaComponent(0.4)]))
        length.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        length.textColor = .white
        length.textAlignment = .center
        length.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        length.layer.cornerRadius = 9
        length.layer.masksToBounds = true
        addSubview(play)
        addSubview(length)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(duration: String?) {
        length.text = duration
        length.isHidden = duration == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = play.intrinsicContentSize
        play.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let text = length.sizeThatFits(bounds.size)
        let width = ceil(text.width) + 14
        length.frame = CGRect(x: bounds.width - width - 8, y: bounds.height - 18 - 8, width: width, height: 18)
    }
}
