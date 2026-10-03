import UIKit

// Read-only measurement of Spotify's displayed player, keyed by screen, safe
// area, text size and appearance. No screenshots, track text or cover are stored.
@MainActor
enum PWNativePlayerAppearance {
    private static let storage = "spotifyglass.download.nativePlayerGeometry.v1"
    private static var lastWrite = Date.distantPast
    private static func key(_ view: UIView) -> String {
        let window = view.window
        let size = window?.bounds.size ?? view.bounds.size
        let safe = window?.safeAreaInsets ?? view.safeAreaInsets
        return "\(Int(size.width))x\(Int(size.height))/\(Int(safe.top))/\(Int(safe.bottom))/\(view.traitCollection.preferredContentSizeCategory.rawValue)/\(UserDefaults.standard.bool(forKey: "spotifyglass.redesign"))"
    }
    static func read(for view: UIView) -> [String: Any]? {
        (UserDefaults.standard.dictionary(forKey: storage)?[key(view)] as? [String: Any])
    }
    static func capture(_ controller: UIViewController) {
        guard let root = controller.viewIfLoaded, let window = root.window,
              controller.presentedViewController == nil, Date().timeIntervalSince(lastWrite) > 1,
              root.bounds.height > window.bounds.height * 0.8 else { return }
        lastWrite = Date()
        func visible(_ view: UIView) -> Bool {
            var current: UIView? = view
            while let v = current, v !== window { if v.isHidden || v.alpha < 0.1 { return false }; current = v.superview }
            return true
        }
        var views: [UIView] = []
        func walk(_ view: UIView) { views.append(view); view.subviews.forEach(walk) }
        walk(root)
        func identified(_ name: String) -> UIView? { views.first { $0.accessibilityIdentifier == name && visible($0) } }
        func label(_ view: UIView?) -> UILabel? {
            guard let view = view else { return nil }
            if let label = view as? UILabel { return label }
            return view.subviews.compactMap { label($0) }.first
        }
        var targets: [String: UIView] = [:]
        for (name, identifier) in ["song":"now-playing-title-label", "artist":"now-playing-subtitle-label",
            "close":"now-playing-minimize-button", "more":"Context menu", "previous":"SPTNowPlayingPreviousTrackButton",
            "play":"SPTNowPlayingPlayButton", "next":"SPTNowPlayingNextTrackButton", "slider":"SPTNowPlayingSliderV2",
            "elapsed":"now-playing-time-take-label", "remaining":"now-playing-time-remaning-label",
            "devices":"Components.ConnectButtonOutputSwitcher", "queue":"QueueButtonNowPlaying"] {
            if let view = identified(identifier) { targets[name] = ["song", "artist", "elapsed", "remaining"].contains(name) ? (label(view) ?? view) : view }
        }
        // These row orders are verified in Native/Player/PlayerDeclutter.x.
        func units(_ controller: UIViewController) {
            let name = NSStringFromClass(type(of: controller))
            if name.contains("PlaybackControlsElementsUnit"), let view = controller.viewIfLoaded {
                func stack(_ v: UIView) -> UIStackView? { (v as? UIStackView) ?? v.subviews.compactMap { stack($0) }.first }
                if let row = stack(view), row.arrangedSubviews.count == 5 {
                    targets["shuffle"] = row.arrangedSubviews[0]; targets["repeat"] = row.arrangedSubviews[4]
                }
            }
            if name.contains("HeaderElementsUnit"), let view = controller.viewIfLoaded {
                let labels = views.compactMap { $0 as? UILabel }.filter { $0.isDescendant(of: view) && visible($0) }
                targets["heading"] = labels.max { $0.bounds.width < $1.bounds.width }
            }
            controller.children.forEach(units)
        }
        units(controller)
        let covers = views.filter { v in
            let name = NSStringFromClass(type(of: v))
            let rect = window.convert(v.bounds, from: v)
            return visible(v) && v.bounds.width > 200 && abs(v.bounds.width - v.bounds.height) < 5
                && (name.contains("CoverArtTiltView") || name.contains("SGRArtwork") || v is UIImageView)
                && abs(rect.midX - window.bounds.midX) < 30 && rect.minY > window.safeAreaInsets.top
        }
        targets["cover"] = covers.max { $0.bounds.width < $1.bounds.width }
        guard let cover = targets["cover"], let title = targets["song"], targets["play"] != nil,
              targets["artist"] != nil, targets["previous"] != nil, targets["next"] != nil,
              window.convert(title.bounds, from: title).minY > window.convert(cover.bounds, from: cover).maxY else { return }
        var profile: [String: Any] = [:]
        for (role, view) in targets {
            let rect = window.convert(view.bounds, from: view)
            guard rect.width > 0, rect.height > 0, rect.minY >= 0, rect.maxY <= window.bounds.height else { continue }
            profile[role] = NSStringFromCGRect(rect)
            if let label = view as? UILabel { profile[role + "Font"] = label.font.fontName; profile[role + "Size"] = label.font.pointSize }
        }
        profile["coverRadius"] = cover.layer.cornerRadius
        var all = UserDefaults.standard.dictionary(forKey: storage) ?? [:]
        let id = key(root)
        if let existing = all[id] as? NSDictionary, existing.isEqual(to: profile) { return }
        if all.count > 8 { all.removeAll() }
        all[id] = profile; UserDefaults.standard.set(all, forKey: storage); lastWrite = Date()
        pwEvent("native_player_geometry_saved", targets.count)
    }
}
