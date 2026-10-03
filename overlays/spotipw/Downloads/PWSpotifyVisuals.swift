import UIKit
import CoreText

// Names and codepoints read from Spotify 9.1.78's own Fonts.bundle.
// Resources stay in Spotify's bundle; no copied font or guessed private factory.
@MainActor
enum PWSpotifyVisuals {
    private static var loaded = Set<String>()
    static func font(_ name: String, size: CGFloat, fallback: UIFont.Weight = .regular) -> UIFont {
        if let font = UIFont(name: name, size: size) { return font }
        if loaded.insert(name).inserted {
            let file = name == "SpotifyMixUITitleVar-Regular" ? "SpotifyMixUITitleVariable" : name
            let url = Bundle.main.bundleURL.appendingPathComponent("Frameworks/SpotifyShared.framework/Fonts.bundle/" + file + ".ttf")
            if FileManager.default.fileExists(atPath: url.path) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: fallback)
    }
    static func icon(_ name: String, size: CGFloat, color: UIColor = .white) -> UIImage? {
        let codes: [String: UInt32] = ["downloaded": 0xf32c, "download": 0xf399, "play": 0xf1c8,
            "pause": 0xf1d3, "previous": 0xf1d6, "next": 0xf1d7, "shuffle": 0xf1d5,
            "repeat": 0xf1d4, "repeatOne": 0xf201, "queue": 0xf3a3, "devices": 0xf3be,
            "close": 0xf394, "more": 0xf1cc]
        guard let code = codes[name], let scalar = UnicodeScalar(code) else { return nil }
        let face = font("spoticon", size: size)
        guard face.fontName == "spoticon" else { return nil }
        let text = NSAttributedString(string: String(scalar), attributes: [.font: face, .foregroundColor: color])
        let bounds = text.boundingRect(with: CGSize(width: size * 3, height: size * 3), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            text.draw(at: CGPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY))
        }.withRenderingMode(.alwaysOriginal)
    }
}

@MainActor
enum PWDownloadedIndicator {
    private static let marker = NSAttributedString.Key("PWDownloadedIndicator")
    static func apply(to label: UILabel, downloaded: Bool) {
        let current = label.attributedText ?? NSAttributedString(string: label.text ?? "", attributes: [.font: label.font as Any, .foregroundColor: label.textColor as Any])
        var marked = NSRange(location: 0, length: 0)
        let present = current.length > 0 && current.attribute(marker, at: 0, effectiveRange: &marked) != nil
        if present == downloaded { return }
        let text = NSMutableAttributedString(attributedString: current)
        if present { text.deleteCharacters(in: marked) }
        if downloaded {
            let side = max(12, min(16, label.font.capHeight + 2))
            let attachment = NSTextAttachment()
            let green = UIColor(red: 0.114, green: 0.725, blue: 0.329, alpha: 1)
            attachment.image = PWSpotifyVisuals.icon("downloaded", size: side, color: green)
                ?? UIImage(systemName: "arrow.down.circle.fill")?.withTintColor(green, renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0, y: (label.font.capHeight - side) / 2, width: side, height: side)
            let prefix = NSMutableAttributedString(attachment: attachment)
            prefix.append(NSAttributedString(string: "\u{2002}", attributes: [.font: label.font as Any]))
            prefix.addAttribute(marker, value: true, range: NSRange(location: 0, length: prefix.length))
            text.insert(prefix, at: 0)
        }
        label.attributedText = text
    }
}
