import Foundation
import CoreFoundation

/// A read-only projection of the manual Sleep sync backend status. No device actions.
struct WFSleepSyncSnapshot: Codable, Equatable {
    enum Phase: String, Codable, CaseIterable {
        case idle, preparing, identity, waitingForSave, sending, acknowledged
        case restoring, finished, cancelled, failed, recoveryRequired, unavailable

        var isActive: Bool {
            switch self {
            case .preparing, .identity, .waitingForSave, .sending, .acknowledged, .restoring:
                return true
            default:
                return false
            }
        }
    }

    /// Only these codes cross the presentation boundary; arbitrary backend text is discarded.
    enum MessageCode: String, Codable, CaseIterable {
        case none, idle, preparing, identity, waitingForSave, sending, acknowledged
        case restoring, finished, cancelled, failed, recoveryRequired, unavailable
        case invalidStatus, deadlineExceeded, protocolConfirmed, userVerified
        case noNativeSource, sourceNotEligible, ackNotObserved
    }

    let sessionID: UUID?
    let phase: Phase
    let messageCode: MessageCode
    let startedAt: Date?
    let deadline: Date?
    let ackMatched: Bool
    let userVerified: Bool
    let cleanupVerified: Bool
    let backendAvailable: Bool
    let sends: Int

    /// Wire contract: UUID string; Date or finite Unix seconds; actual booleans;
    /// sends is an integer 0 or 1. All flags, phase, messageCode and sends are required.
    /// Session ID and both dates are required for every session-bearing phase.
    /// `now` is injectable for deterministic host tests. Expiry never manufactures cleanup.
    init(dictionary: [String: Any], now: Date = Date()) {
        let inputPhase = (dictionary["phase"] as? String).flatMap(Phase.init(rawValue:))
        let inputMessage = (dictionary["messageCode"] as? String).flatMap(MessageCode.init(rawValue:))
        let inputACK = Self.boolean(dictionary["ackMatched"])
        let inputUser = Self.boolean(dictionary["userVerified"])
        let inputCleanup = Self.boolean(dictionary["cleanupVerified"])
        let inputBackend = Self.boolean(dictionary["backendAvailable"])
        let inputSends = Self.sendCount(dictionary["sends"])

        sessionID = (dictionary["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        startedAt = Self.date(dictionary["startedAt"])
        deadline = Self.date(dictionary["deadline"])
        ackMatched = inputACK ?? false
        userVerified = inputUser ?? false
        cleanupVerified = inputCleanup ?? false
        backendAvailable = inputBackend ?? false
        sends = inputSends ?? 0

        let sessionBearing = inputPhase.map { $0 != .idle && $0 != .unavailable } ?? false
        let sessionEvidence = sessionBearing || dictionary["sessionID"] != nil
        let unsafeSession = sessionEvidence && !cleanupVerified
        let fallback: Phase = (inputPhase?.isActive == true || inputPhase == .recoveryRequired || unsafeSession)
            ? .recoveryRequired : .unavailable

        var valid = inputPhase != nil && inputMessage != nil && inputACK != nil
            && inputUser != nil && inputCleanup != nil && inputBackend != nil && inputSends != nil
            && now.timeIntervalSince1970.isFinite
        if sessionBearing {
            valid = valid && sessionID != nil && startedAt != nil && deadline != nil
            if let start = startedAt, let end = deadline {
                valid = valid && end > start && start <= now
            }
        } else {
            // Optional session fields must still be well formed if supplied.
            for (key, parsed) in [("sessionID", sessionID != nil),
                                  ("startedAt", startedAt != nil), ("deadline", deadline != nil)] {
                if let value = dictionary[key], !(value is NSNull), !parsed { valid = false }
            }
        }
        if ackMatched && sends != 1 { valid = false }
        if userVerified && (inputPhase != .finished || !ackMatched || !cleanupVerified || sends != 1) {
            valid = false
        }
        if let inputPhase, [.idle, .preparing, .identity, .waitingForSave].contains(inputPhase),
           sends != 0 || ackMatched {
            valid = false
        }
        if inputPhase == .acknowledged || inputPhase == .finished {
            if !ackMatched || sends != 1 { valid = false }
        }

        guard valid, let inputPhase, let inputMessage else {
            phase = fallback
            messageCode = .invalidStatus
            return
        }
        if inputPhase.isActive, let deadline, deadline <= now {
            phase = .recoveryRequired
            messageCode = .deadlineExceeded
        } else if inputPhase == .recoveryRequired {
            phase = .recoveryRequired
            messageCode = inputMessage
        } else if [.idle, .finished, .cancelled, .failed].contains(inputPhase), !cleanupVerified {
            phase = .recoveryRequired
            messageCode = .recoveryRequired
        } else if !backendAvailable {
            phase = inputPhase.isActive ? .recoveryRequired : .unavailable
            messageCode = .unavailable
        } else {
            phase = inputPhase
            messageCode = inputMessage
        }
    }

    var canStart: Bool {
        backendAvailable && cleanupVerified && [.idle, .finished, .cancelled, .failed].contains(phase)
    }

    var canCancel: Bool {
        backendAvailable && [.preparing, .identity, .waitingForSave, .sending, .acknowledged].contains(phase)
    }

    var needsRecovery: Bool { phase == .recoveryRequired }

    enum StepState: String { case pending, active, complete, unknown }
    struct ProgressStep {
        let key: String
        let state: StepState
    }

    /// Separate bars for actual workflow steps. No invented within-step percent.
    /// Cleanup on a failed run does not imply that saving/sending succeeded.
    var progressSteps: [ProgressStep] {
        let keys = ["prepare", "identity", "save", "send", "ack", "cleanup"]
        var states = Array(repeating: StepState.pending, count: keys.count)
        let current: Int?
        switch phase {
        case .preparing: current = 0
        case .identity: current = 1
        case .waitingForSave: current = 2
        case .sending: current = 4 // send attempt is recorded; waiting for ACK
        default: current = nil
        }
        if let current {
            for index in 0..<current { states[index] = .complete }
            states[current] = .active
        } else if phase == .acknowledged {
            for index in 0..<5 { states[index] = .complete }
        } else if phase == .finished {
            states = Array(repeating: .complete, count: keys.count)
        } else if [.restoring, .failed, .cancelled, .recoveryRequired].contains(phase) {
            states = Array(repeating: .unknown, count: keys.count)
            states[3] = sends == 1 ? .complete : .unknown
            states[4] = ackMatched ? .complete : .unknown
            states[5] = phase == .restoring ? .active : (cleanupVerified ? .complete : .unknown)
        }
        return zip(keys, states).map { ProgressStep(key: $0.0, state: $0.1) }
    }

    /// Stable localization keys, not already localized text. A matching ACK is not success.
    var statusTitle: String { "sleepSync.status.\(presentationCode.rawValue)" }
    var statusDetail: String { "sleepSync.detail.\(presentationCode.rawValue)" }

    private var presentationCode: MessageCode {
        if phase == .finished {
            return userVerified && ackMatched && cleanupVerified ? .userVerified : .protocolConfirmed
        }
        if phase == .failed, [.noNativeSource, .sourceNotEligible, .ackNotObserved].contains(messageCode) {
            return messageCode
        }
        // Do not let an optimistic messageCode override the actual phase.
        return MessageCode(rawValue: phase.rawValue) ?? .unavailable
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func sendCount(_ value: Any?) -> Int? {
        guard let number = number(value), number == 0 || number == 1 else { return nil }
        return Int(number)
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date.timeIntervalSince1970.isFinite ? date : nil
        }
        return number(value).map(Date.init(timeIntervalSince1970:))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, phase, messageCode, startedAt, deadline
        case ackMatched, userVerified, cleanupVerified, backendAvailable, sends
    }

    /// Codable uses Unix seconds irrespective of the caller's Date coding strategy.
    /// Malformed scalar fields take the same fail-closed path as bridge dictionaries.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(dictionary: [:])
            return
        }
        var dictionary: [String: Any] = [:]
        for key in [CodingKeys.sessionID, .phase, .messageCode] {
            if let value = try? container.decode(String.self, forKey: key) {
                dictionary[key.rawValue] = value
            } else if container.contains(key) {
                dictionary[key.rawValue] = NSNull()
            }
        }
        for key in [CodingKeys.ackMatched, .userVerified, .cleanupVerified, .backendAvailable] {
            if let value = try? container.decode(Bool.self, forKey: key) {
                dictionary[key.rawValue] = value
            }
        }
        for key in [CodingKeys.startedAt, .deadline, .sends] {
            if let value = try? container.decode(Double.self, forKey: key) {
                dictionary[key.rawValue] = value
            } else if container.contains(key) {
                dictionary[key.rawValue] = NSNull()
            }
        }
        self.init(dictionary: dictionary)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sessionID?.uuidString, forKey: .sessionID)
        try container.encode(phase, forKey: .phase)
        try container.encode(messageCode, forKey: .messageCode)
        try container.encodeIfPresent(startedAt?.timeIntervalSince1970, forKey: .startedAt)
        try container.encodeIfPresent(deadline?.timeIntervalSince1970, forKey: .deadline)
        try container.encode(ackMatched, forKey: .ackMatched)
        try container.encode(userVerified, forKey: .userVerified)
        try container.encode(cleanupVerified, forKey: .cleanupVerified)
        try container.encode(backendAvailable, forKey: .backendAvailable)
        try container.encode(sends, forKey: .sends)
    }
}
