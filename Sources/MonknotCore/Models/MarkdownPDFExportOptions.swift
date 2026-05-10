import CoreGraphics
import Foundation

public struct MarkdownPDFExportOptions: Codable, Equatable, Sendable {
    public var pageSize: MarkdownPDFPageSize = .automatic
    public var marginPreset: MarkdownPDFMarginPreset = .normal
    public var themeMode: MarkdownPDFThemeMode = .current
    public var scalePercent: Double = 100

    private enum CodingKeys: String, CodingKey {
        case pageSize
        case marginPreset
        case themeMode
        case scalePercent
    }

    public init(
        pageSize: MarkdownPDFPageSize = .automatic,
        marginPreset: MarkdownPDFMarginPreset = .normal,
        themeMode: MarkdownPDFThemeMode = .current,
        scalePercent: Double = 100
    ) {
        self.pageSize = pageSize
        self.marginPreset = marginPreset
        self.themeMode = themeMode
        self.scalePercent = Self.clampedScale(scalePercent)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageSize = try container.decodeIfPresent(MarkdownPDFPageSize.self, forKey: .pageSize) ?? .automatic
        marginPreset = try container.decodeIfPresent(MarkdownPDFMarginPreset.self, forKey: .marginPreset) ?? .normal
        themeMode = try container.decodeIfPresent(MarkdownPDFThemeMode.self, forKey: .themeMode) ?? .current
        scalePercent = Self.clampedScale(try container.decodeIfPresent(Double.self, forKey: .scalePercent) ?? 100)
    }

    public var resolvedScale: Double {
        Self.clampedScale(scalePercent) / 100
    }

    public static func loadLastUsed(defaults: UserDefaults = .standard) -> MarkdownPDFExportOptions {
        guard
            let data = defaults.data(forKey: Keys.lastUsed),
            let options = try? JSONDecoder().decode(MarkdownPDFExportOptions.self, from: data)
        else {
            return MarkdownPDFExportOptions()
        }
        return options
    }

    public func saveLastUsed(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Keys.lastUsed)
    }

    private enum Keys {
        static let lastUsed = "Monknot.markdownPDFExportOptions"
    }

    private static func clampedScale(_ value: Double) -> Double {
        min(180, max(70, value))
    }
}

public enum MarkdownPDFPageSize: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case a4
    case letter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic:
            return "Auto"
        case .a4:
            return "A4"
        case .letter:
            return "Letter"
        }
    }

    public func resolved(locale: Locale = .current) -> CGSize {
        switch self {
        case .a4:
            return CGSize(width: 595, height: 842)
        case .letter:
            return CGSize(width: 612, height: 792)
        case .automatic:
            return locale.region?.identifier == "US"
                ? MarkdownPDFPageSize.letter.resolved(locale: locale)
                : MarkdownPDFPageSize.a4.resolved(locale: locale)
        }
    }
}

public enum MarkdownPDFMarginPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case normal
    case compact

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal:
            return "Normal"
        case .compact:
            return "Compact"
        }
    }

    public var points: CGFloat {
        switch self {
        case .normal:
            return 48
        case .compact:
            return 28
        }
    }
}

public enum MarkdownPDFThemeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case current
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .current:
            return "Current"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}
