import Foundation

// Public YouTube endpoints only. Spotify and media sessions retain their own policy.
enum PWYouTubeAccess {
    static let preferenceKey = "spotifyglass.download.youtubePreferences"
    // Use the same browser identity for the public API configuration and its
    // consent window. The native extractor keeps its own client identities.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    static func homepage(source: Int) -> URL {
        URL(string: source == 0 ? "https://music.youtube.com/" : "https://www.youtube.com/")!
    }
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
    static func consentState(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        ["SOCS", "CONSENT"].contains(cookie.name) &&
        ["youtube.com", ".youtube.com"].contains(cookie.domain.lowercased()) && cookie.path == "/" &&
        !cookie.value.isEmpty && cookie.value.count <= 1024 &&
        !cookie.value.contains("\r") && !cookie.value.contains("\n") && !cookie.value.contains(";") &&
        (cookie.expiresDate == nil || cookie.expiresDate! > now)
    }
    static func consentState(headers: [String: String], from url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard publicURL(url) else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).filter { consentState($0, now: now) }
    }
    static func preference(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        consentState(cookie, now: now) && !cookie.value.uppercased().contains("PENDING")
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
    let target: URL
    let cookies: [HTTPCookie]
    init(source: Int, target: URL, cookies: [HTTPCookie] = []) {
        self.source = source; self.target = target; self.cookies = cookies
    }
    var errorDescription: String? {
        "YouTube a redirigé le téléchargement vers le consentement. Touche « Vérifier l’accès YouTube » dans la file. Accepte ou refuse les cookies facultatifs si la page le propose ; si YouTube s’affiche directement, touche Vérifier. La file reprendra uniquement après vérification de l’accès du téléchargement."
    }
}
