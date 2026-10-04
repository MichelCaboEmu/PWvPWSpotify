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
        let oldHeaderSpacer = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        oldHeaderSpacer.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        let button = UIButton(type: .system)
        let header = PWTrackMenuHeader(prior: oldHeaderSpacer, button: button, width: 393)
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
            check(secondButton.frame.minY == 0 && prior.frame.minY == 56, "download first, real header content preserved below")
            prior.frame.size.height = 700 // native sizing must not feed back
        }
        let emptyControl = UIControl(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        let container = UIView(frame: emptyControl.frame); container.addSubview(emptyControl)
        let emptyHeader = PWTrackMenuHeader(prior: container, button: UIButton(type: .system), width: 393)
        check(emptyHeader.bounds.height == 56, "empty controls do not count as header content")
        report("UI RUNNING: native header, nested action container and bottom spacer")
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        let nativeHeader = UIView(); nativeHeader.accessibilityIdentifier = "context-menu-header-view"
        let title = UILabel(); title.text = "Track header"
        nativeHeader.addSubview(title)
        let bottom = UIView(); bottom.accessibilityIdentifier = "context-menu-bottom-layout"
        let content = UIView(), spacer = UIView()
        for view in [nativeHeader, bottom, spacer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        title.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false; bottom.addSubview(content)
        let table = UITableView(frame: .zero, style: .plain); table.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(table)
        let spacerHeight = spacer.heightAnchor.constraint(equalToConstant: 0)
        let nativeTop = bottom.topAnchor.constraint(equalTo: nativeHeader.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([nativeHeader.topAnchor.constraint(equalTo: root.topAnchor),
            nativeHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor), nativeHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nativeHeader.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            title.topAnchor.constraint(equalTo: nativeHeader.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: nativeHeader.leadingAnchor, constant: 16), title.trailingAnchor.constraint(equalTo: nativeHeader.trailingAnchor, constant: -16),
            title.heightAnchor.constraint(equalToConstant: 32), title.bottomAnchor.constraint(lessThanOrEqualTo: nativeHeader.bottomAnchor, constant: -16),
            nativeTop, bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: bottom.topAnchor), content.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: bottom.leadingAnchor), content.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            table.topAnchor.constraint(equalTo: content.topAnchor), table.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor), table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            table.heightAnchor.constraint(equalToConstant: 240),
            spacer.topAnchor.constraint(equalTo: bottom.bottomAnchor), spacer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spacer.leadingAnchor.constraint(equalTo: root.leadingAnchor), spacer.trailingAnchor.constraint(equalTo: root.trailingAnchor), spacerHeight])
        table.tableHeaderView = emptyHeader; table.contentInset.top = 300; table.contentOffset.y = -300
        root.layoutIfNeeded()
        check(nativeHeader.bounds.height > 500, "fixture reproduces stretched native header before repair")
        for _ in 0..<50 {
            _ = PWTrackMenuLayout.compact(table: table, in: root); root.layoutIfNeeded()
            check(abs(root.convert(table.bounds, from: table).minY - 72) < 1, "nested table follows compressed native header: header=\(nativeHeader.frame), bottom=\(bottom.frame), spacer=\(spacer.frame)")
            check(table.contentInset.top == 0 && table.contentOffset.y >= 0, "no inner scroll spacer")
            check(nativeTop.isActive && nativeTop.constant == 8, "native title-to-actions anchor preserved")
            check(spacer.bounds.height > 450, "unused sheet space is below the actions")
        }
        check(!PWTrackMenuLayout.compact(table: table, in: root), "stable layout does not continually invalidate itself")
        let foreign = UITableView(); let before = root.constraints.count
        check(!PWTrackMenuLayout.compact(table: foreign, in: root) && root.constraints.count == before, "unrelated tables untouched")
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
