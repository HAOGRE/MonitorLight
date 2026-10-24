import Foundation

/// Looks up a user-facing string. Keys are the Simplified Chinese source text;
/// `en.lproj/Localizable.strings` translates them and the bundle follows the
/// system language (English for any language other than Chinese). There is
/// deliberately no in-app language switch.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Format variant: `L("%@未生效", title)`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: arguments)
}
