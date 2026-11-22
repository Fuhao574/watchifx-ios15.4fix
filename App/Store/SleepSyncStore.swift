import Combine
import Foundation

/// Page-local state. Reading or publishing a snapshot never starts a sync or recovery.
@MainActor
final class WFSleepSyncStore: ObservableObject {
    @Published private(set) var snapshot = WFSleepSyncSnapshot(dictionary: WFSleepSyncBridge.snapshot())
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    func refresh() {
        snapshot = WFSleepSyncSnapshot(dictionary: WFSleepSyncBridge.snapshot())
    }

    /// The caller must obtain explicit informed confirmation before invoking this action.
    func start() {
        guard !busy else { return }
        refresh()
        guard snapshot.canStart else { return }
        perform(.start)
    }

    func cancel() {
        guard !busy else { return }
        refresh()
        guard snapshot.canCancel else { return }
        perform(.cancel)
    }

    func recover() {
        guard !busy else { return }
        refresh()
        guard snapshot.backendAvailable, snapshot.needsRecovery else { return }
        perform(.recover)
    }

    private enum Action: String {
        case start, cancel, recover
    }

    private func perform(_ action: Action) {
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var bridgeError: NSError?
            let accepted: Bool
            // The explicit NSError-pointer bridge contract preserves the BOOL result.
            switch action {
            case .start:
                accepted = WFSleepSyncBridge.start(error: &bridgeError)
            case .cancel:
                accepted = WFSleepSyncBridge.cancel(error: &bridgeError)
            case .recover:
                accepted = WFSleepSyncBridge.recover(error: &bridgeError)
            }
            let failed = !accepted || bridgeError != nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A returned BOOL is command acceptance, not protocol or user success.
                self.refresh()
                self.error = failed ? L("sleepSync.error.\(action.rawValue)") : nil
                self.busy = false
            }
        }
    }
}
