import UIKit
import MediaPlayer
import AVKit
import CoreImage

// Full-screen composition follows the supplied Spotify player: artwork above a
// flexible gap, title/progress/transport below, then lyrics/devices/queue.
@MainActor
final class PWOfflinePlayerController: UIViewController {
    private let scroll = UIScrollView(), content = UIView()
    private let cover = UIImageView(), song = UILabel(), artist = UILabel(), heading = UILabel()
    private let elapsed = UILabel(), remaining = UILabel(), saved = UIImageView()
    private let slider = PWOfflineScrubber(), play = UIButton(type: .system)
    private let shuffle = UIButton(type: .system), repeatButton = UIButton(type: .system)
    private var close: UIButton!, more: UIButton!, previous: UIButton!, nextButton: UIButton!, lyrics: UIButton!, queue: UIButton!
    private let devices = AVRoutePickerView()
    private var timer: Timer?, observer: NSObjectProtocol?
    private let gradient = CAGradientLayer()
    private var coloredArtwork: UIImage?
    private var model: PWOfflinePlayer { .shared }
    static func show(from controller: UIViewController) {
        guard PWOfflinePlayer.shared.current != nil, !(controller is PWOfflinePlayerController) else { return }
        let player = PWOfflinePlayerController(); player.modalPresentationStyle = .fullScreen
        controller.present(player, animated: true)
    }
    private func button(_ symbol: String, _ label: String, size: CGFloat = 24, action: @escaping () -> Void) -> UIButton {
        let value = UIButton(type: .system)
        value.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)), for: .normal)
        value.accessibilityLabel = label; value.tintColor = .white
        value.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return value
    }
    private func glass(_ button: UIButton) {
        let pane: UIView
        if UIAccessibility.isReduceTransparencyEnabled {
            pane = UIView(); pane.backgroundColor = UIColor(white: 0.12, alpha: 1)
        } else {
            let effect: UIVisualEffect
            if #available(iOS 26.0, *) { effect = UIGlassEffect(style: .regular) }
            else { effect = UIBlurEffect(style: .systemThinMaterialDark) }
            pane = UIVisualEffectView(effect: effect)
        }
        pane.overrideUserInterfaceStyle = .dark; pane.isUserInteractionEnabled = false
        pane.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        pane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pane.layer.cornerRadius = 22; pane.layer.cornerCurve = .continuous; pane.clipsToBounds = true
        pane.layer.borderWidth = 0.5; pane.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        button.insertSubview(pane, at: 0)
    }
    override func viewDidLoad() {
        super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = .black
        gradient.colors = [UIColor(white: 0.18, alpha: 1).cgColor, UIColor(white: 0.06, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0); gradient.endPoint = CGPoint(x: 1, y: 1)
        view.layer.insertSublayer(gradient, at: 0)
        scroll.contentInsetAdjustmentBehavior = .never; scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll); scroll.addSubview(content)
        heading.font = .systemFont(ofSize: 13, weight: .semibold); heading.textAlignment = .center
        heading.lineBreakMode = .byTruncatingTail
        close = button("chevron.down", "Réduire le lecteur") { [weak self] in self?.dismiss(animated: true) }
        more = button("ellipsis", "Options du titre") {}
        close.frame.size = CGSize(width: 44, height: 44); more.frame.size = close.frame.size
        glass(close); glass(more)
        more.showsMenuAsPrimaryAction = true
        let disabled = [("Accéder à l’artiste", "person"), ("Accéder à l’album", "square.stack"),
                        ("Aller à la radio", "dot.radiowaves.left.and.right"), ("Paroles", "quote.bubble")].map { title, icon in
            UIAction(title: title, image: UIImage(systemName: icon), attributes: .disabled) { _ in }
        }
        more.menu = UIMenu(children: [UIAction(title: "File d’attente", image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.showQueue() },
            UIAction(title: "Partager le fichier", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self = self, let entry = self.model.current else { return }
                PWLocalLibraryController.share(entry, from: self, anchor: self.more)
            }] + disabled)
        cover.contentMode = .scaleAspectFill; cover.clipsToBounds = true; cover.layer.cornerRadius = 11
        cover.layer.cornerCurve = .continuous; cover.backgroundColor = UIColor(white: 0.12, alpha: 1); cover.tintColor = .secondaryLabel
        cover.isAccessibilityElement = true; cover.accessibilityLabel = "Pochette du titre"
        song.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 24, weight: .bold))
        song.numberOfLines = 1; song.lineBreakMode = .byTruncatingTail
        artist.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16))
        artist.textColor = UIColor.white.withAlphaComponent(0.7); artist.numberOfLines = 1
        saved.image = UIImage(systemName: "checkmark.circle.fill")
        saved.tintColor = UIColor(red: 0.2, green: 0.95, blue: 0, alpha: 1)
        saved.isAccessibilityElement = true; saved.accessibilityLabel = "Téléchargé sur cet iPhone"
        slider.minimumValue = 0; slider.minimumTrackTintColor = .white; slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        slider.accessibilityLabel = "Position dans le titre"
        let invisible = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        slider.setThumbImage(invisible, for: .normal)
        slider.addAction(UIAction { [weak self] _ in self?.refreshTime() }, for: .valueChanged)
        for event in [UIControl.Event.touchUpInside, .touchUpOutside] {
            slider.addAction(UIAction { [weak self] _ in guard let self = self else { return }; self.model.seek(Double(self.slider.value)) }, for: event)
        }
        for label in [elapsed, remaining] { label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); label.textColor = UIColor.white.withAlphaComponent(0.7) }
        remaining.textAlignment = .right
        shuffle.accessibilityLabel = "Lecture aléatoire"; shuffle.addAction(UIAction { [weak self] _ in self?.model.toggleShuffle(); self?.refresh() }, for: .touchUpInside)
        repeatButton.accessibilityLabel = "Répétition"; repeatButton.addAction(UIAction { [weak self] _ in self?.model.cycleRepeat(); self?.refresh() }, for: .touchUpInside)
        play.tintColor = .white; play.addAction(UIAction { [weak self] _ in self?.model.toggle(); self?.refresh() }, for: .touchUpInside)
        previous = button("backward.fill", "Titre précédent", size: 36) { [weak self] in self?.model.previous() }
        nextButton = button("forward.fill", "Titre suivant", size: 36) { [weak self] in self?.model.next() }
        lyrics = button("quote.bubble", "Paroles indisponibles hors connexion", size: 22) {}
        lyrics.isEnabled = false; lyrics.tintColor = UIColor.white.withAlphaComponent(0.4)
        queue = button("list.bullet", "File d’attente", size: 22) { [weak self] in self?.showQueue() }
        devices.tintColor = .white; devices.activeTintColor = .systemGreen
        devices.accessibilityLabel = "Choisir la sortie audio"
        let elements: [UIView] = [heading, close, more, cover, song, artist, saved, slider, elapsed, remaining,
                                 shuffle, previous, play, nextButton, repeatButton, lyrics, devices, queue]
        for element in elements { content.addSubview(element) }
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); gradient.frame = view.bounds; scroll.frame = view.bounds
        let safe = view.safeAreaInsets, width = min(view.bounds.width, 560), left = (view.bounds.width - width) / 2
        let margin = round(width * 0.065), coverMargin = round(width * 0.07), coverSide = width - 2 * coverMargin
        let labelHeight = max(55, ceil(song.font.lineHeight + artist.font.lineHeight + 5))
        // Small screens and large accessibility text scroll; no overlapping controls.
        let height = max(view.bounds.height, safe.top + 60 + coverSide + 32 + labelHeight + 198 + safe.bottom)
        content.frame = CGRect(x: left, y: 0, width: width, height: height)
        scroll.contentSize = CGSize(width: view.bounds.width, height: height)
        close.frame = CGRect(x: 14, y: safe.top + 4, width: 44, height: 44)
        more.frame = CGRect(x: width - 58, y: close.frame.minY, width: 44, height: 44)
        heading.frame = CGRect(x: 66, y: close.frame.minY, width: width - 132, height: 44)
        cover.frame = CGRect(x: coverMargin, y: close.frame.maxY + 11, width: coverSide, height: coverSide)
        let footerY = height - safe.bottom - 66
        for (index, item) in [lyrics!, devices, queue!].enumerated() {
            let center = margin + (width - 2 * margin) * CGFloat(2 * index + 1) / 6
            item.frame = CGRect(x: center - 22, y: footerY, width: 44, height: 44)
        }
        let controlsY = footerY - 64
        for (index, item) in [shuffle, previous!, play, nextButton!, repeatButton].enumerated() {
            let center = margin + 22 + (width - 2 * margin - 44) * CGFloat(index) / 4
            item.frame = CGRect(x: center - 26, y: controlsY, width: 52, height: 56)
        }
        slider.frame = CGRect(x: margin, y: controlsY - 63, width: width - 2 * margin, height: 32)
        elapsed.frame = CGRect(x: margin, y: slider.frame.midY + 8, width: 75, height: 18)
        remaining.frame = CGRect(x: width - margin - 75, y: elapsed.frame.minY, width: 75, height: 18)
        let labelsY = slider.frame.midY - 72 - max(0, labelHeight - 55)
        song.frame = CGRect(x: margin, y: labelsY, width: width - 2 * margin - 47, height: ceil(song.font.lineHeight))
        artist.frame = CGRect(x: margin, y: song.frame.maxY + 4, width: song.frame.width, height: ceil(artist.font.lineHeight))
        saved.frame = CGRect(x: width - margin - 30, y: labelsY + (labelHeight - 30) / 2, width: 30, height: 30)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshTime() } }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate(); if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() {
        song.text = model.current?.track.title ?? "Aucune lecture"; artist.text = model.current?.track.artist
        heading.text = model.current?.playlistURI.flatMap { PWLocalLibrary.shared.catalog.playlists[$0]?.title } ?? "Titres téléchargés"
        heading.accessibilityValue = "Lecture hors connexion"
        cover.image = model.artwork ?? UIImage(systemName: "music.note")
        if coloredArtwork !== model.artwork {
            coloredArtwork = model.artwork; updateColors(model.artwork)
        }
        play.accessibilityLabel = model.playing ? "Pause" : "Lire"
        play.setImage(UIImage(systemName: model.playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 39)), for: .normal)
        shuffle.setImage(UIImage(systemName: "shuffle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)), for: .normal)
        repeatButton.setImage(UIImage(systemName: model.repeatMode == 2 ? "repeat.1" : "repeat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)), for: .normal)
        shuffle.tintColor = model.shuffled ? .systemGreen : .white; shuffle.accessibilityValue = model.shuffled ? "Activée" : "Désactivée"
        repeatButton.tintColor = model.repeatMode > 0 ? .systemGreen : .white
        repeatButton.accessibilityValue = ["Désactivée", "Toute la file", "Ce titre"][model.repeatMode]
        refreshTime()
    }
    private func updateColors(_ image: UIImage?) {
        guard let image = image, let input = CIImage(image: image) else {
            gradient.colors = [UIColor(white: 0.18, alpha: 1).cgColor, UIColor(white: 0.06, alpha: 1).cgColor]; return
        }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let extent = input.extent
        func color(_ rect: CGRect, brightness: CGFloat) -> CGColor {
            let filtered = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(filtered, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let average = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return UIColor(hue: h, saturation: min(0.85, s * 1.35), brightness: min(brightness, max(0.14, b * 0.85)), alpha: 1).cgColor
        }
        let upper = CGRect(x: extent.minX, y: extent.midY, width: extent.width, height: extent.height / 2)
        let lower = CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height / 2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.colors = [color(upper, brightness: 0.32), color(extent, brightness: 0.46), color(lower, brightness: 0.28)]
        CATransaction.commit()
    }
    private func refreshTime() {
        func time(_ seconds: Double) -> String { let n = Int(max(0, seconds)); return String(format: "%d:%02d", n / 60, n % 60) }
        if !slider.isTracking { slider.maximumValue = Float(model.duration); slider.value = Float(model.elapsed) }
        elapsed.text = time(Double(slider.value)); remaining.text = "−" + time(model.duration - Double(slider.value))
        slider.accessibilityValue = "\(time(Double(slider.value))) sur \(time(model.duration))"
    }
    private func showQueue() { PWDownloadsBridge.panel(PWOfflineQueueController(style: .insetGrouped), from: self) }
}

private final class PWOfflineScrubber: UISlider {
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.midY - 3, width: bounds.width, height: 6)
    }
}

@MainActor
final class PWOfflineQueueController: UITableViewController {
    private var observer: NSObjectProtocol?
    private var player: PWOfflinePlayer { .shared }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "File d’attente"; overrideUserInterfaceStyle = .dark
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = editButtonItem; tableView.allowsSelectionDuringEditing = true
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tableView.reloadData() } }
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    @objc private func close() { dismiss(animated: true) }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { player.queue.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil), entry = player.queue[indexPath.row]
        cell.textLabel?.text = entry.track.title; cell.detailTextLabel?.text = entry.track.artist
        cell.textLabel?.textColor = indexPath.row == player.index ? .systemGreen : .label
        cell.imageView?.image = UIImage(systemName: indexPath.row == player.index ? "waveform" : "music.note")
        cell.showsReorderControl = true; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { player.jump(indexPath.row); tableView.deselectRow(at: indexPath, animated: true) }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) { player.move(sourceIndexPath.row, to: destinationIndexPath.row) }
    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { indexPath.row == player.index ? .none : .delete }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) { if editingStyle == .delete { player.remove(indexPath.row) } }
}
