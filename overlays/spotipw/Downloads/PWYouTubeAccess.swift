import Foundation

// Public YouTube endpoints only. Spotify and media sessions retain their own policy.
enum PWYouTubeAccess {
    static let preferenceKey = "spotifyglass.download.youtubePreferences"
    static func secure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    static func publicHost(_ host: String) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host.lowercased())
    }
    static func publicURL(_ url: URL) -> Bool {
        secure(url) && publicHost(url.host ?? "")
    }
    static func consentURL(_ url: URL) -> Bool { secure(url) && url.host?.lowercased() == "consent.youtube.com" }
    static func redirectAllowed(originHost: String?, to url: URL) -> Bool {
        guard secure(url) else { return false }
        guard let host = originHost else { return PWDownloadRules.mediaURL(url) }
        if publicHost(host) { return publicURL(url) }
        return url.host?.lowercased() == host
    }
    static func preference(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        ["SOCS", "CONSENT"].contains(cookie.name) &&
        ["youtube.com", ".youtube.com"].contains(cookie.domain.lowercased()) && cookie.path == "/" &&
        !cookie.value.isEmpty && cookie.value.count <= 1024 && !cookie.value.uppercased().contains("PENDING") &&
        !cookie.value.contains("\r") && !cookie.value.contains("\n") && !cookie.value.contains(";") &&
        (cookie.expiresDate == nil || cookie.expiresDate! > now)
    }
    // Only the user's cookie preference is retained. Login and visitor cookies
    // from the isolated consent web view are never copied into downloader sessions.
    static func save(_ cookies: [HTTPCookie], defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let selected = cookies.filter { preference($0, now: now) }
        guard !selected.isEmpty else { return false }
        defaults.set(selected.map { ["name": $0.name, "value": $0.value,
                                     "expires": ($0.expiresDate ?? now.addingTimeInterval(86400)).timeIntervalSince1970] }, forKey: preferenceKey)
        return true
    }
    static func cookieHeader(for url: URL, defaults: UserDefaults = .standard, now: Date = Date()) -> String? {
        guard publicURL(url), let saved = defaults.array(forKey: preferenceKey) as? [[String: Any]] else { return nil }
        var pairs: [String] = [], seen = Set<String>()
        for value in saved {
            guard let name = value["name"] as? String, let text = value["value"] as? String,
                  let expires = value["expires"] as? Double, expires > now.timeIntervalSince1970,
                  let cookie = HTTPCookie(properties: [.name: name, .value: text, .domain: ".youtube.com", .path: "/"]),
                  preference(cookie, now: now), seen.insert(name).inserted else { continue }
            pairs.append(name + "=" + text)
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
    static func apply(to request: inout URLRequest) {
        guard let url = request.url, publicURL(url) else { return }
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader(for: url), forHTTPHeaderField: "Cookie")
    }
}
struct PWYouTubeConsentRequired: LocalizedError {
    let source: Int
    var errorDescription: String? {
        "YouTube demande ton choix de cookies avant de continuer. Touche « Choisir les cookies YouTube » dans la file, fais ton choix sur la page Google, puis la playlist reprendra. Aucun abonnement ni connexion Google n’est nécessaire pour cette étape."
    }
}
