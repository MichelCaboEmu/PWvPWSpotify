import UIKit
import MediaPlayer

@MainActor
final class PWOfflinePlayerController: UIViewController {
    private let cover = UIImageView(), song = UILabel(), artist = UILabel(), elapsed = UILabel(), remaining = UILabel()
    private let slider = UISlider(), play = UIButton(type: .system), shuffle = UIButton(type: .system), repeatButton = UIButton(type: .system)
    private var timer: Timer?, observer: NSObjectProtocol?
    private let gradient = CAGradientLayer()
    private var model: PWOfflinePlayer { .shared }
    static func show(from controller: UIViewController) {
        guard PWOfflinePlayer.shared.current != nil, !(controller is PWOfflinePlayerController) else { return }
        let player = PWOfflinePlayerController(); player.modalPresentationStyle = .fullScreen
        controller.present(player, animated: true)
    }
    private func button(_ symbol: String, _ label: String, size: CGFloat = 24, action: @escaping () -> Void) -> UIButton {
        let value = UIButton(type: .system)
        value.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)), for: .normal)
        value.accessibilityLabel = label; value.tintColor = .white
        value.addAction(UIAction { _ in action() }, for: .touchUpInside)
        value.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        value.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return value
    }
    override func viewDidLoad() {
        super.viewDidLoad(); overrideUserInterfaceStyle = .dark; view.backgroundColor = .black
        gradient.colors = [UIColor(white: 0.18, alpha: 1).cgColor, UIColor.black.cgColor]; view.layer.insertSublayer(gradient, at: 0)
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -28)])
        let heading = UILabel(); heading.text = "LECTURE HORS CONNEXION"; heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textAlignment = .center
        let close = button("chevron.down", "Réduire le lecteur") { [weak self] in self?.dismiss(animated: true) }
        let more = button("ellipsis", "Options du titre") {}
        more.showsMenuAsPrimaryAction = true
        let disabled = ["Accéder à l’artiste", "Accéder à l’album", "Aller à la radio", "Paroles"].map { title in
            UIAction(title: title, attributes: .disabled) { _ in }
        }
        more.menu = UIMenu(children: [UIAction(title: "File d’attente", image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.showQueue() },
            UIAction(title: "Partager le fichier", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak more] _ in
                guard let self = self, let entry = self.model.current else { return }
                PWLocalLibraryController.share(entry, from: self, anchor: more)
            }] + disabled)
        let header = UIStackView(arrangedSubviews: [close, heading, more]); header.spacing = 8; stack.addArrangedSubview(header)
        cover.contentMode = .scaleAspectFit; cover.clipsToBounds = true; cover.layer.cornerRadius = 8
        cover.backgroundColor = UIColor(white: 0.12, alpha: 1); cover.tintColor = .secondaryLabel
        cover.heightAnchor.constraint(equalTo: cover.widthAnchor).isActive = true; stack.addArrangedSubview(cover)
        song.font = .systemFont(ofSize: 25, weight: .bold); song.numberOfLines = 2
        artist.font = .systemFont(ofSize: 17); artist.textColor = .secondaryLabel; artist.numberOfLines = 2
        let labels = UIStackView(arrangedSubviews: [song, artist]); labels.axis = .vertical; labels.spacing = 6; stack.addArrangedSubview(labels)
        slider.minimumValue = 0; slider.tintColor = .white; slider.accessibilityLabel = "Position dans le titre"
        slider.addAction(UIAction { [weak self] _ in guard let self = self else { return }; self.model.seek(Double(self.slider.value)) }, for: .touchUpInside)
        slider.addAction(UIAction { [weak self] _ in guard let self = self else { return }; self.model.seek(Double(self.slider.value)) }, for: .touchUpOutside)
        for label in [elapsed, remaining] { label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); label.textColor = .secondaryLabel }
        let times = UIStackView(arrangedSubviews: [elapsed, UIView(), remaining])
        let timeline = UIStackView(arrangedSubviews: [slider, times]); timeline.axis = .vertical; timeline.spacing = 0; stack.addArrangedSubview(timeline)
        shuffle.accessibilityLabel = "Lecture aléatoire"; shuffle.addAction(UIAction { [weak self] _ in self?.model.toggleShuffle(); self?.refresh() }, for: .touchUpInside)
        repeatButton.accessibilityLabel = "Répétition"; repeatButton.addAction(UIAction { [weak self] _ in self?.model.cycleRepeat(); self?.refresh() }, for: .touchUpInside)
        play.accessibilityLabel = "Lecture ou pause"; play.tintColor = .white; play.addAction(UIAction { [weak self] _ in self?.model.toggle(); self?.refresh() }, for: .touchUpInside)
        let previous = button("backward.end.fill", "Titre précédent", size: 28) { [weak self] in self?.model.previous() }
        let next = button("forward.end.fill", "Titre suivant", size: 28) { [weak self] in self?.model.next() }
        let controls = UIStackView(arrangedSubviews: [shuffle, previous, play, next, repeatButton]); controls.distribution = .equalSpacing; controls.alignment = .center
        for button in [shuffle, repeatButton, play] { button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true }
        stack.addArrangedSubview(controls)
        let lyrics = button("text.quote", "Paroles indisponibles hors connexion") {}; lyrics.isEnabled = false; lyrics.tintColor = .tertiaryLabel
        let queue = button("list.bullet", "File d’attente") { [weak self] in self?.showQueue() }
        let footer = UIStackView(arrangedSubviews: [lyrics, UIView(), queue]); stack.addArrangedSubview(footer)
        let volume = MPVolumeView(); volume.heightAnchor.constraint(equalToConstant: 30).isActive = true; stack.addArrangedSubview(volume)
        observer = NotificationCenter.default.addObserver(forName: pwChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); gradient.frame = view.bounds }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshTime() } }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate(); if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() {
        song.text = model.current?.track.title ?? "Aucune lecture"; artist.text = model.current?.track.artist
        cover.image = model.artwork ?? UIImage(systemName: "music.note")
        play.setImage(UIImage(systemName: model.playing ? "pause.circle.fill" : "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 66)), for: .normal)
        shuffle.setImage(UIImage(systemName: "shuffle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 23)), for: .normal)
        repeatButton.setImage(UIImage(systemName: model.repeatMode == 2 ? "repeat.1" : "repeat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 23)), for: .normal)
        shuffle.tintColor = model.shuffled ? .systemGreen : .white; shuffle.accessibilityValue = model.shuffled ? "Activée" : "Désactivée"
        repeatButton.tintColor = model.repeatMode > 0 ? .systemGreen : .white
        repeatButton.accessibilityValue = ["Désactivée", "Toute la file", "Ce titre"][model.repeatMode]
        refreshTime()
    }
    private func refreshTime() {
        func time(_ seconds: Double) -> String { let n = Int(max(0, seconds)); return String(format: "%d:%02d", n / 60, n % 60) }
        if !slider.isTracking { slider.maximumValue = Float(model.duration); slider.value = Float(model.elapsed) }
        elapsed.text = time(Double(slider.value)); remaining.text = "−" + time(model.duration - Double(slider.value))
    }
    private func showQueue() { PWDownloadsBridge.panel(PWOfflineQueueController(style: .insetGrouped), from: self) }
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
