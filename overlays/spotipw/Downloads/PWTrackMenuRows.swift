import UIKit
import ObjectiveC

// A real action row, not a table header. UIKit allocates exactly one row height
// and the next native action starts immediately after it, even in a tall sheet.
@MainActor
final class PWTrackMenuRows: NSObject, UITableViewDataSource, UITableViewDelegate {
    private static var key: UInt8 = 0
    weak var source: UITableViewDataSource?
    weak var delegate: UITableViewDelegate?
    let button: UIButton
    var action: () -> Void
    private weak var table: UITableView?
    init(table: UITableView, source: UITableViewDataSource, delegate: UITableViewDelegate?, button: UIButton, action: @escaping () -> Void) {
        self.table = table; self.source = source; self.delegate = delegate; self.button = button; self.action = action
        super.init()
    }
    static func installed(on table: UITableView) -> PWTrackMenuRows? { objc_getAssociatedObject(table, &key) as? PWTrackMenuRows }
    @discardableResult static func install(on table: UITableView, button: UIButton, action: @escaping () -> Void) -> PWTrackMenuRows? {
        if let old = installed(on: table), table.dataSource === old {
            if table.delegate !== old { old.delegate = table.delegate; table.delegate = old }
            old.action = action; return old
        }
        guard let source = table.dataSource else { return nil }
        let prior = installed(on: table)
        let nativeDelegate = table.delegate === prior ? prior?.delegate : table.delegate
        let adapter = PWTrackMenuRows(table: table, source: source, delegate: nativeDelegate, button: button, action: action)
        objc_setAssociatedObject(table, &key, adapter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        table.dataSource = adapter; table.delegate = adapter
        // Only discard a genuinely empty leading spacer. Speed/pitch or any
        // native controls retain their original table header and constraints.
        if let header = table.tableHeaderView, !meaningful(header) { table.tableHeaderView = nil }
        table.reloadData(); return adapter
    }
    private static func meaningful(_ view: UIView) -> Bool {
        if let label = view as? UILabel, !(label.text ?? "").isEmpty { return true }
        if let image = view as? UIImageView, image.image != nil { return true }
        if view is UIButton || view is UISlider || view is UISwitch { return true }
        return view.subviews.contains(where: meaningful)
    }
    private func original(_ path: IndexPath) -> IndexPath? {
        if path.section != 0 { return path }
        return path.row == 0 ? nil : IndexPath(row: path.row - 1, section: 0)
    }
    func numberOfSections(in tableView: UITableView) -> Int { max(1, source?.numberOfSections?(in: tableView) ?? 1) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let sections = source?.numberOfSections?(in: tableView) ?? 1
        let count = section < sections ? (source?.tableView(tableView, numberOfRowsInSection: section) ?? 0) : 0
        return count + (section == 0 ? 1 : 0)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let path = original(indexPath) { return source?.tableView(tableView, cellForRowAt: path) ?? UITableViewCell() }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear; cell.contentView.backgroundColor = .clear
        button.removeFromSuperview(); cell.contentView.addSubview(button)
        button.frame = cell.contentView.bounds; button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.accessibilityIdentifier = "PW.DownloadTrack.ActionRow"
        return cell
    }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if let path = original(indexPath) { return delegate?.tableView?(tableView, heightForRowAt: path) ?? tableView.rowHeight }
        let native = IndexPath(row: 0, section: 0)
        guard (source?.numberOfSections?(in: tableView) ?? 1) > 0,
              (source?.tableView(tableView, numberOfRowsInSection: 0) ?? 0) > 0 else { return 58 }
        let height = delegate?.tableView?(tableView, heightForRowAt: native) ?? tableView.rowHeight
        return height > 0 && height.isFinite ? height : 58
    }
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let path = original(indexPath) else { return self.tableView(tableView, heightForRowAt: indexPath) }
        return delegate?.tableView?(tableView, estimatedHeightForRowAt: path) ?? tableView.estimatedRowHeight
    }
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let path = original(indexPath) else { return indexPath }
        if delegate?.responds(to: #selector(UITableViewDelegate.tableView(_:willSelectRowAt:))) != true { return indexPath }
        guard let selected = delegate?.tableView?(tableView, willSelectRowAt: path) else { return nil }
        return selected.section == 0 ? IndexPath(row: selected.row + 1, section: 0) : selected
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let path = original(indexPath) else { tableView.deselectRow(at: indexPath, animated: false); action(); return }
        delegate?.tableView?(tableView, didSelectRowAt: path)
    }
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let path = original(indexPath) { delegate?.tableView?(tableView, willDisplay: cell, forRowAt: path) }
        align(in: tableView)
    }
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let path = original(indexPath) { delegate?.tableView?(tableView, didEndDisplaying: cell, forRowAt: path) }
    }
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard let path = original(indexPath) else { return false }
        return source?.tableView?(tableView, canEditRowAt: path) ?? false
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { false }
    private func hasSection(_ table: UITableView, _ section: Int) -> Bool { section < (source?.numberOfSections?(in: table) ?? 1) }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { hasSection(tableView, section) ? source?.tableView?(tableView, titleForHeaderInSection: section) : nil }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { hasSection(tableView, section) ? source?.tableView?(tableView, titleForFooterInSection: section) : nil }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { hasSection(tableView, section) ? (delegate?.tableView?(tableView, heightForHeaderInSection: section) ?? tableView.sectionHeaderHeight) : .leastNormalMagnitude }
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { hasSection(tableView, section) ? (delegate?.tableView?(tableView, heightForFooterInSection: section) ?? tableView.sectionFooterHeight) : .leastNormalMagnitude }
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { hasSection(tableView, section) ? delegate?.tableView?(tableView, viewForHeaderInSection: section) : nil }
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { hasSection(tableView, section) ? delegate?.tableView?(tableView, viewForFooterInSection: section) : nil }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = original(indexPath) else { return nil }
        return delegate?.tableView?(tableView, contextMenuConfigurationForRowAt: path, point: point)
    }
    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        if let path = original(indexPath) { delegate?.tableView?(tableView, accessoryButtonTappedForRowWith: path) }
    }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || source?.responds(to: selector) == true || delegate?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if delegate?.responds(to: selector) == true { return delegate }
        if source?.responds(to: selector) == true { return source }
        return super.forwardingTarget(for: selector)
    }
    func align(in table: UITableView) {
        guard let mine = table.cellForRow(at: IndexPath(row: 0, section: 0)),
              let native = table.cellForRow(at: IndexPath(row: 1, section: 0)) else { return }
        func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }
        let views = all(native.contentView)
        guard let label = views.compactMap({ $0 as? UILabel }).filter({ !($0.text ?? "").isEmpty }).max(by: { ($0.text?.count ?? 0) < ($1.text?.count ?? 0) }) else { return }
        let text = mine.contentView.convert(label.bounds, from: label)
        let glyphs = views.filter { ($0 is UIImageView || NSStringFromClass(type(of: $0)).contains("SPTEncoreIconView")) && $0.bounds.width >= 16 && $0.bounds.width <= 40 }
        guard let glyph = glyphs.first(where: { mine.contentView.convert($0.bounds, from: $0).maxX <= text.minX }) else { return }
        let icon = mine.contentView.convert(glyph.bounds, from: glyph)
        guard icon.minX >= 0, text.minX > icon.maxX, var config = button.configuration else { return }
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: icon.minX, bottom: 0, trailing: 16)
        if let image = config.image, abs(image.size.width - icon.width) > 0.1 {
            config.image = UIGraphicsImageRenderer(size: CGSize(width: icon.width, height: icon.width)).image { _ in image.draw(in: CGRect(x: 0, y: 0, width: icon.width, height: icon.width)) }.withRenderingMode(image.renderingMode)
        }
        config.imagePadding = text.minX - icon.maxX
        let font = label.font
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in var outgoing = incoming; outgoing.font = font; return outgoing }
        button.configuration = config
    }
}
