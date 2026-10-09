import Foundation

/// Localized text. English texts are the keys, so the app works even without its resources (when the bare
/// executable is started). Translations are in Resources/*.lproj/Localizable.strings.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

/// "50", "0.1", "12.5": numbers the way they are shown in the menu.
func formatNumber(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
}
