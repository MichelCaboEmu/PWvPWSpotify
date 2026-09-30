import UIKit
import WebKit

// An isolated, temporary web view lets the user make the provider's own choice.
// No automatic acceptance, scripted clicks or Google account sign-in.
@MainActor
final class PWYouTubeConsentController: UIViewController, WKNavigationDelegate {
    private let request: PWYouTubeConsentRequired
    private let completed: () -> Void
    private var web: WKWebView!
    private let instructions = UILabel()
    private var finished = false
    private var checking = false
    private var verification: Task<Void, Never>?
    init(request: PWYouTubeConsentRequired, completed: @escaping () -> Void) {
        self.request = request; self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Accès YouTube"
        overrideUserInterfaceStyle = .dark; view.backgroundColor = .systemBackground
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = PWYouTubeAccess.userAgent
        web.navigationDelegate = self; web.translatesAutoresizingMaskIntoConstraints = false
        instructions.translatesAutoresizingMaskIntoConstraints = false
        instructions.numberOfLines = 0
        instructions.font = .preferredFont(forTextStyle: .footnote)
        instructions.adjustsFontForContentSizeCategory = true
        instructions.textColor = .secondaryLabel
        instructions.text = "Accepte ou refuse les cookies facultatifs sur la page Google. Si YouTube s’affiche directement, touche Vérifier."
        view.addSubview(instructions); view.addSubview(web)
        NSLayoutConstraint.activate([
            instructions.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            instructions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            instructions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            web.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 8),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        navigationController?.isModalInPresentation = true
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Vérifier", style: .plain, target: self, action: #selector(check)),
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reload))
        ]
        // Retain the provider's complete redirect, including its return destination.
        // Opening a fresh homepage can show a different flow with no cookie choices.
        let target = PWYouTubeAccess.consentURL(request.target) ? request.target : PWYouTubeAccess.homepage(source: request.source)
        web.load(URLRequest(url: target))
    }
    @objc private func close() { finished = true; verification?.cancel(); dismiss(animated: true) }
    @objc private func reload() { web.reload() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }
        event("youtube_consent_page_failed", (error as NSError).code)
        notice("La page YouTube n’a pas pu être chargée. Vérifie la connexion puis touche Actualiser.")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if PWYouTubeAccess.publicURL(url) || PWYouTubeAccess.consentURL(url) { decisionHandler(.allow) }
        else { event("youtube_consent_navigation_refused"); decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { collect(showMessage: false) }
    @objc private func check() { collect(showMessage: true) }
    private func collect(showMessage: Bool) {
        guard !finished, !checking else { return }
        guard let url = web.url, PWYouTubeAccess.publicURL(url) else {
            if showMessage { notice("Fais d’abord ton choix sur la page Google. Tu peux accepter ou refuser les cookies facultatifs.") }
            return
        }
        checking = true
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self = self, !self.finished else { return }
                let saved = PWYouTubeAccess.save(cookies)
                self.event(saved ? "youtube_consent_preferences_saved" : "youtube_consent_preferences_absent")
                self.verification = Task { [weak self] in
                    await self?.validate(showMessage: showMessage)
                }
            }
        }
    }
    private func validate(showMessage: Bool) async {
        defer { checking = false; verification = nil }
        instructions.text = "Vérification de l’accès utilisé par le téléchargement…"
        let pageURL = PWYouTubeAccess.homepage(source: request.source)
        let client = PWDownloadHTTP(host: pageURL.host)
        defer { client.session.finishTasksAndInvalidate() }
        do {
            // Seeing a homepage or finding a cookie is not proof that the actual
            // downloader has access. Check its session, headers and config parser.
            let bytes = try await client.data(URLRequest(url: pageURL),
                stage: request.source == 0 ? .youtubeMusicConfig : .youtubeConfig, maximum: 4 * 1024 * 1024)
            try Task.checkCancellation()
            guard !finished else { return }
            guard let html = String(data: bytes, encoding: .utf8),
                  PWYouTubeSearchConfig.parse(html, music: request.source == 0) != nil else {
                event("youtube_access_config_missing")
                instructions.text = "YouTube ne fournit pas la configuration du téléchargement. Touche Vérifier pour réessayer."
                if showMessage { notice("La page s’affiche, mais la configuration nécessaire au téléchargement est indisponible. Actualise la page, puis touche Vérifier. Exporte les logs si cela persiste.") }
                return
            }
            event("youtube_access_verified", 200)
            finished = true
            dismiss(animated: true) { self.completed() }
        } catch {
            guard !finished, !Task.isCancelled else { return }
            if let consent = error as? PWYouTubeConsentRequired {
                event("youtube_access_still_requires_consent", 302)
                instructions.text = "Le téléchargement demande encore un choix de cookies. Touche Vérifier pour rouvrir la page Google reçue."
                // A manual retry opens the actual new redirect; no automatic loop.
                if showMessage {
                    web.load(URLRequest(url: consent.target))
                    notice("L’accès du téléchargement demande encore un choix. La page Google reçue vient d’être rouverte. Accepte ou refuse les cookies facultatifs, puis touche Vérifier.")
                }
            } else {
                event("youtube_access_verification_failed", (error as NSError).code)
                instructions.text = "La vérification a échoué. Touche Vérifier pour afficher l’erreur complète et réessayer."
                if showMessage { notice(error.localizedDescription) }
            }
        }
    }
    private func event(_ name: String, _ code: Int = 0) {
        NotificationCenter.default.post(name: Notification.Name("PWDownloadDiagnostic"), object: nil,
                                        userInfo: ["event": name, "code": code])
    }
    private func notice(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Accès YouTube", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
