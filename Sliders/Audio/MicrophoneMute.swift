import AudioToolbox
import CoreAudio
import Observation
import os

/// One-click mute for every microphone at once, enforced at the HAL device
/// level so it covers every app — including ones that pick a non-default
/// input. While engaged, every input device is held muted: a new device is
/// muted the moment it appears, and a mute something else takes off is put
/// back in the same main-queue turn and backed by gain at zero from then on.
/// A device the HAL can't silence is named in `unprotectedDeviceNames`, and
/// stops being the default input while the mute lasts.
///
/// Fails closed: the HAL keeps a device's mute when this process dies, and the
/// engaged state persists, so a crash or update relaunch never opens the
/// microphones. A normal quit hands them back exactly as they were.
@MainActor
@Observable
final class MicrophoneMute {
    private static let logger = Logger(subsystem: "me.kainoa.sliders", category: "MicrophoneMute")
    /// Backstop for drivers that change mute without a property notification.
    /// Listeners are the primary path; this only bounds the worst case.
    private static let watchdogInterval: Duration = .seconds(2)

    private(set) var isEngaged = false
    /// Present input devices still live: no mute or gain control, or every
    /// write to them refused.
    private(set) var unprotectedDeviceNames: [String] = []
    /// False until start() has read the persisted state and the HAL.
    private(set) var isReady = false

    @ObservationIgnored private let store: MicMuteStore
    @ObservationIgnored private var state = MicMuteState()
    @ObservationIgnored private var savedState = MicMuteState()
    /// Devices whose mute came off while engaged; they get the gain lock too.
    @ObservationIgnored private var tampered: Set<String> = []
    /// Writes currently being refused, already logged once.
    @ObservationIgnored private var failing: Set<String> = []
    @ObservationIgnored private var systemListeners: [HALListener] = []
    @ObservationIgnored private var deviceListeners: [AudioObjectID: [HALListener]] = [:]
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    init(store: MicMuteStore = MicMuteStore()) {
        self.store = store
    }

    #if RENDER_SHOTS
        /// Render harness only: publish mute state without touching the HAL.
        func seedForRender(isEngaged: Bool, unprotectedDeviceNames: [String] = []) {
            self.isEngaged = isEngaged
            self.unprotectedDeviceNames = unprotectedDeviceNames
            isReady = true
        }
    #endif

    func start() {
        state = store.load()
        savedState = state
        isEngaged = state.isEngaged
        installSystemListeners()
        reconcile()
        isReady = true
    }

    func toggle() {
        setEngaged(!isEngaged)
    }

    func setEngaged(_ engaged: Bool) {
        guard isReady, engaged != state.isEngaged else { return }
        state.isEngaged = engaged
        isEngaged = engaged
        if !engaged { tampered.removeAll() }
        Self.logger.info("Microphones \(engaged ? "muted" : "unmuted", privacy: .public)")
        reconcile()
    }

    /// A normal quit returns every microphone to how it was, so none stays
    /// silent with nothing on screen to explain it. The engaged flag stays
    /// persisted: the next launch mutes again, the red icon says so.
    func releaseForQuit() {
        // Not ready means the launch probe hasn't heard back from coreaudiod:
        // a HAL call now could hang the quit. Whatever a previous run left
        // muted stays muted (fail closed), and the next launch picks it up.
        guard isReady else { return }
        stopWatchdog()
        systemListeners.removeAll()
        deviceListeners.removeAll()
        release(MicInputDevice.all())
        persist()
    }

    /// Core Audio reset: every listener and object ID is stale, and devices
    /// may come back with their mute cleared.
    func recoverAfterServiceRestart() {
        guard isReady else { return }
        systemListeners.removeAll()
        deviceListeners.removeAll()
        installSystemListeners()
        reconcile()
    }

    /// Wake and Bluetooth profile switches can republish devices unmuted.
    func resync() {
        guard isReady else { return }
        reconcile()
    }

    // MARK: - Reconcile

    private func installSystemListeners() {
        // HALListener delivers on the main queue. Acting in the same turn,
        // without a Task hop, keeps a fresh device's live window as short as
        // the HAL allows.
        let onChange: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        systemListeners = [
            AudioObjectID.system.listen(kAudioHardwarePropertyDevices, onChange: onChange),
            AudioObjectID.system.listen(kAudioHardwarePropertyDefaultInputDevice, onChange: onChange),
        ]
    }

    private func reconcile() {
        if state.isEngaged {
            let devices = MicInputDevice.all()
            var silenced = Set(devices.filter { hold($0) }.map(\.id))
            // An aggregate with no working control of its own is silent
            // through its members, and only while every one of them is.
            for device in devices where !silenced.contains(device.id) && !device.inputMembers.isEmpty
                && device.inputMembers.allSatisfy(silenced.contains) {
                silenced.insert(device.id)
            }
            let open = Set(devices.filter { !silenced.contains($0.id) }.map(\.uid))
            swapDefaultIfUnprotected(devices, open: open)
            publishUnprotected(devices.filter { open.contains($0.uid) }.map(\.name))
            watch(devices)
            startWatchdog()
        } else {
            deviceListeners.removeAll()
            publishUnprotected([])
            // Nothing pending (the usual case): skip enumerating devices on
            // every hotplug.
            var stuck = false
            if !state.restore.isEmpty || state.defaultSwap != nil {
                stuck = release(MicInputDevice.all())
            }
            // A present device that refused its restore is retried until it
            // takes; an absent one is restored when the device list changes.
            if stuck { startWatchdog() } else { stopWatchdog() }
        }
        persist()
    }

    /// Applies the device's own locks; false when none of them is in force,
    /// so the device is live unless its members cover it.
    private func hold(_ device: MicInputDevice) -> Bool {
        let endpoint = VolumeEndpoint(deviceID: device.id, scope: kAudioDevicePropertyScopeInput)
        let recorded = state.restore[device.uid]
        let currentMute = endpoint.readMute()
        let currentGain = endpoint.readVolume()

        // A layer we already hold that reads open again was undone by
        // something else (an app, a driver reset, a profile switch).
        let muteBreached = recorded?.wasMuted != nil && currentMute == false
        let gainBreached = recorded?.gain != nil && (currentGain ?? 0) > 0
        if muteBreached || gainBreached { escalate(device, reason: "was undone") }

        var silenced = false
        let layers = MicMutePolicy.layers(for: device.controls, tampered: tampered.contains(device.uid))
        for layer in layers {
            if apply(layer, to: device, endpoint: endpoint, currentMute: currentMute, currentGain: currentGain) {
                silenced = true
            } else if layer == .mute {
                escalate(device, reason: "refused the mute")
            }
        }
        // A refused mute gets the gain lock in this same pass, not 2 s later.
        let added = MicMutePolicy.layers(for: device.controls, tampered: tampered.contains(device.uid))
            .filter { !layers.contains($0) }
        for layer in added
            where apply(layer, to: device, endpoint: endpoint, currentMute: currentMute, currentGain: currentGain) {
            silenced = true
        }
        return silenced
    }

    private func escalate(_ device: MicInputDevice, reason: String) {
        guard tampered.insert(device.uid).inserted else { return }
        Self.logger.warning("""
        \(device.name) \(reason); \(device.controls.canZeroGain
            ? "holding it with gain at zero too" : "it has no gain control to fall back on")
        """)
    }

    /// True when the layer is in force: already set, or written successfully.
    private func apply(_ layer: MicMutePolicy.Layer, to device: MicInputDevice, endpoint: VolumeEndpoint,
                       currentMute: Bool?, currentGain: Float?) -> Bool {
        let unreadable = "\(device.uid) \(layer) read"
        let failure = "\(device.uid) \(layer) write"
        guard let next = MicMutePolicy.record(layer, currentMute: currentMute, currentGain: currentGain,
                                              into: state.restore[device.uid])
        else {
            noteFailure(unreadable, "Can't read \(device.name) before changing it; leaving that control alone")
            return false
        }
        clearFailure(unreadable)
        if next != state.restore[device.uid] {
            state.restore[device.uid] = next
            // Before the HAL write: a crash between the two must still leave
            // the original value on disk to restore.
            persist()
        }
        let inForce = switch layer {
        case .mute: currentMute == true || endpoint.writeMute(true) != nil
        case .zeroGain: currentGain == 0 || endpoint.writeVolume(0) != nil
        }
        if inForce {
            clearFailure(failure)
        } else {
            noteFailure(failure, "Failed to \(layer == .mute ? "mute" : "zero gain on") \(device.name)")
        }
        return inForce
    }

    /// The watchdog retries a refused write every couple of seconds for as
    /// long as it is refused; one log line per failure, not one per retry.
    private func noteFailure(_ key: String, _ message: String) {
        guard failing.insert(key).inserted else { return }
        Self.logger.error("\(message)")
    }

    private func clearFailure(_ key: String) {
        failing.remove(key)
    }

    /// Writes back what each present device had before the mute. A device
    /// that refuses keeps its record and is retried on the next reconcile;
    /// an absent one is restored when it returns. True when something
    /// present refused, so the watchdog must keep retrying.
    @discardableResult
    private func release(_ devices: [MicInputDevice]) -> Bool {
        for device in devices {
            guard let saved = state.restore[device.uid] else { continue }
            let endpoint = VolumeEndpoint(deviceID: device.id, scope: kAudioDevicePropertyScopeInput)
            // Gain before mute: unmuting first would open the mic at zero
            // gain and then jump.
            let gainRestored = saved.gain.map { endpoint.writeVolume($0) != nil } ?? true
            let muteRestored = saved.wasMuted.map { endpoint.writeMute($0) != nil } ?? true
            if gainRestored, muteRestored {
                state.restore[device.uid] = nil
                clearFailure("\(device.uid) restore")
            } else {
                noteFailure("\(device.uid) restore", "Failed to restore \(device.name)")
            }
        }
        let defaultRefused = restoreDefault(devices)
        return defaultRefused || devices.contains { state.restore[$0.uid] != nil }
    }
}

// MARK: - Default input

extension MicrophoneMute {
    /// `open` holds the devices still live after hold(): no controls, or
    /// controls that refused every write.
    private func swapDefaultIfUnprotected(_ devices: [MicInputDevice], open: Set<String>) {
        guard let currentID = try? AudioObjectID.readDefaultDevice(.input),
              let current = devices.first(where: { $0.id == currentID })
        else { return }
        let candidates = devices.map {
            MicMutePolicy.Candidate(uid: $0.uid, isProtectable: !open.contains($0.uid), isBuiltIn: $0.isBuiltIn)
        }
        guard let targetUID = MicMutePolicy.substituteDefault(currentUID: current.uid, candidates: candidates),
              let target = devices.first(where: { $0.uid == targetUID })
        else { return }
        do {
            try AudioObjectID.system.write(kAudioHardwarePropertyDefaultInputDevice, value: target.id)
            // The current default is the latest choice even mid-swap: ours
            // is protectable, so landing here again means someone picked
            // another unprotectable device since, and that pick is the one
            // to give back.
            state.defaultSwap = DefaultInputSwap(from: current.uid, to: target.uid)
            clearFailure("default swap")
            Self.logger.info("\(current.name) can't be muted; default input moved to \(target.name)")
        } catch {
            noteFailure("default swap",
                        "Failed to move default input off \(current.name): \(error.localizedDescription)")
        }
    }

    /// Gives the default input back once `from` is present. The swap record
    /// is dropped only when that succeeds or the default has moved off `to`
    /// (a choice made since wins); otherwise it waits for a retry. Returns
    /// true when the HAL couldn't be read or refused the write, so the
    /// caller keeps retrying.
    private func restoreDefault(_ devices: [MicInputDevice]) -> Bool {
        // Read the default's identity straight from the HAL: `devices` can
        // briefly leave it out (a channel count reading 0 mid-reconnect), and
        // that must not pass for the user having picked something else.
        guard let swap = state.defaultSwap else { return false }
        // Unreadable is indeterminate: keep the record and retry.
        guard let currentID = try? AudioObjectID.readDefaultDevice(.input),
              let currentUID = try? currentID.readDeviceUID()
        else { return true }
        guard currentUID == swap.to else {
            state.defaultSwap = nil
            return false
        }
        // Absent: the device-list listener brings us back when it returns.
        guard let from = devices.first(where: { $0.uid == swap.from }) else { return false }
        do {
            try AudioObjectID.system.write(kAudioHardwarePropertyDefaultInputDevice, value: from.id)
            state.defaultSwap = nil
            clearFailure("default restore")
            return false
        } catch {
            noteFailure("default restore", "Failed to give the default input back to \(from.name)")
            return true
        }
    }

    // MARK: - Watching

    private func watch(_ devices: [MicInputDevice]) {
        let present = Set(devices.map(\.id))
        for id in deviceListeners.keys where !present.contains(id) {
            deviceListeners[id] = nil
        }
        for device in devices where deviceListeners[device.id] == nil {
            let id = device.id
            let onChange: @Sendable () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.enforce(id) }
            }
            deviceListeners[id] = [
                id.listen(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput, onChange: onChange),
                id.listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                          scope: kAudioDevicePropertyScopeInput, onChange: onChange),
            ]
        }
    }

    private func enforce(_ id: AudioObjectID) {
        guard state.isEngaged, let device = MicInputDevice(id: id) else { return }
        guard hold(device) else {
            // Newly live: the warning and the default-input swap both need
            // the full device picture.
            reconcile()
            return
        }
        persist()
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.watchdogInterval, tolerance: .seconds(1))
                } catch {
                    return
                }
                // reconcile() stops the watchdog once nothing needs it.
                guard let self else { return }
                reconcile()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - State

    private func publishUnprotected(_ names: [String]) {
        if names != unprotectedDeviceNames { unprotectedDeviceNames = names }
    }

    private func persist() {
        guard state != savedState else { return }
        store.save(state)
        savedState = state
    }
}
