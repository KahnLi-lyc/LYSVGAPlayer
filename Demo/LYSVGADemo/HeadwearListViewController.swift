import LYSVGAPlayer
import UIKit

@MainActor
final class HeadwearListViewController: UIViewController {
    private enum AutoScrollPhase {
        case idle
        case warming(elapsed: TimeInterval)
        case measuring(elapsed: TimeInterval)
    }

    private let loader = LYSVGAAssetLoader()
    private let users = HeadwearListUser.samples
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let modeControl = UISegmentedControl(items: HeadwearListMode.allCases.map(\.title))
    private let metricsLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let emptyLabel = UILabel()
    private let monitor = HeadwearListPerformanceMonitor()

    private var assets: [HeadwearListAsset] = []
    private var loadTask: Task<Void, Never>?
    private var autoScrollPhase: AutoScrollPhase = .idle
    private var autoScrollDirection: CGFloat = 1
    private var completedRoundTripCount = 0
    private var autoScrollButton: UIBarButtonItem!
    private var resetButton: UIBarButtonItem!
    private var isAppInBackground = false

    private let warmupSeconds: TimeInterval = 3
    private let measurementSeconds: TimeInterval = 30

    private var mode: HeadwearListMode {
        HeadwearListMode(rawValue: modeControl.selectedSegmentIndex) ?? .mixed
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Headwear List"
        view.backgroundColor = .systemBackground
        configureHierarchy()
        configureMonitor()
        configureNotifications()
        loadAssets()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        monitor.start()
        setVisibleCellsActive(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopAutoScroll(writeReport: false)
        setVisibleCellsActive(false)
        monitor.stop()
    }

    deinit {
        loadTask?.cancel()
    }

    private func configureHierarchy() {
        modeControl.selectedSegmentIndex = HeadwearListMode.mixed.rawValue
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeControl)

        metricsLabel.translatesAutoresizingMaskIntoConstraints = false
        metricsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        metricsLabel.textColor = .secondaryLabel
        metricsLabel.numberOfLines = 2
        metricsLabel.adjustsFontForContentSizeCategory = true
        metricsLabel.text = "FPS --  P95 --  Hitch --\nVisible 0  Memory --"
        view.addSubview(metricsLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.rowHeight = 96
        tableView.estimatedRowHeight = 96
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 106, bottom: 0, right: 16)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(HeadwearListCell.self, forCellReuseIdentifier: HeadwearListCell.reuseIdentifier)
        view.addSubview(tableView)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        view.addSubview(loadingIndicator)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        autoScrollButton = UIBarButtonItem(
            image: UIImage(systemName: "play.circle"),
            style: .plain,
            target: self,
            action: #selector(toggleAutoScroll)
        )
        autoScrollButton.accessibilityLabel = "Start automatic scroll benchmark"
        autoScrollButton.isEnabled = false
        resetButton = UIBarButtonItem(
            image: UIImage(systemName: "arrow.counterclockwise"),
            style: .plain,
            target: self,
            action: #selector(resetMetrics)
        )
        resetButton.accessibilityLabel = "Reset performance metrics"
        navigationItem.rightBarButtonItems = [autoScrollButton, resetButton]

        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            modeControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            modeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            modeControl.heightAnchor.constraint(equalToConstant: 32),

            metricsLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            metricsLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            metricsLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            metricsLabel.heightAnchor.constraint(equalToConstant: 36),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: metricsLabel.bottomAnchor, constant: 4),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: tableView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: tableView.trailingAnchor, constant: -24),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
        ])
    }

    private func configureMonitor() {
        monitor.onUpdate = { [weak self] snapshot in
            self?.metricsLabel.text = String(
                format: "FPS %.1f  P95 %.1fms  Hitch %.1f%%\nVisible %d  Memory %.1f MB",
                snapshot.framesPerSecond,
                snapshot.p95FrameMilliseconds,
                snapshot.hitchRate * 100,
                snapshot.visiblePlayerCount,
                Double(snapshot.residentMemoryBytes) / 1_048_576
            )
        }
        monitor.onFrame = { [weak self] interval in
            self?.advanceAutoScroll(by: interval)
        }
    }

    private func configureNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground() {
        isAppInBackground = true
        stopAutoScroll(writeReport: false)
        setVisibleCellsActive(false)
        monitor.stop()
    }

    @objc private func applicationWillEnterForeground() {
        isAppInBackground = false
        guard viewIfLoaded?.window != nil else { return }
        monitor.start()
        setVisibleCellsActive(true)
    }

    private func loadAssets() {
        loadingIndicator.startAnimating()
        emptyLabel.isHidden = true
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await HeadwearListAssetRepository.load(using: loader)
            guard Task.isCancelled == false else { return }
            assets = result.assets
            loadingIndicator.stopAnimating()
            autoScrollButton.isEnabled = assets.isEmpty == false
            emptyLabel.isHidden = assets.isEmpty == false
            if assets.isEmpty {
                emptyLabel.text = result.failures.isEmpty
                    ? "No SVGA assets are available."
                    : result.failures.joined(separator: "\n")
            }
            tableView.reloadData()
            updateVisiblePlayerCount()
        }
    }

    private func asset(forRow row: Int) -> HeadwearListAsset? {
        guard assets.isEmpty == false else { return nil }
        switch mode {
        case .single:
            return assets[0]
        case .mixed:
            return assets[row % assets.count]
        }
    }

    @objc private func modeChanged() {
        stopAutoScroll(writeReport: false)
        tableView.visibleCells.compactMap { $0 as? HeadwearListCell }.forEach { $0.setActive(false) }
        tableView.reloadData()
        monitor.resetRollingMetrics()
        updateVisiblePlayerCount()
    }

    @objc private func resetMetrics() {
        monitor.resetRollingMetrics()
    }

    @objc private func toggleAutoScroll() {
        switch autoScrollPhase {
        case .idle:
            startAutoScroll()
        case .warming, .measuring:
            stopAutoScroll(writeReport: false)
        }
    }

    private func startAutoScroll() {
        guard assets.isEmpty == false, maximumContentOffset > 0 else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        autoScrollDirection = 1
        autoScrollPhase = .warming(elapsed: 0)
        autoScrollButton.image = UIImage(systemName: "stop.circle")
        autoScrollButton.accessibilityLabel = "Stop automatic scroll benchmark"
        modeControl.isEnabled = false
        monitor.resetRollingMetrics()
    }

    private func advanceAutoScroll(by interval: TimeInterval) {
        switch autoScrollPhase {
        case .idle:
            return
        case let .warming(elapsed):
            let nextElapsed = elapsed + interval
            scroll(by: interval)
            if nextElapsed >= warmupSeconds {
                tableView.setContentOffset(
                    CGPoint(x: 0, y: -tableView.adjustedContentInset.top),
                    animated: false
                )
                autoScrollDirection = 1
                completedRoundTripCount = 0
                monitor.beginMeasurement()
                autoScrollPhase = .measuring(elapsed: 0)
            } else {
                autoScrollPhase = .warming(elapsed: nextElapsed)
            }
        case let .measuring(elapsed):
            let nextElapsed = elapsed + interval
            scrollMeasurement(to: min(nextElapsed, measurementSeconds))
            if nextElapsed >= measurementSeconds {
                stopAutoScroll(writeReport: true)
            } else {
                autoScrollPhase = .measuring(elapsed: nextElapsed)
            }
        }
    }

    private func scroll(by interval: TimeInterval) {
        let minimumOffset = -tableView.adjustedContentInset.top
        let maximumOffset = maximumContentOffset
        guard maximumOffset > minimumOffset else { return }
        let distance = maximumOffset - minimumOffset
        let speed = distance * 6 / measurementSeconds
        var target = min(max(tableView.contentOffset.y, minimumOffset), maximumOffset)
        var remainingDistance = speed * interval
        while remainingDistance > 0 {
            let boundary = autoScrollDirection > 0 ? maximumOffset : minimumOffset
            let distanceToBoundary = abs(boundary - target)
            if remainingDistance < distanceToBoundary {
                target += autoScrollDirection * remainingDistance
                remainingDistance = 0
            } else {
                target = boundary
                remainingDistance -= distanceToBoundary
                if autoScrollDirection < 0 {
                    monitor.markTraversalBoundary()
                }
                autoScrollDirection *= -1
            }
        }
        tableView.contentOffset = CGPoint(x: 0, y: target)
    }

    private func scrollMeasurement(to elapsed: TimeInterval) {
        let minimumOffset = -tableView.adjustedContentInset.top
        let maximumOffset = maximumContentOffset
        guard maximumOffset > minimumOffset else { return }

        let progress = min(max(elapsed / measurementSeconds, 0), 1)
        let roundTripProgress = progress * 3
        let completedRoundTrips = progress == 1 ? 3 : Int(floor(roundTripProgress))
        while completedRoundTripCount < completedRoundTrips {
            monitor.markTraversalBoundary()
            completedRoundTripCount += 1
        }

        let fractionalRoundTrip = roundTripProgress - floor(roundTripProgress)
        let distance = maximumOffset - minimumOffset
        let position: CGFloat
        if fractionalRoundTrip <= 0.5 {
            position = minimumOffset + distance * CGFloat(fractionalRoundTrip * 2)
        } else {
            position = maximumOffset - distance * CGFloat((fractionalRoundTrip - 0.5) * 2)
        }
        tableView.contentOffset = CGPoint(x: 0, y: position)
    }

    private var maximumContentOffset: CGFloat {
        max(
            -tableView.adjustedContentInset.top,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )
    }

    private func stopAutoScroll(writeReport: Bool) {
        guard case .idle = autoScrollPhase else {
            if writeReport,
               let report = monitor.finishMeasurement(
                   mode: mode,
                   rowCount: users.count,
                   assetFileNames: assets.map(\.fileName),
                   warmupSeconds: warmupSeconds,
                   durationSeconds: measurementSeconds
               ) {
                write(report)
            } else {
                monitor.cancelMeasurement()
            }
            autoScrollPhase = .idle
            autoScrollButton.image = UIImage(systemName: "play.circle")
            autoScrollButton.accessibilityLabel = "Start automatic scroll benchmark"
            modeControl.isEnabled = true
            return
        }
    }

    private func write(_ report: HeadwearListBenchmarkReport) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try data.write(
                to: directory.appendingPathComponent("headwear-list-benchmark.json"),
                options: .atomic
            )
            encoder.outputFormatting = [.sortedKeys]
            let compactData = try encoder.encode(report)
            print("LYSVGA_HEADWEAR_LIST_RESULT \(String(decoding: compactData, as: UTF8.self))")
        } catch {
            metricsLabel.text = "Unable to write benchmark report\n\(error.localizedDescription)"
            metricsLabel.textColor = .systemRed
        }
    }

    private func setVisibleCellsActive(_ active: Bool) {
        tableView.visibleCells.compactMap { $0 as? HeadwearListCell }.forEach { $0.setActive(active) }
        updateVisiblePlayerCount()
    }

    private func updateVisiblePlayerCount() {
        monitor.updateVisiblePlayerCount(
            tableView.indexPathsForVisibleRows?.count ?? 0
        )
    }
}

extension HeadwearListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        assets.isEmpty ? 0 : users.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: HeadwearListCell.reuseIdentifier,
            for: indexPath
        ) as? HeadwearListCell,
            let asset = asset(forRow: indexPath.row) else {
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }
        cell.configure(user: users[indexPath.row], asset: asset)
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? HeadwearListCell)?.setActive(isAppInBackground == false && viewIfLoaded?.window != nil)
        updateVisiblePlayerCount()
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? HeadwearListCell)?.setActive(false)
        updateVisiblePlayerCount()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisiblePlayerCount()
    }
}
