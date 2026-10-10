import Foundation

enum PWPlaybackConnectivity {
    static func useLocal(pathUnavailable: Bool, networkAllowed: Bool) -> Bool { pathUnavailable || !networkAllowed }
    static func displayFailure(playlistRequest: Bool, offline: Bool, cancelled: Bool) -> Bool {
        !cancelled && (!playlistRequest || offline)
    }
}
