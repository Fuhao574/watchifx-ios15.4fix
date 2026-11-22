import Combine
import UIKit

final class SleepSyncViewController: WFScrollStackViewController {
    private let initialPlugin: PluginState?
    private let moduleStore = WFSleepSyncStore()
    private var moduleCancellables = Set<AnyCancellable>()
    private var statusTimer: Timer?
    private var isPageVisible = false

    init(store: Store, plugin: PluginState? = nil) {
        initialPlugin = plugin
        super.init(store: store, title: L("sleepSync.title"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // This page observes only its own module, not unrelated global Store changes.
    override func bindStore() { super.bindStore() }

    override func viewDidLoad() {
        super.viewDidLoad()
        Publishers.CombineLatest3(moduleStore.$snapshot, moduleStore.$busy, moduleStore.$error)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &moduleCancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startStatusPolling() }
            .store(in: &moduleCancellables)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stopStatusPolling() }
            .store(in: &moduleCancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isPageVisible = true
        startStatusPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPageVisible = false
        stopStatusPolling()
    }

    deinit {
        statusTimer?.invalidate()
    }

    private func startStatusPolling() {
        guard isPageVisible, UIApplication.shared.applicationState == .active else { return }
        stopStatusPolling()
        moduleStore.refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPageVisible,
                      UIApplication.shared.applicationState == .active else { return }
                self.moduleStore.refresh()
            }
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    override func render() {
        resetContent()
        let snapshot = moduleStore.snapshot
        if let initialPlugin {
            let plugin = store.plugins.first { $0.id == initialPlugin.id } ?? initialPlugin
            contentStack.addArrangedSubview(WFMakePluginHeaderCard(plugin: plugin))
        }
        var statusContents: [UIView] = [
            WFMakeTextLabel(L(snapshot.statusTitle), font: .preferredFont(forTextStyle: .headline)),
        ]
        for step in snapshot.progressSteps {
            let caption = L("sleepSync.progress.\(step.key)")
            let stateText = L("sleepSync.progress.\(step.state.rawValue)")
            let heading = UIStackView(arrangedSubviews: [
                WFMakeSecondaryLabel(caption), WFMakeFootnoteLabel(stateText),
            ])
            heading.axis = .horizontal
            heading.distribution = .equalSpacing
            heading.spacing = 8
            if step.state == .active {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                heading.addArrangedSubview(spinner)
            }
            let progressView = UIProgressView(progressViewStyle: .default)
            progressView.progressTintColor = step.state == .complete ? .systemGreen : .systemBlue
            progressView.setProgress(step.state == .complete ? 1 : 0, animated: false)
            progressView.accessibilityLabel = caption
            progressView.accessibilityValue = stateText
            statusContents.append(heading)
            statusContents.append(progressView)
        }
        statusContents.append(WFMakeSecondaryLabel(L(snapshot.statusDetail)))
        if snapshot.messageCode == .invalidStatus || snapshot.messageCode == .deadlineExceeded {
            statusContents.append(WFMakeFootnoteLabel(
                L("sleepSync.detail.\(snapshot.messageCode.rawValue)"), color: .systemOrange
            ))
        }
        if snapshot.phase == .waitingForSave {
            statusContents.append(WFMakeFootnoteLabel(L("sleepSync.instruction.save"), color: .systemOrange))
        }
        if snapshot.sessionID != nil, snapshot.cleanupVerified, !snapshot.phase.isActive {
            statusContents.append(WFMakeFootnoteLabel(L("sleepSync.instruction.restoreSetting"), color: .systemOrange))
        }
        if let error = moduleStore.error {
            statusContents.append(WFMakeFootnoteLabel(error, color: .systemRed))
        }
        contentStack.addArrangedSubview(WFMakeSection(
            title: L("sleepSync.section.status"), contents: [WFMakeCard(statusContents)]
        ))

        contentStack.addArrangedSubview(WFMakeSection(
            title: L("sleepSync.section.actions"),
            contents: [WFMakeCard([
                WFMakeActionButton(
                    title: L("sleepSync.action.start"), systemImage: "moon.zzz",
                    isLoading: moduleStore.busy, isEnabled: snapshot.canStart,
                    tintColor: .systemOrange
                ) { [weak self] in self?.presentStartConfirmation() },
                WFMakeActionButton(
                    title: L("sleepSync.action.cancel"), systemImage: "stop.circle",
                    isPrimary: false, isEnabled: !moduleStore.busy && snapshot.canCancel
                ) { [weak self] in self?.moduleStore.cancel() },
                WFMakeActionButton(
                    title: L("sleepSync.action.recover"), systemImage: "arrow.uturn.backward",
                    isPrimary: false,
                    isEnabled: !moduleStore.busy && snapshot.backendAvailable && snapshot.needsRecovery
                ) { [weak self] in self?.moduleStore.recover() },
                WFMakeActionButton(
                    title: L("sleepSync.action.refresh"), systemImage: "arrow.clockwise",
                    isPrimary: false, isEnabled: !moduleStore.busy
                ) { [weak self] in self?.moduleStore.refresh() },
            ])]
        ))
    }

    private func presentStartConfirmation() {
        guard !moduleStore.busy, moduleStore.snapshot.canStart else { return }
        let controller = UIAlertController(
            title: L("sleepSync.confirm.title"), message: L("sleepSync.confirm.message"), preferredStyle: .alert
        )
        controller.addAction(UIAlertAction(title: L("sleepSync.confirm.cancel"), style: .cancel))
        controller.addAction(UIAlertAction(title: L("sleepSync.confirm.start"), style: .destructive) { [weak self] _ in
            self?.moduleStore.start()
        })
        present(controller, animated: true)
    }
}
