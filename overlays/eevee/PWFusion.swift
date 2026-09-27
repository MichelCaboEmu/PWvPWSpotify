// PWvPWSpotify integration. GPL-3.0; EeveeSpotify implementations stay upstream.
import Foundation
import UIKit
import SwiftUI
import Orion
import ObjectiveC.runtime

// Only complementary hooks start in this build. spoti.pw owns account responses,
// ad filtering, crossfade, player styling, lyrics interception and settings entry.
func pwFusionStart() {
    PasteboardConcreteSwizzler.install()
    TrueShuffleHook.install()
    activateCarPlayCrashFix()
    if UserDefaults.standard.bool(forKey: "spotifyglass.eevee.sessionProtection") {
        activateSessionLogoutProtection(minimal: true)
    }
    if UserDefaults.experimentsOptions.showInstagramDestination {
        InstgramDestinationGroup().activate()
    }
    activateSponsorBlock()
    NSLog("[PWvPWSpotify] Complementary Eevee profile initialized")
}

@objc(PWEeveeBridge)
final class PWEeveeBridge: NSObject {
    @objc(presentExtrasFrom:)
    static func presentExtras(from presenter: UIViewController) {
        let controller = UIHostingController(rootView:
            NavigationView { PWExtrasView() }.navigationViewStyle(.stack))
        controller.overrideUserInterfaceStyle = .dark
        presenter.present(controller, animated: true)
    }

    // The caller owns the single lyrics hook and display. These repositories are
    // data sources only; Eevee's separate lyrics hooks and karaoke UI never start.
    @objc(fetchLyrics:query:completion:)
    static func fetchLyrics(_ provider: String, query: NSDictionary,
                            completion: @escaping (NSDictionary?) -> Void) {
        guard let title = query["title"] as? String, !title.isEmpty,
              let artist = query["artist"] as? String, !artist.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let search = LyricsSearchQuery(title: title, primaryArtist: artist,
                                       spotifyTrackId: query["trackID"] as? String ?? "")
        var options = UserDefaults.lyricsOptions
        options.romanization = UserDefaults.standard.bool(forKey: "spotifyglass.eevee.romanization")
        DispatchQueue.global(qos: .utility).async {
            do {
                let result: LyricsDto
                switch provider {
                case "genius": result = try GeniusLyricsRepository.shared.getLyrics(search, options: options)
                case "petitlyrics": result = try PetitLyricsRepository().getLyrics(search, options: options)
                default:
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let lines = result.timeSynced
                    ? result.lines.sorted { ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0) }
                    : result.lines
                let texts = lines.map { line -> String in
                    if options.romanization && result.romanization == .canBeRomanized {
                        return line.content.applyingTransform(.toLatin, reverse: false) ?? line.content
                    }
                    return line.content
                }
                let answer: NSDictionary = [
                    "texts": texts, "starts": lines.map { $0.offsetMs ?? 0 },
                    "synced": result.timeSynced
                ]
                DispatchQueue.main.async { completion(answer) }
            } catch {
                // No URL, account token, response body or user content in logs.
                NSLog("[PWvPWSpotify] Lyrics source unavailable: %@", provider)
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}

private struct PWExtrasView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cleanLinks = UserDefaults.cleanShareLinks
    @State private var trueShuffle = UserDefaults.trueShuffleEnabled
    @State private var experiments = UserDefaults.experimentsOptions
    @AppStorage("spotifyglass.eevee.sessionProtection") private var sessionProtection = false
    @AppStorage("spotifyglass.eevee.romanization") private var romanization = false
    @State private var musixmatchToken = UserDefaults.standard.string(forKey: "spotifyglass.musixmatch.token") ?? ""

    var body: some View {
        List {
            Section {
                NavigationLink("SponsorBlock", destination: SponsorBlockSettingsView())
                NavigationLink("Icône de l’application", destination: EeveeAppIconPickerView())
            }
            Section(header: Text("Partage")) {
                Toggle("Nettoyer les liens partagés", isOn: $cleanLinks)
                    .onChange(of: cleanLinks) { UserDefaults.cleanShareLinks = $0 }
                Toggle("Partage LiveContainer", isOn: $experiments.liveContainerSharing)
                Toggle("Destination Instagram", isOn: $experiments.showInstagramDestination)
            }
            Section(footer: Text("Le mélange exclut les recommandations de Smart Shuffle. Redémarre Spotify après une modification.")) {
                Toggle("Mélange limité à la playlist", isOn: $trueShuffle)
                    .onChange(of: trueShuffle) { UserDefaults.trueShuffleEnabled = $0 }
            }
            Section(header: Text("Paroles"), footer: Text("Choisis et ordonne Genius et PetitLyrics dans Lecteur → Paroles → Sources. Le jeton Musixmatch facultatif est conservé uniquement sur cet appareil. Redémarre après un changement.")) {
                Toggle("Romaniser Genius et PetitLyrics", isOn: $romanization)
                SecureField("Jeton Musixmatch facultatif", text: $musixmatchToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Enregistrer le jeton") {
                    let token = musixmatchToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    if token.isEmpty { UserDefaults.standard.removeObject(forKey: "spotifyglass.musixmatch.token") }
                    else { UserDefaults.standard.set(token, forKey: "spotifyglass.musixmatch.token") }
                }
            }
            Section(header: Text("Avancé"), footer: Text("Protection expérimentale d’Eevee contre certaines déconnexions. Peut perturber des requêtes de session. Désactivée par défaut ; redémarrage nécessaire.")) {
                Toggle("Protection de session", isOn: $sessionProtection)
            }
            Section(footer: Text("L’interface, les paroles, les publicités et le fondu restent configurés dans les réglages principaux. Le correctif CarPlay d’Eevee est actif lorsque ses méthodes existent ; il n’ajoute pas les autorisations CarPlay.")) {
                Text("spoti.pw 0.21.1 + EeveeSpotify Reincarnated")
                    .font(.footnote)
            }
        }
        .navigationTitle("Compléments Eevee")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Terminé") { dismiss() } } }
        .onChange(of: experiments) { UserDefaults.experimentsOptions = $0 }
    }
}
