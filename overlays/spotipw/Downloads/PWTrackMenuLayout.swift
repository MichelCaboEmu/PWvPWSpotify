import UIKit
import ObjectiveC

// Only used in a Spotify track context menu containing our download header.
// Its outer constraints and UIScrollView insets can create a gap independently
// of the height of tableHeaderView; fixing the header alone cannot remove it.
@MainActor
enum PWTrackMenuLayout {
    private static var key: UInt8 = 0
    private final class State: NSObject { var top: NSLayoutConstraint?; weak var region: UIView? }
    @discardableResult static func compact(table: UITableView, in root: UIView) -> Bool {
        guard table.tableHeaderView is PWTrackMenuHeader, table.isDescendant(of: root), table !== root else { return false }
        let state: State
        if let old = objc_getAssociatedObject(table, &key) as? State { state = old }
        else { state = State(); objc_setAssociatedObject(table, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        var changed = false
        let oldTop = table.adjustedContentInset.top
        if table.contentInsetAdjustmentBehavior != .never { table.contentInsetAdjustmentBehavior = .never; changed = true }
        if abs(table.contentInset.top) > 0.5 { var inset = table.contentInset; inset.top = 0; table.contentInset = inset; changed = true }
        if table.sectionHeaderTopPadding != 0 { table.sectionHeaderTopPadding = 0; changed = true }
        if !table.isDragging, !table.isDecelerating, table.contentOffset.y < 0, oldTop > 0 {
            table.setContentOffset(CGPoint(x: table.contentOffset.x, y: 0), animated: false); changed = true
        }
        // Find the direct content region under the real title/artwork header.
        // Do not guess private fields or alter native data-source/index paths.
        var region: UIView = table
        while let parent = region.superview, parent !== root { region = parent }
        var edge: CGFloat = 0
        func visit(_ view: UIView) {
            guard view !== region, !view.isHidden, view.alpha > 0.01 else { return }
            let hasText = (view as? UILabel)?.text?.isEmpty == false
            let hasArt = (view as? UIImageView)?.image != nil && view.bounds.height <= 180
            if hasText || hasArt {
                let rect = root.convert(view.bounds, from: view)
                if rect.minY >= 0, rect.maxY < root.bounds.height / 2 { edge = max(edge, rect.maxY) }
            } else { view.subviews.forEach(visit) }
        }
        root.subviews.forEach(visit)
        guard edge > 0, region.superview === root else { return changed }
        if state.region !== region { state.top?.isActive = false; state.top = nil; state.region = region }
        // Replace the native top positioning only. Width, scrolling, row layout,
        // bottom and native content height remain managed by Spotify.
        for constraint in root.constraints where constraint !== state.top && constraint.isActive {
            let first = constraint.firstItem as? UIView, second = constraint.secondItem as? UIView
            if (first === region && [.top, .centerY].contains(constraint.firstAttribute)) ||
               (second === region && [.top, .centerY].contains(constraint.secondAttribute)) {
                constraint.isActive = false; changed = true
            }
        }
        if state.top == nil {
            region.translatesAutoresizingMaskIntoConstraints = false
            state.top = region.topAnchor.constraint(equalTo: root.topAnchor, constant: edge + 8)
            state.top?.identifier = "PWTrackMenuContentTop"
            state.top?.isActive = true; changed = true
        } else if abs((state.top?.constant ?? 0) - edge - 8) > 0.5 {
            state.top?.constant = edge + 8; changed = true
        }
        // The hook runs after Spotify's layout pass. Explicitly invalidate the
        // containing view: replacing a constraint alone can leave its old frame
        // visible until an unrelated later layout (also reproducible in UIKit).
        // Do not call layoutIfNeeded here, which would re-enter the native hook.
        if changed { root.setNeedsLayout() }
        return changed
    }
}
