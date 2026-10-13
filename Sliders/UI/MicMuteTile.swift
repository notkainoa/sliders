import SwiftUI

/// The microphone tab's lead control: one click mutes every input device for
/// every app. A tile rather than a small toggle — it is the one control on
/// the tab that decides whether anyone can hear you, so its state has to read
/// at a glance.
struct MicMuteTile: View {
    @Environment(MixerEngine.self) private var engine
    @State private var isHovering = false

    var body: some View {
        let micMute = engine.micMute
        let muted = micMute.isEngaged
        Button {
            micMute.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(muted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 28, height: 28)
                    .background(muted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(muted ? "Microphones Muted" : "Mute All Microphones")
                        .font(.system(size: 12, weight: .semibold))
                    subtitle(muted: muted, unprotected: micMute.unprotectedDeviceNames)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(background(muted: muted), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!micMute.isReady)
        .opacity(micMute.isReady ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .help(muted ? "Unmute every microphone" : "Mute every microphone for every app")
        .accessibilityLabel(muted ? "Unmute microphones" : "Mute all microphones")
    }

    @ViewBuilder
    private func subtitle(muted: Bool, unprotected: [String]) -> some View {
        if muted, !unprotected.isEmpty {
            // Never claim a silence the HAL can't deliver.
            Label(unprotected.count == 1
                ? "\(unprotected[0]) can't be muted"
                : "\(unprotected.count) microphones can't be muted",
                systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(unprotected.joined(separator: ", "))
        } else {
            Text(muted ? "Apps hear silence · Click to unmute" : "Every app, every input device")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func background(muted: Bool) -> AnyShapeStyle {
        if muted {
            return AnyShapeStyle(Color.red.opacity(isHovering ? 0.2 : 0.14))
        }
        return isHovering
            ? AnyShapeStyle(Color(nsColor: .tertiarySystemFill))
            : AnyShapeStyle(Color(nsColor: .quaternarySystemFill))
    }
}
