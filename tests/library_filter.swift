import Foundation
private struct Info { var uri: URL }
private struct Entity { var entityInfo: Info }
private enum Item { case contentItem(Entity), banner, alsoAvailableOfflineItem(Entity) }
private struct Window { var size: Int; var items: [Item]; var range: Range<Int> }
private enum HeaderType { case contentControls, none }
private struct Header { var type: HeaderType }
private struct Section { var items: Window; var header: Header }
private struct Content { var sections: [Section] }
private struct Model { var content: Content }
private struct Binder { var model: Model }
@main struct Tests {
    static func main() {
        let a = "spotify:playlist:aaaaaaaaaaaaaaaaaaaaaa", b = "spotify:collection:tracks"
        func item(_ uri: String) -> Item { .contentItem(Entity(entityInfo: Info(uri: URL(string: uri)!))) }
        let binder = Binder(model: Model(content: Content(sections: [
            Section(items: Window(size: 0, items: [], range: 0..<0), header: Header(type: .contentControls)),
            Section(items: Window(size: 15, items: [item(a), .banner, item("spotify:album:bbbbbbbbbbbbbbbbbbbbbb"), item(b)], range: 7..<11), header: Header(type: .none))])))
        let sections = PWLibraryFilterRules.sections(binder)!
        precondition(sections.count == 2 && sections[0].controls)
        precondition(sections[1].uris == [7:a, 10:b])
        precondition(PWLibraryFilterRules.key("spotify:user:alice:playlist:aaaaaaaaaaaaaaaaaaaaaa") == a)
        precondition(PWLibraryFilterRules.key("spotify:local-files") == nil)
        precondition(PWLibraryFilterRules.sections("unknown") == nil)
        precondition(!PWPlaybackConnectivity.useLocal(pathUnavailable: false, networkAllowed: true))
        precondition(PWPlaybackConnectivity.useLocal(pathUnavailable: true, networkAllowed: true))
        precondition(PWPlaybackConnectivity.useLocal(pathUnavailable: false, networkAllowed: false))
        precondition(!PWPlaybackConnectivity.displayFailure(playlistRequest: true, offline: false, cancelled: false))
        precondition(!PWPlaybackConnectivity.displayFailure(playlistRequest: true, offline: true, cancelled: true))
        precondition(PWPlaybackConnectivity.displayFailure(playlistRequest: true, offline: true, cancelled: false))
        print("PASS: native library window identity and online/offline routing")
    }
}
