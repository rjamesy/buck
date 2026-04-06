import Foundation

enum ANSIStripper {
    /// Remove ANSI escape sequences from text
    static func strip(_ text: String) -> String {
        // Match ESC[ followed by any number of params and a command letter
        // Also match ESC] (OSC) sequences terminated by BEL or ST
        guard let regex = try? NSRegularExpression(
            pattern: "\u{1b}\\[[0-9;]*[a-zA-Z]|\u{1b}\\][^\u{07}]*(?:\u{07}|\u{1b}\\\\)|\u{1b}[()][AB012]",
            options: []
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
