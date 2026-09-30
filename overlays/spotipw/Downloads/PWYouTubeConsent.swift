import UIKit
import WebKit

// An isolated, temporary web view lets the user make the provider's own choice.
// No automatic acceptance, scripted clicks or Google account sign-in.
@MainActor
final class PWYouTubeConsentController: UIViewController, WKNavigationDelegate {
    private let source: Int
    private let completed: () -> Void
    private var web: WKWebView!
    private var finished = false
    init(source: Int, completed: @escaping () -> Void) {
        self.source = source; self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Cookies YouTube"
        overrideUserInterfaceStyle = .dark
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self; web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        let host = source == 0 ? "music.youtube.com" : "www.youtube.com"
        web.load(URLRequest(url: URL(string: "https://\(host)/")!))
    }
    @objc private func close() { finished = true; dismiss(animated: true) }
    @objc private func reload() { web.reload() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }
        NotificationCenter.default.post(name: Notification.Name("PWDownloadDiagnostic"), object: nil,
                                        userInfo: ["event": "youtube_consent_page_failed", "code": (error as NSError).code])
        notice("La page YouTube n’a pas pu être chargée. Vérifie la connexion puis touche Actualiser.")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Subframes may load Google's published consent resources. All frame
        // navigations stay within the public YouTube/consent pages, never a login.
        if PWYouTubeAccess.publicURL(url) || PWYouTubeAccess.consentURL(url) { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { collect(showMessage: false) }
    @objc private func check() { collect(showMessage: true) }
    private func collect(showMessage: Bool) {
        guard !finished else { return }
        guard let url = web.url, PWYouTubeAccess.publicURL(url) else {
            if showMessage { notice("Fais d’abord ton choix de cookies sur la page Google. Tu peux accepter ou refuser les cookies facultatifs.") }
            return
        }
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self = self, !self.finished else { return }
                guard PWYouTubeAccess.save(cookies) else {
                    if showMessage { self.notice("Le choix de cookies n’a pas encore été confirmé par YouTube. Termine la page Google, puis touche Vérifier.") }
                    return
                }
                self.finished = true
                self.dismiss(animated: true) { self.completed() }
            }
        }
    }
    private func notice(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Cookies YouTube", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
