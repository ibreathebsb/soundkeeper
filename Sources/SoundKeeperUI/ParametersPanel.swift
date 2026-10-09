import AppKit
import SoundKeeperCore

/// The form with numeric parameters of the signal: frequency, amplitude, length, waiting, fading.
public final class ParametersForm {
    public let view: NSView

    private let settings: Settings
    private let frequency: NSTextField
    private let amplitude: NSTextField
    private let play: NSTextField
    private let wait: NSTextField
    private let fade: NSTextField

    public init(settings: Settings) {
        self.settings = settings

        func field(_ value: Double, enabled: Bool) -> NSTextField {
            let field = NSTextField(string: enabled ? formatNumber(value) : "")
            field.alignment = .right
            field.isEnabled = enabled
            field.placeholderString = enabled ? nil : "—"
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            return field
        }

        let stream = settings.stream
        frequency = field(settings.frequency, enabled: stream.usesFrequency)
        amplitude = field(settings.amplitudePercent, enabled: stream.usesAmplitude)
        play = field(settings.playSeconds, enabled: stream.hasParameters)
        wait = field(settings.waitSeconds, enabled: stream.hasParameters)
        fade = field(settings.fadeSeconds, enabled: stream.usesAmplitude)

        func label(_ text: String, secondary: Bool = false) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            if secondary {
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            }
            return label
        }

        let frequencyHint = stream == .fluctuate ? L("Hz — fluctuations per second") : L("Hz")
        let grid = NSGridView(views: [
            [label(L("Frequency:")), frequency, label(frequencyHint, secondary: true)],
            [label(L("Amplitude:")), amplitude, label(L("% — 0.1 is inaudible for a noise"), secondary: true)],
            [label(L("Length:")), play, label(L("seconds — 0 is infinite"), secondary: true)],
            [label(L("Waiting:")), wait, label(L("seconds between sounds, if the length is set"), secondary: true)],
            [label(L("Fading:")), fade, label(L("seconds"), secondary: true)],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.setFrameSize(grid.fittingSize)
        container.layoutSubtreeIfNeeded()
        view = container

        // Tab goes through the fields.
        let editable = [frequency, amplitude, play, wait, fade].filter(\.isEnabled)
        for (index, field) in editable.enumerated() {
            field.nextKeyView = editable[(index + 1) % editable.count]
        }
    }

    /// The first field that can be edited.
    public var initialFirstResponder: NSView? {
        [frequency, amplitude, play, wait, fade].first(where: \.isEnabled)
    }

    /// For tests: types text into fields. `nil` leaves a field as it is.
    public func enter(frequency: String? = nil, amplitude: String? = nil, play: String? = nil, wait: String? = nil, fade: String? = nil) {
        if let frequency { self.frequency.stringValue = frequency }
        if let amplitude { self.amplitude.stringValue = amplitude }
        if let play { self.play.stringValue = play }
        if let wait { self.wait.stringValue = wait }
        if let fade { self.fade.stringValue = fade }
    }

    /// The settings with what is entered in the form. Fields with something that is not a number are ignored.
    public var result: Settings {
        var result = settings
        if frequency.isEnabled, let value = Self.number(frequency.stringValue) { result.frequency = min(value, 96000) }
        if amplitude.isEnabled, let value = Self.number(amplitude.stringValue) { result.amplitudePercent = min(value, 100) }
        if play.isEnabled, let value = Self.number(play.stringValue) { result.playSeconds = value }
        if wait.isEnabled, let value = Self.number(wait.stringValue) { result.waitSeconds = value }
        if fade.isEnabled, let value = Self.number(fade.stringValue) { result.fadeSeconds = value }
        return result
    }

    /// A non-negative number. Both "0.5" and "0,5" are fine.
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

public enum ParametersPanel {
    /// Shows the panel. Returns changed settings, or nil if the panel is cancelled.
    public static func run(settings: Settings) -> Settings? {
        let form = ParametersForm(settings: settings)

        let alert = NSAlert()
        alert.messageText = L("Signal Parameters")
        alert.informativeText = L("Parameters of the signal that keeps your outputs awake. Fields that don't apply to the current signal type are disabled.")
        alert.accessoryView = form.view
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = form.initialFirstResponder

        // The app has no windows and no Dock icon, so it has to be activated to show a dialog.
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return form.result
    }
}
