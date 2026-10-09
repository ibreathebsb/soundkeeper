import AppKit
import SoundKeeperCore

/// Icons of the status bar item. They are template images made of SF Symbols, so they follow the menu bar colors.
public enum StatusIcon {
    /// All icons have the same size, and the speaker is at the same place in all of them. So nothing jumps in the
    /// menu bar when the state is changed.
    public static let size = NSSize(width: 22, height: 16)

    public static func image(for activity: AppModel.Activity) -> NSImage {
        let names: [String]
        switch activity {
        case .active: names = ["speaker.wave.2.fill"]
        case .idle: names = ["speaker.fill"]
        case .off: names = ["speaker.slash.fill"]
        case .problem: names = ["speaker.badge.exclamationmark.fill", "exclamationmark.triangle.fill"]
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        let symbol = names.lazy.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }.first

        let image = NSImage(size: size, flipped: false) { bounds in
            guard let symbol else { return false }

            // Symbols with a slash or a badge extend to the left of the speaker; plain speakers start at the left edge.
            let symbolSize = symbol.size
            let x = activity == .off ? (bounds.width - symbolSize.width) / 2 - 1.5 : 1
            let y = (bounds.height - symbolSize.height) / 2
            symbol.draw(in: NSRect(x: max(0, x), y: y, width: symbolSize.width, height: symbolSize.height))
            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = L("Sound Keeper")
        return image
    }

    public static func toolTip(for activity: AppModel.Activity, outputs: [String]) -> String {
        switch activity {
        case .off:
            return L("Sound Keeper is turned off")
        case .idle:
            return L("Sound Keeper: no output to keep awake")
        case .problem:
            return L("Sound Keeper: some output can't be kept awake")
        case .active:
            return L("Sound Keeper keeps awake: %@", outputs.joined(separator: ", "))
        }
    }
}

/// The item in the status bar.
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let model: AppModel

    public init(model: AppModel, menu: NSMenu) {
        self.model = model

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "SoundKeeper"
        statusItem.menu = menu
        refresh()

        // The system places the item a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            Log.debug("Status item: \(self.placement).")
        }
    }

    /// Where the item is in the menu bar, for diagnostics.
    public var placement: String {
        guard let window = statusItem.button?.window else { return "no window" }

        let frame = window.frame
        var details = ["frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"]
        details.append(window.screen != nil ? "on a screen" : "not on a screen")
        details.append(window.occlusionState.contains(.visible) ? "visible" : "not visible right now")
        if !statusItem.isVisible { details.append("hidden by the user") }
        return details.joined(separator: ", ")
    }

    public func refresh() {
        guard let button = statusItem.button else { return }

        let activity = model.activity
        let outputs = model.status.sessions.filter { $0.health == .active }.map(\.name)

        button.image = StatusIcon.image(for: activity)
        button.toolTip = StatusIcon.toolTip(for: activity, outputs: outputs)
    }

    /// Opens the menu, like a click on the icon does.
    public func showMenu() {
        statusItem.button?.performClick(nil)
    }
}
