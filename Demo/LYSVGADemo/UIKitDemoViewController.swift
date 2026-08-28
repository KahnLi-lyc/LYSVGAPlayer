import LYSVGAPlayer
import UIKit
import UniformTypeIdentifiers

@MainActor
final class UIKitDemoViewController: UIViewController {
    private let playerView = LYSVGAPlayerView()
    private let loader = LYSVGAAssetLoader()
    private let statusLabel = UILabel()
    private let progressSlider = UISlider()
    private let remoteField = UITextField()
    private let playButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let loopSwitch = UISwitch()
    private let reverseSwitch = UISwitch()
    private var loadTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Player"
        view.backgroundColor = .systemBackground
        playerView.delegate = self
        playerView.contentMode = .scaleAspectFit
        playerView.clipsToBounds = true
        configureHierarchy()
        configureControls()
        updateState()
    }

    deinit {
        loadTask?.cancel()
    }

    private func configureHierarchy() {
        let scrollView = UIScrollView()
        let stack = UIStackView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        playerView.backgroundColor = .secondarySystemBackground
        playerView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(playerView)
        playerView.heightAnchor.constraint(equalToConstant: 300).isActive = true

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        stack.addArrangedSubview(statusLabel)

        let sourceRow = UIStackView(arrangedSubviews: [sampleButton(), fileButton()])
        sourceRow.axis = .horizontal
        sourceRow.spacing = 10
        sourceRow.distribution = .fillEqually
        stack.addArrangedSubview(sourceRow)

        remoteField.borderStyle = .roundedRect
        remoteField.placeholder = "HTTPS SVGA URL"
        remoteField.keyboardType = .URL
        remoteField.autocapitalizationType = .none
        remoteField.autocorrectionType = .no
        let remoteRow = UIStackView(arrangedSubviews: [remoteField, loadURLButton()])
        remoteRow.axis = .horizontal
        remoteRow.spacing = 8
        stack.addArrangedSubview(remoteRow)

        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
        stack.addArrangedSubview(progressSlider)

        let playbackRow = UIStackView(arrangedSubviews: [playButton, stopButton(), muteButton])
        playbackRow.axis = .horizontal
        playbackRow.spacing = 12
        playbackRow.distribution = .fillEqually
        stack.addArrangedSubview(playbackRow)

        let optionsRow = UIStackView(arrangedSubviews: [optionView("Loop", switchControl: loopSwitch), optionView("Reverse", switchControl: reverseSwitch)])
        optionsRow.axis = .horizontal
        optionsRow.spacing = 20
        optionsRow.distribution = .fillEqually
        stack.addArrangedSubview(optionsRow)

        let dynamicRow = UIStackView(arrangedSubviews: [replaceButton(), restoreButton()])
        dynamicRow.axis = .horizontal
        dynamicRow.spacing = 10
        dynamicRow.distribution = .fillEqually
        stack.addArrangedSubview(dynamicRow)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func configureControls() {
        playButton.configuration = iconConfiguration("play.fill")
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        playButton.accessibilityLabel = "Play"
        playButton.toolTip = "Play or pause"

        muteButton.configuration = iconConfiguration("speaker.wave.2.fill")
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        muteButton.accessibilityLabel = "Mute"
        muteButton.toolTip = "Mute or unmute"

        loopSwitch.isOn = true
    }

    private func sampleButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = titleConfiguration("Bundle", systemImage: "shippingbox")
        button.menu = UIMenu(children: DemoSample.allCases.map { sample in
            UIAction(title: sample.title) { [weak self] _ in self?.load(sample) }
        })
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func fileButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = titleConfiguration("File", systemImage: "folder")
        button.addAction(UIAction { [weak self] _ in self?.openFile() }, for: .touchUpInside)
        return button
    }

    private func loadURLButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = iconConfiguration("arrow.down.circle")
        button.accessibilityLabel = "Load URL"
        button.toolTip = "Load URL"
        button.addAction(UIAction { [weak self] _ in self?.loadRemoteURL() }, for: .touchUpInside)
        return button
    }

    private func stopButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = iconConfiguration("stop.fill")
        button.accessibilityLabel = "Stop"
        button.toolTip = "Stop"
        button.addAction(UIAction { [weak self] _ in self?.playerView.stop() }, for: .touchUpInside)
        return button
    }

    private func replaceButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = titleConfiguration("Replace", systemImage: "photo.badge.arrow.down")
        button.addAction(UIAction { [weak self] _ in
            guard let self, let key = playerView.video?.sprites.first?.imageKey else { return }
            playerView.setImage(DemoSupport.replacementImage(), forKey: key)
        }, for: .touchUpInside)
        return button
    }

    private func restoreButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = titleConfiguration("Restore", systemImage: "arrow.uturn.backward")
        button.addAction(UIAction { [weak self] _ in self?.playerView.clearDynamicContents() }, for: .touchUpInside)
        return button
    }

    private func optionView(_ title: String, switchControl: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        let row = UIStackView(arrangedSubviews: [label, switchControl])
        row.axis = .horizontal
        row.distribution = .equalSpacing
        return row
    }

    private func titleConfiguration(_ title: String, systemImage: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 6
        return configuration
    }

    private func iconConfiguration(_ systemImage: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: systemImage)
        return configuration
    }

    @objc private func togglePlayback() {
        if playerView.playbackState == .playing {
            playerView.pause()
        } else if playerView.playbackState == .paused {
            playerView.resume()
        } else {
            playerView.repeatMode = loopSwitch.isOn ? .forever : .once
            do {
                try playerView.play(reverse: reverseSwitch.isOn)
            } catch {
                statusLabel.text = error.localizedDescription
            }
        }
    }

    @objc private func toggleMute() {
        playerView.isMuted.toggle()
        updateState()
    }

    @objc private func seekChanged() {
        playerView.seek(toProgress: Double(progressSlider.value))
    }

    private func load(_ sample: DemoSample) {
        guard let url = sample.url else {
            statusLabel.text = "Missing bundled sample: \(sample.rawValue).svga"
            return
        }
        startLoad(.file(url))
    }

    private func loadRemoteURL() {
        guard let text = remoteField.text,
              let url = URL(string: text), url.scheme?.lowercased() == "https" else {
            statusLabel.text = "Enter a valid HTTPS URL."
            return
        }
        startLoad(.remote(url))
    }

    private func openFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func startLoad(_ source: LYSVGASource) {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await playerView.load(source, using: loader, autoplay: true)
            } catch let error as LYSVGAError where error == .cancelled {
                return
            } catch {
                statusLabel.text = error.localizedDescription
            }
        }
    }

    private func updateState() {
        statusLabel.text = "\(playerView.playbackState)  frame \(playerView.currentFrame.map(String.init) ?? "-")"
        progressSlider.value = Float(playerView.currentProgress)
        playButton.configuration?.image = UIImage(
            systemName: playerView.playbackState == .playing ? "pause.fill" : "play.fill"
        )
        playButton.accessibilityLabel = playerView.playbackState == .playing ? "Pause" : "Play"
        muteButton.configuration?.image = UIImage(
            systemName: playerView.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        )
    }
}

extension UIKitDemoViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        startLoad(.file(url))
    }
}

extension UIKitDemoViewController: LYSVGAPlayerViewDelegate {
    func playerView(_ playerView: LYSVGAPlayerView, didChangePlaybackState state: LYSVGAPlaybackState) {
        updateState()
    }

    func playerView(_ playerView: LYSVGAPlayerView, didDisplayFrame frame: Int, progress: Double) {
        updateState()
    }

    func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError) {
        statusLabel.text = error.localizedDescription
    }
}
