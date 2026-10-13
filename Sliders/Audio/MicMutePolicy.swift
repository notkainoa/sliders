import Foundation

/// The HAL controls one input device exposes for silencing it.
struct MicControls: Equatable {
    var canMute: Bool
    var canZeroGain: Bool

    var isProtectable: Bool { canMute || canZeroGain }
}

/// What a device looked like before the global mute touched it. A nil field
/// was never changed and must not be written back on release.
struct MicRestoreState: Codable, Equatable {
    var wasMuted: Bool?
    var gain: Float?
}

/// A default-input switch made because the user's default can't be muted:
/// `from` gets the default back on release, but only while `to` still holds
/// it — a choice the user made in the meantime wins.
struct DefaultInputSwap: Codable, Equatable {
    var from: String
    var to: String
}

/// Everything the global mute persists. Kept across launches on purpose: a
/// crash or update relaunch must leave the microphones muted (fail closed),
/// and the next instance needs the restore states to undo exactly its own
/// changes.
struct MicMuteState: Codable, Equatable {
    var isEngaged = false
    var restore: [String: MicRestoreState] = [:]
    var defaultSwap: DefaultInputSwap?
}

/// Pure decisions behind the global microphone mute; the HAL side lives in
/// MicrophoneMute.
enum MicMutePolicy {
    enum Layer: Equatable {
        case mute
        case zeroGain
    }

    /// The locks to hold on a device. Mute is the primary one: the HAL keeps
    /// it across crashes and apps see clean silence. Gain at zero backs it up
    /// once something has taken the mute off behind our back, and stands in
    /// for devices with no mute control at all.
    static func layers(for controls: MicControls, tampered: Bool) -> [Layer] {
        if controls.canMute {
            return tampered && controls.canZeroGain ? [.mute, .zeroGain] : [.mute]
        }
        return controls.canZeroGain ? [.zeroGain] : []
    }

    /// Records a device's pre-mute value for a layer. Never overwrites: once
    /// muted, the device reads back our own state, and recording that would
    /// make release a no-op.
    static func record(_ layer: Layer, currentMute: Bool?, currentGain: Float?,
                       into existing: MicRestoreState?) -> MicRestoreState {
        var state = existing ?? MicRestoreState()
        switch layer {
        case .mute:
            if state.wasMuted == nil { state.wasMuted = currentMute ?? false }
        case .zeroGain:
            if state.gain == nil, let currentGain { state.gain = currentGain }
        }
        return state
    }

    struct Candidate: Equatable {
        let uid: String
        let isProtectable: Bool
        let isBuiltIn: Bool
    }

    /// The device to make the default input while muted, or nil to leave the
    /// default alone. Apps that follow the default would otherwise keep
    /// hearing a device the HAL can't silence. Built-in first: it is always
    /// there and never a surprise.
    static func substituteDefault(currentUID: String?, candidates: [Candidate]) -> String? {
        guard let currentUID,
              let current = candidates.first(where: { $0.uid == currentUID }),
              !current.isProtectable
        else { return nil }
        let protectable = candidates.filter(\.isProtectable)
        return (protectable.first(where: \.isBuiltIn) ?? protectable.first)?.uid
    }
}

/// Persists MicMuteState as one JSON blob in UserDefaults.
struct MicMuteStore {
    private static let key = "micMute"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MicMuteState {
        defaults.loadJSON(MicMuteState.self, forKey: Self.key) ?? MicMuteState()
    }

    func save(_ state: MicMuteState) {
        defaults.saveJSON(state, forKey: Self.key)
    }
}
