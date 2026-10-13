import SwiftUI

/// The default input's name and gain slider, under the mute tile on the
/// microphone tab.
struct InputVolumeSection: View {
    @Environment(MixerEngine.self) private var engine

    var body: some View {
        let inputVolume = engine.inputVolume
        // The global mute owns every input while engaged; gain and the
        // per-device mute would only be overridden, so they freeze.
        let globallyMuted = engine.micMute.isEngaged
        // Before start() the controller has no device behind it yet, and
        // every write would fail.
        let live = engine.isStarted && !globallyMuted
        let editable = live && inputVolume.canSetVolume
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Input")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(inputVolume.deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Input gain is absent or read-only on plenty of devices (gain
            // knob lives in hardware) — a live-looking slider that snaps back
            // reads as broken, so it dims and freezes instead.
            ControlSlider(
                value: Binding(
                    get: { inputVolume.volume },
                    set: { inputVolume.setVolume($0) }
                ),
                icon: inputVolume.isMuted || globallyMuted ? "mic.slash.fill" : "mic.fill",
                iconDimmed: inputVolume.isMuted,
                iconColor: globallyMuted ? .red : nil,
                onIconTap: live && inputVolume.canMute ? { inputVolume.toggleMute() } : nil
            )
            .disabled(!editable)
            .opacity(editable ? 1.0 : 0.5)
            if !inputVolume.canSetVolume, !globallyMuted {
                Text("Gain is controlled on the device")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
