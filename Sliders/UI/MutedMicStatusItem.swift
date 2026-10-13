import AppKit
import Observation

/// A second menu bar icon, present only while every microphone is muted: a
/// red slashed mic beside the Sliders mark, visible from any app. A click
/// opens a menu instead of unmuting straight away — opening the microphones
/// should take a deliberate choice, never a stray click.
///
/// The item is created once and then only shown and hidden. Removing a
/// status item clears its saved position, so a re-created one comes back as
/// a brand-new item — placed at the far left of the status area, which is
/// under the notch on a crowded menu bar and inside the hidden section of
/// managers like Ice, Bartender or Thaw. A fixed autosave name keeps the
/// position across mutes and launches, including one the user drags it to.
@MainActor
final class MutedMicStatusItem: NSObject, NSMenuDelegate {
    private static let autosaveName = "MicrophonesMuted"

    private let micMute: MicrophoneMute
    private var item: NSStatusItem?

    init(micMute: MicrophoneMute) {
        self.micMute = micMute
    }

    func install() {
        update()
        observe()
    }

    /// The Sliders right-click monitor must leave this item's clicks alone.
    func owns(_ window: NSWindow?) -> Bool {
        guard let window, let own = item?.button?.window else { return false }
        return window === own
    }

    private func observe() {
        withObservationTracking {
            _ = micMute.isEngaged
            _ = micMute.unprotectedDeviceNames
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        guard micMute.isEngaged else {
            item?.isVisible = false
            return
        }
        let item = item ?? makeItem()
        self.item = item
        item.isVisible = true
        let status = micMute.unprotectedDeviceNames.isEmpty
            ? "Microphones muted"
            : "Microphones muted, except \(micMute.unprotectedDeviceNames.joined(separator: ", "))"
        item.button?.toolTip = status
        item.button?.setAccessibilityLabel(status)
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Setting the name re-reads the saved position and visibility. The
        // visibility is only ever our own hide from the last unmute, and
        // restoring it would keep the item hidden while muted, so drop it
        // and keep just the position.
        for key in ["Visible", "VisibleCC"] {
            UserDefaults.standard.removeObject(forKey: "NSStatusItem \(key) \(Self.autosaveName)")
        }
        item.autosaveName = Self.autosaveName
        item.button?.image = Self.icon
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        return item
    }

    /// Not a template: the red is the point, and must survive menu bar tinting.
    private static let icon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphones muted")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The status bar window is pinned dark; without this the menu
        // inherits that and ignores the system theme.
        menu.appearance = NSApp.effectiveAppearance

        let header = NSMenuItem(title: "All Mics Muted", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for name in micMute.unprotectedDeviceNames {
            let warning = NSMenuItem(title: "\(name) can't be muted", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)
            menu.addItem(warning)
        }
        menu.addItem(.separator())

        let unmute = NSMenuItem(title: "Unmute All Mics", action: #selector(unmute), keyEquivalent: "")
        unmute.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        unmute.target = self
        menu.addItem(unmute)
    }

    @objc private func unmute() {
        micMute.setEngaged(false)
    }
}
