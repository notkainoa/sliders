import Foundation
import Testing

@Suite("MicMutePolicy")
struct MicMutePolicyTests {
    private let both = MicControls(canMute: true, canZeroGain: true)
    private let muteOnly = MicControls(canMute: true, canZeroGain: false)
    private let gainOnly = MicControls(canMute: false, canZeroGain: true)
    private let none = MicControls(canMute: false, canZeroGain: false)

    @Test("mute alone until something undoes it")
    func muteFirst() {
        #expect(MicMutePolicy.layers(for: both, tampered: false) == [.mute])
        #expect(MicMutePolicy.layers(for: muteOnly, tampered: false) == [.mute])
    }

    @Test("a tampered device is also held at zero gain")
    func tamperEscalates() {
        #expect(MicMutePolicy.layers(for: both, tampered: true) == [.mute, .zeroGain])
        #expect(MicMutePolicy.layers(for: muteOnly, tampered: true) == [.mute])
    }

    @Test("gain stands in when there is no mute control")
    func gainFallback() {
        #expect(MicMutePolicy.layers(for: gainOnly, tampered: false) == [.zeroGain])
        #expect(MicMutePolicy.layers(for: none, tampered: true).isEmpty)
        #expect(!none.isProtectable)
    }

    @Test("records the pre-mute values")
    func recordsOriginal() {
        let muted = MicMutePolicy.record(.mute, currentMute: false, currentGain: 0.7, into: nil)
        #expect(muted == MicRestoreState(wasMuted: false, gain: nil))
        let both = MicMutePolicy.record(.zeroGain, currentMute: true, currentGain: 0.7, into: muted)
        #expect(both == MicRestoreState(wasMuted: false, gain: 0.7))
    }

    /// Once muted the device reads back our own state; re-recording would make
    /// release restore the mute instead of the user's original.
    @Test("never overwrites a recorded value")
    func keepsFirstRecord() {
        let original = MicRestoreState(wasMuted: false, gain: 0.7)
        #expect(MicMutePolicy.record(.mute, currentMute: true, currentGain: 0, into: original) == original)
        #expect(MicMutePolicy.record(.zeroGain, currentMute: true, currentGain: 0, into: original) == original)
    }

    @Test("a device that was already muted stays muted on release")
    func preservesUserMute() {
        let state = MicMutePolicy.record(.mute, currentMute: true, currentGain: nil, into: nil)
        #expect(state.wasMuted == true)
    }

    @Test("moves the default off an unmutable device, built-in first")
    func substitutesDefault() {
        let candidates = [
            MicMutePolicy.Candidate(uid: "iphone", isProtectable: false, isBuiltIn: false),
            MicMutePolicy.Candidate(uid: "usb", isProtectable: true, isBuiltIn: false),
            MicMutePolicy.Candidate(uid: "builtin", isProtectable: true, isBuiltIn: true),
        ]
        #expect(MicMutePolicy.substituteDefault(currentUID: "iphone", candidates: candidates) == "builtin")
        #expect(MicMutePolicy.substituteDefault(currentUID: "usb", candidates: candidates) == nil)
        #expect(MicMutePolicy.substituteDefault(currentUID: nil, candidates: candidates) == nil)
    }

    @Test("falls back to any mutable device, or leaves the default alone")
    func substituteFallbacks() {
        let noBuiltIn = [
            MicMutePolicy.Candidate(uid: "iphone", isProtectable: false, isBuiltIn: false),
            MicMutePolicy.Candidate(uid: "usb", isProtectable: true, isBuiltIn: false),
        ]
        #expect(MicMutePolicy.substituteDefault(currentUID: "iphone", candidates: noBuiltIn) == "usb")
        let nothingMutable = [MicMutePolicy.Candidate(uid: "iphone", isProtectable: false, isBuiltIn: false)]
        #expect(MicMutePolicy.substituteDefault(currentUID: "iphone", candidates: nothingMutable) == nil)
    }
}

@Suite("MicMuteStore")
struct MicMuteStoreTests {
    private func makeStore() throws -> MicMuteStore {
        let suite = "MicMuteStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return MicMuteStore(defaults: defaults)
    }

    @Test("defaults to unmuted with nothing to restore")
    func emptyLoad() throws {
        #expect(try makeStore().load() == MicMuteState())
    }

    /// The engaged flag and restore states must survive a relaunch: that is
    /// what keeps a crash or update from opening the microphones.
    @Test("round-trips the engaged state and restore records")
    func roundTrip() throws {
        let store = try makeStore()
        let state = MicMuteState(
            isEngaged: true,
            restore: ["mic": MicRestoreState(wasMuted: false, gain: 0.5)],
            defaultSwap: DefaultInputSwap(from: "iphone", to: "builtin")
        )
        store.save(state)
        #expect(store.load() == state)
    }
}
