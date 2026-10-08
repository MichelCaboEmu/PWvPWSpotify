import UIKit

// A table header is not an intrinsic height. In particular, Spotify can give an
// empty header a flexible-height mask. Letting it autoresize inside our wrapper
// feeds the added row back into the next measurement, growing on every pass.
@MainActor
final class PWTrackMenuHeader: UIView {
    private let prior: UIView?, button: UIButton
    private var rowHeight: CGFloat = 56
    private var priorHeight: CGFloat = 0
    private var measuredStyle: String?
    init(prior: UIView?, button: UIButton, width: CGFloat) {
        self.prior = prior; self.button = button
        super.init(frame: .zero)
        autoresizesSubviews = false
        if let prior = prior { addSubview(prior) }
        priorHeight = contentHeight()
        addSubview(button); _ = resize(width: width)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func contentHeight() -> CGFloat {
        guard let prior = prior else { return 0 }
        if NSStringFromClass(type(of: prior)).contains("SGSpeedPitchView") { return prior.bounds.height }
        var bottom: CGFloat = 0
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            let label = (view as? UILabel)?.text?.isEmpty == false
            let picture = (view as? UIImageView)?.image != nil && view.bounds.height <= 160
            if label || picture {
                let rect = prior.convert(view.bounds, from: view)
                if rect.height > 0 { bottom = max(bottom, rect.maxY) }
            } else if !(view is UIVisualEffectView) { view.subviews.forEach(visit) }
        }
        prior.subviews.forEach(visit)
        // Preserve intentional small padding, not a screen-sized empty spacer.
        return bottom > 0 ? ceil(bottom + 8) : (prior.bounds.height <= 24 ? prior.bounds.height : 0)
    }
    private func matchRows(_ table: UITableView) {
        guard let cell = table.visibleCells.first, cell.bounds.height >= 40, cell.bounds.height <= 100 else { return }
        var labels: [UILabel] = [], glyphs: [UIView] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let label = view as? UILabel, !(label.text ?? "").isEmpty { labels.append(label) }
            if view is UIImageView || NSStringFromClass(type(of: view)).contains("SPTEncoreIconView") {
                if view.bounds.width >= 16 && view.bounds.width <= 40 { glyphs.append(view) }
            }
            view.subviews.forEach(visit)
        }
        visit(cell.contentView)
        guard let label = labels.max(by: { ($0.text?.count ?? 0) < ($1.text?.count ?? 0) }) else { return }
        // The header spans the table, but inset/grouped native cells need not.
        // Measure both glyph and text in OUR coordinates, not the cell's local
        // coordinates (which previously discarded its horizontal inset).
        let textX = convert(label.bounds, from: label).minX
        let glyph = glyphs.filter { convert($0.bounds, from: $0).maxX <= textX }.min { convert($0.bounds, from: $0).minX < convert($1.bounds, from: $1).minX }
        let iconX = glyph.map { convert($0.bounds, from: $0).minX } ?? 16
        let iconWidth = glyph?.bounds.width ?? 24
        guard textX > iconX + iconWidth, textX < 100 else { return }
        rowHeight = cell.bounds.height
        let key = "\(textX)/\(iconX)/\(iconWidth)/\(label.font.fontName)/\(label.font.pointSize)"
        guard key != measuredStyle else { return }; measuredStyle = key
        var config = button.configuration ?? .plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: iconX, bottom: 0, trailing: 16)
        if let image = config.image, image.size.width != iconWidth {
            config.image = UIGraphicsImageRenderer(size: CGSize(width: iconWidth, height: iconWidth)).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: iconWidth, height: iconWidth))
            }.withRenderingMode(image.renderingMode)
        }
        config.imagePadding = textX - iconX - iconWidth
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming; out.font = label.font; return out
        }
        button.configuration = config
    }
    @discardableResult func resize(width: CGFloat, table: UITableView? = nil) -> Bool {
        if let table = table { matchRows(table) }
        // Ignore incidental stretching after insertion. Only Speed/pitch has
        // an intentionally variable height, updated by its own toggle action.
        if let prior = prior, NSStringFromClass(type(of: prior)).contains("SGSpeedPitchView") { priorHeight = prior.bounds.height }
        let height = priorHeight
        let nextFrame = CGRect(x: 0, y: 0, width: width, height: height + rowHeight)
        let changed = frame != nextFrame
        // No autoresizing occurs here: the prior height cannot include this row.
        frame = nextFrame
        button.frame = CGRect(x: 0, y: 0, width: width, height: rowHeight)
        prior?.frame = CGRect(x: 0, y: rowHeight, width: width, height: height)
        return changed
    }
}
