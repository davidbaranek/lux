import UIKit

extension UIFont {
    /// The same font, bold.
    var bold: UIFont { UIFont(descriptor: fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor, size: 0) }
}
