import Foundation

public struct AppTheme: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let background: String
    public let foreground: String
    public let cursor: String
    public let selectionBackground: String
    public let selectionForeground: String
    public let palette: [String]

    public init(
        id: String,
        name: String,
        background: String,
        foreground: String,
        cursor: String,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String]
    ) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }

    public var accent: String {
        palette[safe: 4] ?? "#339CFF"
    }

    public var secondaryAccent: String {
        palette[safe: 5] ?? accent
    }

    public var codeKeyword: String {
        palette[safe: 5] ?? accent
    }

    public var codeString: String {
        palette[safe: 2] ?? "#71D36F"
    }

    public var codeNumber: String {
        palette[safe: 6] ?? "#64D2FF"
    }

    public var codeBuiltin: String {
        palette[safe: 3] ?? "#FF9F40"
    }

    public var codeComment: String {
        palette[safe: 8] ?? "#8D939F"
    }

    public var isDark: Bool {
        guard let rgb = RGBHex(background) else {
            return true
        }

        return rgb.relativeLuminance < 0.45
    }

    public static let codexLight = AppTheme(
        id: "codex-light",
        name: "Codex",
        background: "#FFFFFF",
        foreground: "#1A1C1F",
        cursor: "#339CFF",
        selectionBackground: "#D9ECFF",
        selectionForeground: "#111315",
        palette: [
            "#F4F4F5", "#E5484D", "#2F9E44", "#D89B00",
            "#339CFF", "#8B5CF6", "#0EA5E9", "#3F444A",
            "#A4A9B2", "#D92D20", "#16A34A", "#CA8A04",
            "#2563EB", "#A855F7", "#0891B2", "#111315"
        ]
    )

    public static let codexDark = AppTheme(
        id: "codex-dark",
        name: "Codex",
        background: "#181818",
        foreground: "#FFFFFF",
        cursor: "#339CFF",
        selectionBackground: "#233850",
        selectionForeground: "#FFFFFF",
        palette: [
            "#111315", "#FF5F57", "#5CE27F", "#F5C66B",
            "#339CFF", "#B785FF", "#60D8FF", "#D7D7D9",
            "#6D7178", "#FF7A73", "#77F299", "#FFD98A",
            "#64B5FF", "#CB9DFF", "#86E7FF", "#FFFFFF"
        ]
    )

    public static let lightThemes: [AppTheme] = [
        codexLight,
        AppTheme(
            id: "github-light",
            name: "GitHub",
            background: "#FFFFFF",
            foreground: "#24292F",
            cursor: "#0969DA",
            selectionBackground: "#B6E3FF",
            selectionForeground: "#24292F",
            palette: [
                "#24292F", "#CF222E", "#116329", "#4D2D00",
                "#0969DA", "#8250DF", "#1B7C83", "#F6F8FA",
                "#57606A", "#A40E26", "#1A7F37", "#9A6700",
                "#218BFF", "#A475F9", "#3192AA", "#FFFFFF"
            ]
        )
    ]

    public static let darkThemes: [AppTheme] = [
        codexDark,
        AppTheme(
            id: "ayu-mirage",
            name: "Ayu Mirage",
            background: "#1F2430",
            foreground: "#CCCAC2",
            cursor: "#FFCC66",
            selectionBackground: "#409FFF",
            selectionForeground: "#1F2430",
            palette: ["#171B24", "#ED8274", "#87D96C", "#FACC6E", "#6DCBFA", "#DABAFA", "#90E1C6", "#C7C7C7", "#686868", "#F28779", "#D5FF80", "#FFD173", "#73D0FF", "#DFBFFF", "#95E6CB", "#FFFFFF"]
        ),
        AppTheme(
            id: "catppuccin-mocha",
            name: "Catppuccin Mocha",
            background: "#1E1E2E",
            foreground: "#CDD6F4",
            cursor: "#F5E0DC",
            selectionBackground: "#585B70",
            selectionForeground: "#CDD6F4",
            palette: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8", "#585B70", "#F37799", "#89D88B", "#EBD391", "#74A8FC", "#F2AEDE", "#6BD7CA", "#BAC2DE"]
        ),
        AppTheme(
            id: "dracula",
            name: "Dracula",
            background: "#282A36",
            foreground: "#F8F8F2",
            cursor: "#F8F8F2",
            selectionBackground: "#44475A",
            selectionForeground: "#FFFFFF",
            palette: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2", "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]
        ),
        AppTheme(
            id: "everforest-dark-hard",
            name: "Everforest Dark Hard",
            background: "#1E2326",
            foreground: "#D3C6AA",
            cursor: "#E69875",
            selectionBackground: "#4C3743",
            selectionForeground: "#D3C6AA",
            palette: ["#7A8478", "#E67E80", "#A7C080", "#DBBC7F", "#7FBBB3", "#D699B6", "#83C092", "#F2EFDF", "#A6B0A0", "#F85552", "#8DA101", "#DFA000", "#3A94C5", "#DF69BA", "#35A77C", "#FFFBEF"]
        ),
        AppTheme(
            id: "github-dark",
            name: "GitHub Dark",
            background: "#101216",
            foreground: "#8B949E",
            cursor: "#C9D1D9",
            selectionBackground: "#3B5070",
            selectionForeground: "#FFFFFF",
            palette: ["#000000", "#F78166", "#56D364", "#E3B341", "#6CA4F8", "#DB61A2", "#2B7489", "#FFFFFF", "#4D4D4D", "#F78166", "#56D364", "#E3B341", "#6CA4F8", "#DB61A2", "#2B7489", "#FFFFFF"]
        ),
        AppTheme(
            id: "gruvbox-dark",
            name: "Gruvbox Dark",
            background: "#282828",
            foreground: "#EBDBB2",
            cursor: "#EBDBB2",
            selectionBackground: "#665C54",
            selectionForeground: "#EBDBB2",
            palette: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984", "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]
        ),
        AppTheme(
            id: "nord",
            name: "Nord",
            background: "#2E3440",
            foreground: "#D8DEE9",
            cursor: "#ECEFF4",
            selectionBackground: "#ECEFF4",
            selectionForeground: "#4C566A",
            palette: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0", "#596377", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]
        ),
        AppTheme(
            id: "tokyonight-storm",
            name: "TokyoNight Storm",
            background: "#24283B",
            foreground: "#C0CAF5",
            cursor: "#C0CAF5",
            selectionBackground: "#364A82",
            selectionForeground: "#C0CAF5",
            palette: ["#1D202F", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6", "#4E5575", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]
        ),
        AppTheme(
            id: "monokai-pro",
            name: "Monokai Pro",
            background: "#2D2A2E",
            foreground: "#FCFCFA",
            cursor: "#C1C0C0",
            selectionBackground: "#5B595C",
            selectionForeground: "#FCFCFA",
            palette: ["#2D2A2E", "#FF6188", "#A9DC76", "#FFD866", "#FC9867", "#AB9DF2", "#78DCE8", "#FCFCFA", "#727072", "#FF6188", "#A9DC76", "#FFD866", "#FC9867", "#AB9DF2", "#78DCE8", "#FCFCFA"]
        )
    ]

    public static func lightTheme(id: String) -> AppTheme {
        lightThemes.first { $0.id == id } ?? codexLight
    }

    public static func darkTheme(id: String) -> AppTheme {
        darkThemes.first { $0.id == id } ?? codexDark
    }
}

public struct RGBHex: Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init?(_ hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        guard value.count == 6, let intValue = Int(value, radix: 16) else {
            return nil
        }

        self.red = Double((intValue >> 16) & 0xFF) / 255.0
        self.green = Double((intValue >> 8) & 0xFF) / 255.0
        self.blue = Double(intValue & 0xFF) / 255.0
    }

    public var relativeLuminance: Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func linear(_ component: Double) -> Double {
        if component <= 0.03928 {
            return component / 12.92
        }

        return pow((component + 0.055) / 1.055, 2.4)
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
