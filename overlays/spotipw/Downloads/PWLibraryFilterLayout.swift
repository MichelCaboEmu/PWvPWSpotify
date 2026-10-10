import UIKit

// Filter layout attributes only. Counts, index paths, data source, cell creation,
// menus, navigation, native pagination and batch updates remain Spotify-owned.
@MainActor
final class PWLibraryFilterLayout {
    var active = false
    var building = false
    var eligible = Set<String>()
    private(set) var attributes: [UICollectionViewLayoutAttributes] = []
    private(set) var size = CGSize.zero
    private var items: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var ready = false
    var report: ((Int, Int, Bool) -> Void)?
    func prepare(_ layout: UICollectionViewLayout) {
        guard active, !building, let collection = layout.collectionView, let source = collection.dataSource else { return }
        building = true; defer { building = false }
        guard let sections = PWLibraryFilterRules.sections(source), sections.count == collection.numberOfSections else {
            ready = false; report?(0, 0, false); return
        }
        attributes = []; items = [:]; var y: CGFloat = 0; var found = 0; var examined = 0
        let originalSize = layout.collectionViewContentSize
        for (section, model) in sections.enumerated() {
            let count = collection.numberOfItems(inSection: section)
            guard count <= 10000, examined + count <= 10000 else { ready = false; report?(0, examined, false); return }
            examined += count
            let native = (0..<count).compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: section)) }
            let selected = native.filter { model.uris[$0.indexPath.item].map { eligible.contains($0) } == true }
            guard !selected.isEmpty || model.controls else { continue }
            if let header = layout.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)), header.frame.height > 0,
               let copy = header.copy() as? UICollectionViewLayoutAttributes {
                copy.frame.origin.y = y; attributes.append(copy); y = copy.frame.maxY
            }
            guard let first = native.first else { continue }
            let firstRow = native.filter { abs($0.frame.minY - first.frame.minY) < 1 }.sorted { $0.frame.minX < $1.frame.minX }
            let columns = max(1, firstRow.count)
            let gap: CGFloat
            if let flow = layout as? UICollectionViewFlowLayout { gap = flow.minimumLineSpacing }
            else {
                let nextY = native.first(where: { $0.frame.minY > first.frame.minY + 1 })?.frame.minY
                gap = min(24, max(0, (nextY ?? first.frame.maxY) - (firstRow.map { $0.frame.maxY }.max() ?? first.frame.maxY)))
            }
            if !selected.isEmpty { y += 8 }
            var rowBottom = y
            for (position, original) in selected.enumerated() {
                if position > 0 && position % columns == 0 { y = rowBottom + gap }
                guard let copy = original.copy() as? UICollectionViewLayoutAttributes else { continue }
                copy.frame.origin = CGPoint(x: firstRow[position % columns].frame.minX, y: y)
                copy.alpha = 1; copy.isHidden = false
                attributes.append(copy); items[copy.indexPath] = copy; rowBottom = max(rowBottom, copy.frame.maxY); found += 1
            }
            if !selected.isEmpty { y = rowBottom + 8 }
        }
        size = CGSize(width: originalSize.width, height: y)
        ready = true; report?(found, examined, true)
    }
    var filtering: Bool { active && !building && ready }
    func elements(in rect: CGRect) -> [UICollectionViewLayoutAttributes] { attributes.filter { $0.frame.intersects(rect) } }
    func item(at path: IndexPath) -> UICollectionViewLayoutAttributes? { items[path] }
}
