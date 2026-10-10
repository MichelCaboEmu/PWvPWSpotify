import UIKit
import Darwin

@MainActor
final class NativeRowFixtureTable: UITableView {
    let sample = UITableViewCell(style: .default, reuseIdentifier: nil)
    override var visibleCells: [UITableViewCell] { [sample] }
}

@MainActor
final class NativeMenuFixture: NSObject, UITableViewDataSource, UITableViewDelegate {
    var count = 3
    var selected: IndexPath?
    var rendered: [Int] = []
    var highlighted: IndexPath?
    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? count : 1 }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 56 }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { .leastNormalMagnitude }
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNormalMagnitude }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        rendered.append(indexPath.row)
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let icon = UIImageView(image: UIImage(systemName: "square.and.arrow.up")); icon.frame = CGRect(x: 16, y: 16, width: 24, height: 24)
        let label = UILabel(frame: CGRect(x: 54, y: 14, width: 200, height: 28)); label.text = "Action \(indexPath.row)"; label.font = .systemFont(ofSize: 18)
        cell.contentView.addSubview(icon); cell.contentView.addSubview(label); return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { selected = indexPath }
    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        precondition(indexPath.row < (indexPath.section == 0 ? count : 1)); highlighted = indexPath; return true
    }
}


private struct FilterInfo { var uri: URL }
private struct FilterEntity { var entityInfo: FilterInfo }
private enum FilterItem { case contentItem(FilterEntity) }
private struct FilterWindow { var items: [FilterItem]; var range: Range<Int> }
private struct FilterSection { var items: FilterWindow }
private struct FilterContent { var sections: [FilterSection] }
private struct FilterModel { var content: FilterContent }
@MainActor
private final class NativeLibraryFixture: NSObject, UICollectionViewDataSource {
    let model = FilterModel(content: FilterContent(sections: [FilterSection(items: FilterWindow(items: (0..<6).map {
        .contentItem(FilterEntity(entityInfo: FilterInfo(uri: URL(string: "spotify:playlist:fixture\($0)")!)))
    }, range: 0..<6))]))
    func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { 6 }
    func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        view.dequeueReusableCell(withReuseIdentifier: "native", for: indexPath)
    }
}
@MainActor
private final class NativeLibraryLayout: UICollectionViewLayout {
    var columns = 1
    override var collectionViewContentSize: CGSize { CGSize(width: 393, height: 600) }
    override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard path.section == 0, path.item < 6 else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
        attributes.frame = CGRect(x: 12 + (path.item % columns) * 190, y: (path.item / columns) * 90, width: columns == 1 ? 369 : 178, height: 80)
        return attributes
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        (0..<6).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }.filter { $0.frame.intersects(rect) }
    }
}

@MainActor
@main
final class UIRegressionApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private func report(_ message: String) {
        print(message); fflush(stdout)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ui-result.txt")
        try? message.write(to: file, atomically: true, encoding: .utf8)
    }
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Self.self)) }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible(); self.window = window
        DispatchQueue.main.async { self.run() }
        return true
    }
    private func run() {
        report("UI RUNNING: header sizing")
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { report("UI FAIL: \(message)"); exit(1) }
            checks += 1
        }
        let oldHeaderSpacer = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        oldHeaderSpacer.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        let button = UIButton(type: .system)
        let header = PWTrackMenuHeader(prior: oldHeaderSpacer, button: button, width: 393)
        for index in 0..<50 {
            _ = header.resize(width: index % 2 == 0 ? 393 : 430)
            check(header.bounds.height == 56, "empty flexible header must not grow")
            check(button.frame.minY == 0, "download row must start at top of empty header")
        }
        let prior = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 200))
        let caption = UILabel(frame: CGRect(x: 16, y: 12, width: 180, height: 20)); caption.text = "Existing content"
        prior.addSubview(caption)
        let secondButton = UIButton(type: .system)
        let populated = PWTrackMenuHeader(prior: prior, button: secondButton, width: 393)
        for _ in 0..<50 {
            _ = populated.resize(width: 393)
            check(populated.bounds.height == 96, "real header content preserved without inflation")
            check(secondButton.frame.minY == 0 && prior.frame.minY == 56, "download first, real header content preserved below")
            prior.frame.size.height = 700 // native sizing must not feed back
        }
        let emptyControl = UIControl(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        let container = UIView(frame: emptyControl.frame); container.addSubview(emptyControl)
        let emptyHeader = PWTrackMenuHeader(prior: container, button: UIButton(type: .system), width: 393)
        check(emptyHeader.bounds.height == 56, "empty controls do not count as header content")
        report("UI RUNNING: inset native menu row alignment")
        let alignmentTable = NativeRowFixtureTable(frame: CGRect(x: 0, y: 0, width: 393, height: 400), style: .plain)
        let sample = alignmentTable.sample; alignmentTable.addSubview(sample)
        sample.frame = CGRect(x: 24, y: 56, width: 345, height: 56)
        sample.contentView.frame = sample.bounds
        let nativeIcon = UIImageView(image: UIImage(systemName: "square.and.arrow.up"))
        nativeIcon.frame = CGRect(x: 8, y: 16, width: 24, height: 24)
        let nativeLabel = UILabel(frame: CGRect(x: 46, y: 14, width: 270, height: 28))
        nativeLabel.text = "Partager"; nativeLabel.font = .systemFont(ofSize: 18)
        sample.contentView.addSubview(nativeIcon); sample.contentView.addSubview(nativeLabel)
        let alignedButton = UIButton(type: .system)
        var alignedConfig = UIButton.Configuration.plain(); alignedConfig.title = "Télécharger ce titre"
        alignedConfig.image = UIImage(systemName: "arrow.down.circle"); alignedButton.configuration = alignedConfig
        alignedButton.contentHorizontalAlignment = .leading
        let alignedHeader = PWTrackMenuHeader(prior: nil, button: alignedButton, width: 393)
        alignmentTable.tableHeaderView = alignedHeader
        _ = alignedHeader.resize(width: 393, table: alignmentTable)
        check(abs((alignedButton.configuration?.contentInsets.leading ?? 0) - 32) < 0.1, "download glyph includes native cell's 24pt inset")
        check(abs((alignedButton.configuration?.imagePadding ?? 0) - 14) < 0.1, "native icon-to-text spacing retained")
        check(alignedHeader.bounds.height == 56, "native row height retained")
        report("UI RUNNING: native header, nested action container and bottom spacer")
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        let nativeHeader = UIView(); nativeHeader.accessibilityIdentifier = "context-menu-header-view"
        let title = UILabel(); title.text = "Track header"
        nativeHeader.addSubview(title)
        let bottom = UIView(); bottom.accessibilityIdentifier = "context-menu-bottom-layout"
        let content = UIView(), spacer = UIView()
        for view in [nativeHeader, bottom, spacer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        title.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false; bottom.addSubview(content)
        let table = UITableView(frame: .zero, style: .plain); table.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(table)
        let spacerHeight = spacer.heightAnchor.constraint(equalToConstant: 0)
        let nativeTop = bottom.topAnchor.constraint(equalTo: nativeHeader.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([nativeHeader.topAnchor.constraint(equalTo: root.topAnchor),
            nativeHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor), nativeHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nativeHeader.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            title.topAnchor.constraint(equalTo: nativeHeader.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: nativeHeader.leadingAnchor, constant: 16), title.trailingAnchor.constraint(equalTo: nativeHeader.trailingAnchor, constant: -16),
            title.heightAnchor.constraint(equalToConstant: 32), title.bottomAnchor.constraint(lessThanOrEqualTo: nativeHeader.bottomAnchor, constant: -16),
            nativeTop, bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: bottom.topAnchor), content.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: bottom.leadingAnchor), content.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            table.topAnchor.constraint(equalTo: content.topAnchor), table.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor), table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            table.heightAnchor.constraint(equalToConstant: 240),
            spacer.topAnchor.constraint(equalTo: bottom.bottomAnchor), spacer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spacer.leadingAnchor.constraint(equalTo: root.leadingAnchor), spacer.trailingAnchor.constraint(equalTo: root.trailingAnchor), spacerHeight])
        table.tableHeaderView = emptyHeader; table.contentInset.top = 300; table.contentOffset.y = -300
        root.layoutIfNeeded()
        check(nativeHeader.bounds.height > 500, "fixture reproduces stretched native header before repair")
        for _ in 0..<50 {
            _ = PWTrackMenuLayout.compact(table: table, in: root); root.layoutIfNeeded()
            check(abs(root.convert(table.bounds, from: table).minY - 72) < 1, "nested table follows compressed native header: header=\(nativeHeader.frame), bottom=\(bottom.frame), spacer=\(spacer.frame)")
            check(table.contentInset.top == 0 && table.contentOffset.y >= 0, "no inner scroll spacer")
            check(nativeTop.isActive && nativeTop.constant == 8, "native title-to-actions anchor preserved")
            check(spacer.bounds.height > 450, "unused sheet space is below the actions")
        }
        check(!PWTrackMenuLayout.compact(table: table, in: root), "stable layout does not continually invalidate itself")
        let foreign = UITableView(); let before = root.constraints.count
        check(!PWTrackMenuLayout.compact(table: foreign, in: root) && root.constraints.count == before, "unrelated tables untouched")
        report("UI RUNNING: actual action row, tall sheet and native selection mapping")
        let actions = UITableView(frame: CGRect(x: 0, y: 0, width: 393, height: 800), style: .plain)
        let fixture = NativeMenuFixture(); actions.dataSource = fixture; actions.delegate = fixture
        actions.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        let download = UIButton(type: .system)
        var config = UIButton.Configuration.plain(); config.title = "Télécharger ce titre"; config.image = UIImage(systemName: "arrow.down.circle"); download.configuration = config
        var downloads = 0
        let adapter = PWTrackMenuRows.install(on: actions, button: download, action: { downloads += 1 })!
        window?.rootViewController?.view.addSubview(actions)
        actions.layoutIfNeeded()
        check(actions.tableHeaderView == nil, "empty stretched header is absent from actual row layout")
        check(actions.numberOfRows(inSection: 0) == 4 && actions.numberOfRows(inSection: 1) == 1, "one injected row, other sections unchanged")
        for height in [400.0, 800.0, 1200.0] {
            actions.frame.size.height = height; actions.layoutIfNeeded(); adapter.align(in: actions)
            let first = actions.rectForRow(at: IndexPath(row: 0, section: 0)), next = actions.rectForRow(at: IndexPath(row: 1, section: 0))
            check(abs(next.minY - first.maxY) < 0.5, "no gap between Download and first native action in tall sheet")
            check(first.height == 56, "download occupies native row height")
            check(abs((download.configuration?.contentInsets.leading ?? 0) - 16) < 0.5, "download icon aligned with native icon")
        }
        adapter.tableView(actions, didSelectRowAt: IndexPath(row: 0, section: 0))
        check(downloads == 1 && fixture.selected == nil, "download does not invoke the first native action")
        adapter.tableView(actions, didSelectRowAt: IndexPath(row: 2, section: 0))
        check(fixture.selected == IndexPath(row: 1, section: 0), "native action index remapped")
        check(adapter.tableView(actions, shouldHighlightRowAt: IndexPath(row: 3, section: 0)) && fixture.highlighted == IndexPath(row: 2, section: 0), "last native row highlight uses its original index")
        fixture.highlighted = nil
        check(adapter.tableView(actions, shouldHighlightRowAt: IndexPath(row: 0, section: 0)) && fixture.highlighted == nil, "download highlight does not address native row zero")
        adapter.tableView(actions, didSelectRowAt: IndexPath(row: 0, section: 1))
        check(fixture.selected == IndexPath(row: 0, section: 1), "second section index unchanged")
        fixture.count = 5; actions.reloadData(); actions.layoutIfNeeded()
        check(actions.numberOfRows(inSection: 0) == 6, "asynchronous native actions retained")
        fixture.count = 0; actions.reloadData(); actions.layoutIfNeeded()
        check(actions.numberOfRows(inSection: 0) == 1 && actions.rectForRow(at: IndexPath(row: 0, section: 0)).height == 58, "empty native action list has a safe standalone download row")
        fixture.count = 3
        actions.delegate = fixture
        _ = PWTrackMenuRows.install(on: actions, button: download, action: { downloads += 1 })
        check(actions.delegate === adapter, "native delegate refresh reinstalls index translation")
        report("UI RUNNING: downloaded indicators")
        let label = UILabel(); label.font = .systemFont(ofSize: 14)
        let original = NSAttributedString(string: "Damso", attributes: [.font: label.font as Any, .foregroundColor: UIColor.gray])
        label.attributedText = original
        for _ in 0..<50 { PWDownloadedIndicator.apply(to: label, downloaded: true) }
        check(label.attributedText?.string == "\u{fffc}\u{2002}Damso", "one indicator before artist")
        PWDownloadedIndicator.apply(to: label, downloaded: false)
        check(label.attributedText?.isEqual(to: original) == true, "removal restores original attributed text")
        PWDownloadedIndicator.apply(to: label, downloaded: true)
        label.attributedText = NSAttributedString(string: "PNL")
        PWDownloadedIndicator.apply(to: label, downloaded: false)
        check(label.text == "PNL", "recycled row without download has no stale badge")
        PWDownloadedIndicator.apply(to: label, downloaded: true)
        check(label.text == "\u{fffc}\u{2002}PNL", "recycled downloaded row gets its own indicator")
        report("UI RUNNING: native Library downloaded filter")
        let librarySource = NativeLibraryFixture(), libraryLayout = NativeLibraryLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 393, height: 800), collectionViewLayout: libraryLayout)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "native")
        collection.dataSource = librarySource; collection.reloadData(); collection.layoutIfNeeded()
        let filter = PWLibraryFilterLayout(); filter.active = true
        filter.eligible = Set(["spotify:playlist:fixture0", "spotify:playlist:fixture2", "spotify:playlist:fixture4"])
        filter.prepare(libraryLayout)
        check(filter.filtering && collection.numberOfItems(inSection: 0) == 6, "native Library counts are unchanged")
        check(filter.attributes.map { $0.indexPath.item } == [0, 2, 4], "filtered cells retain original native index paths")
        check(filter.item(at: IndexPath(item: 1, section: 0)) == nil, "non-downloaded playlist has no visible attributes")
        check(filter.attributes.map { $0.frame.minY } == [8, 98, 188], "list rows reflow without gaps")
        check(filter.size.height == 276, "list content height removes hidden playlists")
        check(filter.elements(in: CGRect(x: 0, y: 0, width: 393, height: 90)).count == 1, "visible rect queries use filtered geometry")
        libraryLayout.columns = 2
        filter.eligible = Set(["spotify:playlist:fixture1", "spotify:playlist:fixture4", "spotify:playlist:fixture5"])
        filter.prepare(libraryLayout)
        check(filter.attributes.map { $0.indexPath.item } == [1, 4, 5], "grid native indices remain intact")
        check(filter.attributes.map { $0.frame.minX } == [12, 202, 12] && filter.attributes.map { $0.frame.minY } == [8, 8, 98], "grid reflows across native columns")
        filter.eligible = []; filter.prepare(libraryLayout)
        check(filter.attributes.isEmpty && filter.size.height == 0, "empty selection shows no unrelated playlists")
        filter.active = false
        check(!filter.filtering, "turning filter off restores native layout")
        report("UI PASS: \(checks) checks"); exit(0)
    }
}
