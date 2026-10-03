import UIKit
import Darwin

@MainActor
@main
final class UIRegressionApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private func report(_ message: String) {
        print(message); fflush(stdout)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ui-result.txt")
        try? message.write(to: file, atomically: true, encoding: .utf8)
    }
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Self.self)) }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible(); self.window = window
        DispatchQueue.main.async { self.run() }
        return true
    }
    private func run() {
        report("UI RUNNING: header sizing")
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { report("UI FAIL: \(message)"); exit(1) }
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
        let emptyControl = UIControl(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        let container = UIView(frame: emptyControl.frame); container.addSubview(emptyControl)
        let emptyHeader = PWTrackMenuHeader(prior: container, button: UIButton(type: .system), width: 393)
        check(emptyHeader.bounds.height == 56, "empty controls do not count as header content")
        report("UI RUNNING: outer menu constraints and scroll insets")
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        let title = UILabel(frame: CGRect(x: 16, y: 20, width: 280, height: 30)); title.text = "Track header"
        root.addSubview(title)
        let table = UITableView(frame: .zero, style: .plain); table.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(table)
        let oldTop = table.topAnchor.constraint(equalTo: root.topAnchor, constant: 500)
        NSLayoutConstraint.activate([oldTop, table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor), table.heightAnchor.constraint(equalToConstant: 240)])
        table.tableHeaderView = emptyHeader; table.contentInset.top = 300; table.contentOffset.y = -300
        root.layoutIfNeeded()
        for _ in 0..<50 {
            _ = PWTrackMenuLayout.compact(table: table, in: root); root.layoutIfNeeded()
            check(abs(table.frame.minY - 58) < 1, "table follows native title, without outer gap: table=\(table.frame), root=\(root.frame), title=\(title.frame), constraints=\(root.constraints)")
            check(table.contentInset.top == 0 && table.contentOffset.y >= 0, "no inner scroll spacer")
            check(!oldTop.isActive, "obsolete native top constraint cannot restore the gap")
        }
        report("UI RUNNING: downloaded indicators")
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
        report("UI PASS: \(checks) checks"); exit(0)
    }
}
