import Foundation

// Host only. Compile this file together with App/Models/SleepSync.swift.
// No backend, private framework, device connection, or mutation is involved.
@main
enum SleepSyncStateTests {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        if !condition() { fatalError("FAIL: \(label)") }
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let id = "8846CB79-D280-4D11-85A6-FBE16A50F151"
        func status(_ phase: WFSleepSyncSnapshot.Phase = .idle) -> [String: Any] {
            var value: [String: Any] = [
                "phase": phase.rawValue, "messageCode": phase.rawValue,
                "ackMatched": false, "userVerified": false,
                "cleanupVerified": true, "backendAvailable": true, "sends": 0,
            ]
            if phase != .idle && phase != .unavailable {
                value["sessionID"] = id
                value["startedAt"] = now.addingTimeInterval(-10).timeIntervalSince1970
                value["deadline"] = now.addingTimeInterval(60).timeIntervalSince1970
            }
            return value
        }
        func snapshot(_ value: [String: Any]) -> WFSleepSyncSnapshot {
            WFSleepSyncSnapshot(dictionary: value, now: now)
        }

        let missing = snapshot([:])
        check(missing.phase == .unavailable, "missing status unavailable")
        check(!missing.canStart && !missing.canCancel, "missing status has no actions")
        check(!missing.backendAvailable && !missing.cleanupVerified, "missing flags never assumed true")

        let idle = snapshot(status())
        check(idle.phase == .idle && idle.canStart && !idle.canCancel, "clean idle can start")
        check(idle.sessionID == nil && idle.sends == 0, "idle has no synthetic session")

        for key in ["phase", "messageCode", "ackMatched", "userVerified", "cleanupVerified", "backendAvailable", "sends"] {
            var value = status()
            value.removeValue(forKey: key)
            let result = snapshot(value)
            check(result.phase == .unavailable || result.needsRecovery, "missing \(key) fails closed")
            check(!result.canStart, "missing \(key) cannot start")
        }

        for malformed: Any in ["true", "false", 1, 0, 2, NSNull()] {
            for key in ["ackMatched", "userVerified", "cleanupVerified", "backendAvailable"] {
                var value = status()
                value[key] = malformed
                check(!snapshot(value).canStart, "reject nonboolean \(key): \(malformed)")
            }
        }

        for malformed: Any in [-1, 2, 0.5, "1", true, Double.nan, Double.infinity] {
            var value = status()
            value["sends"] = malformed
            check(!snapshot(value).canStart, "reject send count \(malformed)")
        }

        var unknown = status()
        unknown["phase"] = "success"
        check(snapshot(unknown).phase == .unavailable, "unknown phase unavailable")
        unknown = status()
        unknown["messageCode"] = "arbitrary backend text / path / identifier"
        check(snapshot(unknown).messageCode == .invalidStatus, "unknown message discarded")
        check(!snapshot(unknown).statusDetail.contains("arbitrary"), "raw message never presented")

        var active = status(.sending)
        active["cleanupVerified"] = false
        active["sends"] = 1
        let sending = snapshot(active)
        check(sending.phase == .sending && sending.canCancel && !sending.canStart, "active actions")
        check(sending.sessionID?.uuidString == id, "UUID decoded")
        check(!sending.needsRecovery, "unexpired active session is not stale recovery")

        var ack = active
        ack["phase"] = "acknowledged"
        ack["ackMatched"] = true
        ack["messageCode"] = "userVerified"
        let ackWithoutCleanup = snapshot(ack)
        check(ackWithoutCleanup.phase == .acknowledged, "ACK alone stays acknowledged")
        check(ackWithoutCleanup.statusTitle == "sleepSync.status.acknowledged", "optimistic code cannot claim success")
        check(!ackWithoutCleanup.canStart, "ACK does not unlock a second send")
        var unmatched = ack
        unmatched["ackMatched"] = false
        check(snapshot(unmatched).needsRecovery, "acknowledged phase requires a matched ACK")
        unmatched = ack
        unmatched["sends"] = 0
        check(snapshot(unmatched).needsRecovery, "matched ACK requires exactly one send")

        var finished = ack
        finished["phase"] = "finished"
        let dirtyFinished = snapshot(finished)
        check(dirtyFinished.needsRecovery && !dirtyFinished.canStart, "finished without cleanup requires recovery")
        check(dirtyFinished.statusTitle == "sleepSync.status.recoveryRequired", "no dirty success title")

        finished["cleanupVerified"] = true
        let protocolOnly = snapshot(finished)
        check(protocolOnly.phase == .finished, "finished after cleanup")
        check(protocolOnly.statusTitle == "sleepSync.status.protocolConfirmed", "ACK plus cleanup is only protocol confirmation")
        check(protocolOnly.canStart && !protocolOnly.userVerified, "clean completed session may start a new session")
        finished["userVerified"] = true
        let verified = snapshot(finished)
        check(verified.statusTitle == "sleepSync.status.userVerified", "explicit user verification shown")
        check(verified.statusDetail == "sleepSync.detail.userVerified", "detail is a key")
        finished["ackMatched"] = false
        check(snapshot(finished).phase != .finished, "user flag cannot replace ACK")

        var expired = active
        expired["deadline"] = now.timeIntervalSince1970
        let stale = snapshot(expired)
        check(stale.needsRecovery && !stale.canStart && !stale.canCancel, "deadline boundary requires recovery")
        check(stale.messageCode == .deadlineExceeded && !stale.cleanupVerified, "expiry does not fake cleanup")

        for key in ["sessionID", "startedAt", "deadline"] {
            var malformed = active
            malformed.removeValue(forKey: key)
            check(snapshot(malformed).needsRecovery, "missing active \(key) requires recovery")
            malformed[key] = "malformed"
            check(snapshot(malformed).needsRecovery, "bad active \(key) requires recovery")
        }
        for date: Any in [true, Double.nan, Double.infinity] {
            var malformed = active
            malformed["deadline"] = date
            check(snapshot(malformed).needsRecovery, "invalid deadline rejected")
        }
        var reversed = active
        reversed["deadline"] = now.addingTimeInterval(-20)
        check(snapshot(reversed).needsRecovery, "reversed dates require recovery")
        reversed = active
        reversed["startedAt"] = now.addingTimeInterval(1)
        check(snapshot(reversed).needsRecovery, "future start rejected")
        var dateObjects = active
        dateObjects["startedAt"] = now.addingTimeInterval(-10)
        dateObjects["deadline"] = now.addingTimeInterval(60)
        check(snapshot(dateObjects) == sending, "native Dates and epoch seconds agree")

        for phase: WFSleepSyncSnapshot.Phase in [.cancelled, .failed, .finished] {
            var value = status(phase)
            value["cleanupVerified"] = false
            check(snapshot(value).needsRecovery, "unclean terminal \(phase) requires recovery")
        }
        var recovery = status(.recoveryRequired)
        recovery["cleanupVerified"] = true
        check(snapshot(recovery).needsRecovery && !snapshot(recovery).canStart, "explicit recovery is never auto-cleared")
        var noBackend = status()
        noBackend["backendAvailable"] = false
        check(snapshot(noBackend).phase == .unavailable, "unavailable backend disables start")
        noBackend = active
        noBackend["backendAvailable"] = false
        check(snapshot(noBackend).needsRecovery, "lost active backend requires recovery")

        let encoded = try JSONEncoder().encode(verified)
        for (phase, stage) in [(WFSleepSyncSnapshot.Phase.preparing, 1), (.identity, 2),
                               (.waitingForSave, 3), (.sending, 4), (.acknowledged, 4),
                               (.restoring, 5), (.finished, 6)] {
            var value = status(phase)
            value["cleanupVerified"] = phase == .finished
            if [.sending, .acknowledged, .finished].contains(phase) { value["sends"] = 1 }
            if [.acknowledged, .finished].contains(phase) { value["ackMatched"] = true }
            let result = snapshot(value)
            check(result.progressStage == stage, "workflow progress stage \(phase)")
            check(result.stageProgress == Float(stage) / 6, "workflow fraction \(phase)")
        }
        for phase in [WFSleepSyncSnapshot.Phase.idle, .cancelled, .failed, .recoveryRequired, .unavailable] {
            check(snapshot(status(phase)).stageProgress == nil, "no false completion on \(phase)")
        }
        check(dirtyFinished.stageProgress == nil, "unverified cleanup has no completed bar")
        check(stale.stageProgress == nil, "expired phase cannot show completed progress")
        for reason in ["noNativeSource", "sourceNotEligible", "ackNotObserved"] {
            var value = status(.failed)
            value["messageCode"] = reason
            if reason == "ackNotObserved" { value["sends"] = 1 }
            let result = snapshot(value)
            check(result.statusTitle == "sleepSync.status.\(reason)", "specific failure title")
            check(!result.ackMatched && result.cleanupVerified, "failure is not protocol success")
            value["phase"] = "preparing"
            value["sends"] = 0
            check(snapshot(value).statusTitle == "sleepSync.status.preparing", "failure code cannot override active phase")
        }
        let decoded = try JSONDecoder().decode(WFSleepSyncSnapshot.self, from: encoded)
        check(decoded == verified, "Codable terminal round trip")
        for json in ["{}", "null", "[]", "{\"phase\":\"idle\",\"backendAvailable\":1}"] {
            let value = try JSONDecoder().decode(WFSleepSyncSnapshot.self, from: Data(json.utf8))
            check(value.phase == .unavailable && !value.canStart, "malformed JSON status fails closed: \(json)")
        }
        var jsonActive = active
        jsonActive["startedAt"] = Date().addingTimeInterval(-120).timeIntervalSince1970
        jsonActive["deadline"] = Date().addingTimeInterval(-60).timeIntervalSince1970
        let staleData = try JSONSerialization.data(withJSONObject: jsonActive)
        let staleDecoded = try JSONDecoder().decode(WFSleepSyncSnapshot.self, from: staleData)
        check(staleDecoded.needsRecovery, "Codable reload rechecks active deadline")

        print("PASS: \(assertions) SleepSync Foundation host assertions; no device actions")
    }
}
