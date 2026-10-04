import UIKit
import ObjectiveC

// 9.1.78: mainView > headerView, divider, bottomLayout > contentContainer >
// table; then bottomSpacer. Spotify computes preferredContentSize from this
// constraint graph. Moving the table left the stretched header in that graph.
@MainActor
enum PWTrackMenuLayout {
    private static var key: UInt8 = 0
    private final class State: NSObject { var height: NSLayoutConstraint?; weak var header: UIView?; var signature = "" }
    static func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    @discardableResult static func compact(table: UITableView, in root: UIView) -> Bool {
        guard table.tableHeaderView is PWTrackMenuHeader, table.isDescendant(of: root) else { return false }
        var changed = false
        if table.contentInsetAdjustmentBehavior != .never { table.contentInsetAdjustmentBehavior = .never; changed = true }
        if abs(table.contentInset.top) > 0.5 { var inset = table.contentInset; inset.top = 0; table.contentInset = inset; changed = true }
        if table.sectionHeaderTopPadding != 0 { table.sectionHeaderTopPadding = 0; changed = true }
        if !table.isDragging, !table.isDecelerating, table.contentOffset.y < -0.5 {
            table.setContentOffset(CGPoint(x: table.contentOffset.x, y: 0), animated: false); changed = true
        }
        guard let header = find("context-menu-header-view", in: root),
              let bottom = find("context-menu-bottom-layout", in: root),
              table.isDescendant(of: bottom), header.bounds.width > 0 else { return changed }
        // A tall sheet must put unused height AFTER the actions. Identify the
        // native bottom spacer by its actual top/bottom anchors, not by an
        // arbitrary empty view or screen coordinate.
        for spacer in root.subviews where spacer !== header && spacer !== bottom {
            let afterActions = root.constraints.contains { $0.firstItem as? UIView === spacer && $0.firstAttribute == .top && $0.secondItem as? UIView === bottom && $0.secondAttribute == .bottom }
            let atBottom = root.constraints.contains { $0.firstItem as? UIView === spacer && $0.firstAttribute == .bottom && $0.secondItem as? UIView === root && $0.secondAttribute == .bottom }
            guard afterActions, atBottom else { continue }
            for constraint in spacer.constraints where constraint.isActive && constraint.firstItem as? UIView === spacer && constraint.firstAttribute == .height && constraint.secondItem == nil && constraint.relation == .equal && constraint.priority.rawValue > 249 {
                constraint.isActive = false; constraint.priority = UILayoutPriority(249); constraint.isActive = true
                let minimum = spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: max(0, constraint.constant))
                minimum.identifier = "PWTrackMenuBottomMinimum"; minimum.isActive = true
                changed = true
            }
        }
        let state: State
        if let old = objc_getAssociatedObject(table, &key) as? State { state = old }
        else { state = State(); objc_setAssociatedObject(table, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        if state.header !== header { state.height?.isActive = false; state.height = nil; state.header = header; state.signature = "" }
        func content(_ view: UIView) -> String {
            if let label = view as? UILabel { return "\(label.text ?? "")/\(label.font.pointSize)/\(label.numberOfLines)" }
            if let image = view as? UIImageView { return "\(image.image?.size ?? .zero)" }
            return view.subviews.map(content).joined(separator: "|")
        }
        let signature = "\(header.bounds.width)/\(header.traitCollection.preferredContentSizeCategory.rawValue)/\(content(header))"
        if state.signature == signature, state.height?.isActive == true { return changed }
        // Preserve all Spotify constraints. Measure without our own height.
        state.height?.isActive = false
        let measured = header.systemLayoutSizeFitting(CGSize(width: header.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        guard measured.isFinite, measured > 0 else { return changed }
        let height = max(64, ceil(measured))
        if state.height == nil {
            state.height = header.heightAnchor.constraint(equalToConstant: height)
            state.height?.priority = UILayoutPriority(999)
            state.height?.identifier = "PWTrackMenuMeasuredHeader"
            changed = true
        } else if abs((state.height?.constant ?? 0) - height) > 0.5 {
            state.height?.constant = height; changed = true
        }
        state.height?.isActive = true
        state.signature = signature
        if abs(header.bounds.height - height) > 0.5 { changed = true }
        if changed { root.setNeedsLayout() }
        return changed
    }
    static func geometry(table: UITableView, in root: UIView) -> [String: Any] {
        func frame(_ view: UIView?) -> String {
            guard let view = view else { return "absent" }
            return NSCoder.string(for: root.convert(view.bounds, from: view))
        }
        var result: [String: Any] = ["root":NSCoder.string(for: root.bounds), "table":frame(table),
            "content_height":table.contentSize.height, "inset_top":table.adjustedContentInset.top,
            "offset_y":table.contentOffset.y, "table_header":frame(table.tableHeaderView),
            "table_footer":frame(table.tableFooterView), "sections":table.numberOfSections]
        for (key, id) in [("native_header", "context-menu-header-view"), ("bottom_layout", "context-menu-bottom-layout")] {
            let view = find(id, in: root); result[key] = frame(view)
            result[key + "_class"] = view.map { NSStringFromClass(type(of: $0)) } ?? "absent"
        }
        if table.numberOfSections > 0 {
            result["section_0_header"] = NSCoder.string(for: table.rectForHeader(inSection: 0))
            if table.numberOfRows(inSection: 0) > 0 { result["first_row"] = NSCoder.string(for: table.rectForRow(at: IndexPath(row: 0, section: 0))) }
        }
        return result
    }
}
