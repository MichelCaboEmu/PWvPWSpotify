import UIKit
import Darwin

@MainActor
@main
final class UIRegressionApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Self.self)) }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible(); self.window = window
        DispatchQueue.main.async { self.run() }
        return true
    }
    private func run() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { print("UI FAIL: \(message)"); fflush(stdout); exit(1) }
            checks += 1
        }
        let spacer = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        spacer.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        let button = UIButton(type: .system)
        let header = PWTrackMenuHeader(prior: spacer, button: button, width: 393)
        for index in 0..<50 {
            _ = header.resize(width: index % 2 == 0 ? 393 : 430)
            check(header.bounds.height == 56, "empty flexible header must not grow")
            check(button.frame.minY == 0, "download row must start at top of empty header")
        }
        let prior = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 200))
        let caption = UILabel(frame: CGRect(x: 16, y: 12, width: 180, height: 20)); caption.text = "Existing content"
        prior.addSubview(caption)
        let secondButton = UIButton(type: .system)
        let populated = PWTrackMenuHeader(prior: prior, button: secondButton, width: 393)
        for _ in 0..<50 {
            _ = populated.resize(width: 393)
            check(populated.bounds.height == 96, "real header content preserved without inflation")
            check(secondButton.frame.minY == 40, "download follows content with eight-point spacing")
        }
        let label = UILabel(); label.font = .systemFont(ofSize: 14)
        let original = NSAttributedString(string: "Damso", attributes: [.font: label.font as Any, .foregroundColor: UIColor.gray])
        label.attributedText = original
        for _ in 0..<50 { PWDownloadedIndicator.apply(to: label, downloaded: true) }
        check(label.attributedText?.string == "\u{fffc}\u{2002}Damso", "one indicator before artist")
        PWDownloadedIndicator.apply(to: label, downloaded: false)
        check(label.attributedText?.isEqual(to: original) == true, "removal restores original attributed text")
        PWDownloadedIndicator.apply(to: label, downloaded: true)
        label.attributedText = NSAttributedString(string: "PNL")
        PWDownloadedIndicator.apply(to: label, downloaded: false)
        check(label.text == "PNL", "recycled row without download has no stale badge")
        PWDownloadedIndicator.apply(to: label, downloaded: true)
        check(label.text == "\u{fffc}\u{2002}PNL", "recycled downloaded row gets its own indicator")
        print("UI PASS: \(checks) checks"); fflush(stdout); exit(0)
    }
}
