import LYSVGAPlayer
import UIKit

@MainActor
final class HeadwearListCell: UITableViewCell {
    static let reuseIdentifier = "HeadwearListCell"

    private let playerView = LYSVGAPlayerView()
    private let avatarView = UIView()
    private let initialsLabel = UILabel()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let assetLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private var preparationTask: Task<Void, Never>?
    private var configurationRevision: UInt = 0
    private var representedAssetID: String?
    private var isActive = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureHierarchy()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        preparationTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configurationRevision &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        representedAssetID = nil
        isActive = false
        playerView.clear()
        loadingIndicator.stopAnimating()
        nameLabel.text = nil
        statusLabel.text = nil
        assetLabel.text = nil
        assetLabel.textColor = .tertiaryLabel
    }

    func configure(user: HeadwearListUser, asset: HeadwearListAsset) {
        nameLabel.text = user.displayName
        statusLabel.text = user.status
        assetLabel.text = asset.title
        assetLabel.textColor = .tertiaryLabel
        initialsLabel.text = String(user.displayName.prefix(1)).uppercased()
        avatarView.backgroundColor = Self.avatarColors[user.avatarColorIndex % Self.avatarColors.count]

        guard representedAssetID != asset.id || playerView.video == nil else {
            playIfReady()
            return
        }

        configurationRevision &+= 1
        let revision = configurationRevision
        representedAssetID = asset.id
        preparationTask?.cancel()
        playerView.clear()
        loadingIndicator.startAnimating()
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await playerView.setVideo(asset.video)
                try Task.checkCancellation()
                guard revision == configurationRevision, representedAssetID == asset.id else { return }
                loadingIndicator.stopAnimating()
                playIfReady()
            } catch is CancellationError {
                return
            } catch let error as LYSVGAError where error == .cancelled {
                return
            } catch {
                guard revision == configurationRevision else { return }
                loadingIndicator.stopAnimating()
                assetLabel.text = error.localizedDescription
                assetLabel.textColor = .systemRed
            }
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            playIfReady()
        } else {
            playerView.pause()
        }
    }

    private func playIfReady() {
        guard isActive, playerView.video != nil else { return }
        playerView.repeatMode = .forever
        playerView.isMuted = true
        switch playerView.playbackState {
        case .playing, .loading, .idle, .failed:
            break
        case .paused:
            playerView.resume()
        case .ready, .finished:
            try? playerView.play()
        }
    }

    private func configureHierarchy() {
        selectionStyle = .none
        backgroundColor = .systemBackground

        let headwearContainer = UIView()
        headwearContainer.translatesAutoresizingMaskIntoConstraints = false
        headwearContainer.isUserInteractionEnabled = false
        contentView.addSubview(headwearContainer)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.layer.cornerRadius = 23
        avatarView.clipsToBounds = true
        headwearContainer.addSubview(avatarView)

        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.font = .preferredFont(forTextStyle: .headline)
        initialsLabel.textColor = .white
        initialsLabel.textAlignment = .center
        avatarView.addSubview(initialsLabel)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.backgroundColor = .clear
        playerView.contentMode = .scaleAspectFit
        playerView.clipsToBounds = false
        playerView.isMuted = true
        playerView.repeatMode = .forever
        playerView.isUserInteractionEnabled = false
        headwearContainer.addSubview(playerView)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        headwearContainer.addSubview(loadingIndicator)

        let labels = UIStackView(arrangedSubviews: [nameLabel, statusLabel, assetLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 3
        labels.alignment = .fill
        contentView.addSubview(labels)

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.textColor = .label
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        assetLabel.font = .preferredFont(forTextStyle: .caption1)
        assetLabel.textColor = .tertiaryLabel
        assetLabel.lineBreakMode = .byTruncatingMiddle

        NSLayoutConstraint.activate([
            headwearContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            headwearContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            headwearContainer.widthAnchor.constraint(equalToConstant: 84),
            headwearContainer.heightAnchor.constraint(equalToConstant: 84),

            avatarView.centerXAnchor.constraint(equalTo: headwearContainer.centerXAnchor),
            avatarView.centerYAnchor.constraint(equalTo: headwearContainer.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 46),
            avatarView.heightAnchor.constraint(equalToConstant: 46),
            initialsLabel.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor),
            initialsLabel.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
            initialsLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),
            initialsLabel.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor),

            playerView.leadingAnchor.constraint(equalTo: headwearContainer.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: headwearContainer.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: headwearContainer.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: headwearContainer.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: headwearContainer.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: headwearContainer.centerYAnchor),

            labels.leadingAnchor.constraint(equalTo: headwearContainer.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    private static let avatarColors: [UIColor] = [
        .systemTeal, .systemIndigo, .systemPink, .systemGreen,
        .systemBlue, .systemPurple, .systemRed, .systemCyan,
    ]
}
