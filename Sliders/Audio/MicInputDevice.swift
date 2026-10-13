import AudioToolbox
import CoreAudio

/// One input device as the global mute sees it.
struct MicInputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let controls: MicControls
    let isBuiltIn: Bool
    /// An aggregate's active input sub-devices; empty for anything else.
    let inputMembers: [AudioObjectID]

    static func all() -> [MicInputDevice] {
        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        else { return [] }
        return ids.compactMap(MicInputDevice.init(id:))
    }

    init?(id: AudioObjectID) {
        let scope = kAudioDevicePropertyScopeInput
        // Sliders' own aggregates carry tapped app output on their input side,
        // not a microphone; muting them would silence per-app playback.
        guard id.channelCount(scope: scope) > 0,
              let device = AudioDevice(id: id),
              !device.isSlidersPlumbing
        else { return nil }
        var inputs: [AudioObjectID] = []
        if device.transport == kAudioDeviceTransportTypeAggregate {
            let members = (try? id.readArray(kAudioAggregateDevicePropertyActiveSubDeviceList,
                                             of: AudioObjectID.self)) ?? []
            inputs = members.filter { $0.channelCount(scope: scope) > 0 }
            // Tap-only aggregates (another app's per-app audio) have no
            // microphone in them.
            guard !inputs.isEmpty else { return nil }
        }
        self.id = id
        uid = device.uid
        name = device.name
        controls = Self.controls(of: id)
        isBuiltIn = device.transport == kAudioDeviceTransportTypeBuiltIn
        inputMembers = inputs
    }

    private static func controls(of id: AudioObjectID) -> MicControls {
        let scope = kAudioDevicePropertyScopeInput
        return MicControls(
            canMute: id.isSettable(kAudioDevicePropertyMute, scope: scope),
            canZeroGain: id.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        )
    }
}
