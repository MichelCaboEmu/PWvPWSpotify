import UIKit
import ObjectiveC

@MainActor
private final class PWLibraryFilterControl: NSObject {
    let state = PWLibraryFilterLayout()
    let button = UIButton(type: .system)
    weak var collection: UICollectionView?
    weak var scroll: UIScrollView?
    var baseInset: CGFloat = 0
    var observer: NSObjectProtocol?
    private var lastReport = ""
    init(collection: UICollectionView, scroll: UIScrollView, host: UIView) {
        super.init(); self.collection = collection; self.scroll = scroll; baseInset = scroll.contentInset.left
        button.overrideUserInterfaceStyle = .dark
        button.accessibilityIdentifier = "PW.Library.DownloadedFilter"
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        host.addSubview(button)
        state.report = { [weak self] shown, total, valid in
            guard let self = self else { return }
            let report = "\(shown)/\(total)/\(valid)"
            if self.lastReport != report {
                self.lastReport = report
                pwEvent("library_downloaded_filter", details: ["shown":shown,"native_items":total,"schema_valid":valid])
            }
            if !valid { self.state.active = false; self.paint() }
        }
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateAvailability() }
        }
        paint(); place()
        var inset = scroll.contentInset; inset.left = baseInset + 150; scroll.contentInset = inset
        scroll.contentOffset.x -= 150
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    private func paint() {
        var config: UIButton.Configuration
        if state.active { config = .filled(); config.baseBackgroundColor = .systemGreen; config.baseForegroundColor = .black }
        else {
            if #available(iOS 26.0, *) { config = .glass() } else { config = .tinted() }
            config.baseForegroundColor = .white
        }
        config.title = "Téléchargés"; config.image = UIImage(systemName: "arrow.down.circle.fill")
        config.imagePadding = 6; config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
            var values = values; values.font = .systemFont(ofSize: 14, weight: .semibold); return values
        }
        button.configuration = config
        button.accessibilityTraits = state.active ? [.button, .selected] : [.button]
        button.accessibilityHint = "Afficher les playlists avec au moins un titre téléchargé sur cet iPhone"
    }
    func place() {
        guard let host = button.superview, let scroll = scroll else { return }
        button.frame = CGRect(x: 6, y: max(0, (host.bounds.height - 36) / 2), width: 138, height: 36)
        var inset = scroll.contentInset; inset.left = baseInset + 150
        if scroll.contentInset.left != inset.left { scroll.contentInset = inset }
        host.bringSubviewToFront(button)
    }
    func updateAvailability() {
        guard state.active else { return }
        // Membership is playlist-scoped; an unrelated downloaded file cannot
        // make a playlist qualify unless that track actually belongs to it.
        let library = PWLocalLibrary.shared
        state.eligible = Set(library.catalog.playlists.values.filter { list in
            list.trackIDs.contains { library.available($0, playlist: list.uri) != nil || library.available($0) != nil }
        }.compactMap { PWLibraryFilterRules.key($0.uri) })
        collection?.collectionViewLayout.invalidateLayout()
    }
    @objc private func toggle() {
        _ = PWDownloadStore.shared
        state.active.toggle(); paint(); updateAvailability()
        collection?.collectionViewLayout.invalidateLayout()
        if let collection = collection {
            collection.setContentOffset(CGPoint(x: 0, y: -collection.adjustedContentInset.top), animated: false)
        }
    }
}
private var pwLibraryControlKey: UInt8 = 0
private var pwLibraryLayoutKey: UInt8 = 0

extension PWDownloadsBridge {
    @objc(installDownloadedLibraryFilter:)
    static func installDownloadedLibraryFilter(_ root: UIView) {
        guard UserDefaults.standard.integer(forKey: "spotifyglass.download.source") != 2 else { return }
        func find(_ view: UIView, _ predicate: (UIView) -> Bool) -> UIView? {
            if predicate(view) { return view }
            for child in view.subviews { if let value = find(child, predicate) { return value } }
            return nil
        }
        guard let collection = find(root, { $0.accessibilityIdentifier == "YourLibraryContent.collectionView" }) as? UICollectionView,
              let source = collection.dataSource, String(reflecting: type(of: source)).contains("YourLibraryContentViewBinder") else { return }
        if let control = objc_getAssociatedObject(root, &pwLibraryControlKey) as? PWLibraryFilterControl {
            objc_setAssociatedObject(collection.collectionViewLayout, &pwLibraryLayoutKey, control.state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            control.place(); return
        }
        guard let host = find(root, { NSStringFromClass(type(of: $0)).contains("YourLibraryHeaderContentFiltersView") }),
              host.bounds.height >= 30,
              let scroll = find(host, { $0 is UIScrollView }) as? UIScrollView else { return }
        let control = PWLibraryFilterControl(collection: collection, scroll: scroll, host: host)
        objc_setAssociatedObject(root, &pwLibraryControlKey, control, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(collection.collectionViewLayout, &pwLibraryLayoutKey, control.state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        pwEvent("library_downloaded_filter_installed")
    }
    private static func libraryState(_ layout: UICollectionViewLayout) -> PWLibraryFilterLayout? {
        objc_getAssociatedObject(layout, &pwLibraryLayoutKey) as? PWLibraryFilterLayout
    }
    @objc(prepareDownloadedLibraryLayout:)
    static func prepareDownloadedLibraryLayout(_ layout: UICollectionViewLayout) { libraryState(layout)?.prepare(layout) }
    @objc(downloadedLibraryLayoutActive:)
    static func downloadedLibraryLayoutActive(_ layout: UICollectionViewLayout) -> Bool { libraryState(layout)?.filtering == true }
    @objc(downloadedLibraryElements:rect:)
    static func downloadedLibraryElements(_ layout: UICollectionViewLayout, rect: CGRect) -> [UICollectionViewLayoutAttributes] {
        libraryState(layout)?.elements(in: rect) ?? []
    }
    @objc(downloadedLibraryItem:path:)
    static func downloadedLibraryItem(_ layout: UICollectionViewLayout, path: IndexPath) -> UICollectionViewLayoutAttributes? { libraryState(layout)?.item(at: path) }
    @objc(downloadedLibrarySupplementary:kind:path:)
    static func downloadedLibrarySupplementary(_ layout: UICollectionViewLayout, kind: String, path: IndexPath) -> UICollectionViewLayoutAttributes? {
        libraryState(layout)?.attributes.first { $0.representedElementKind == kind && $0.indexPath == path }
    }
    @objc(downloadedLibrarySize:)
    static func downloadedLibrarySize(_ layout: UICollectionViewLayout) -> CGSize { libraryState(layout)?.size ?? .zero }
}
