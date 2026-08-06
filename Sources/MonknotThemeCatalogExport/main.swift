import Foundation
import MonknotCore

struct ThemeCatalogExport: Encodable {
    let sourceVersion: String
    let light: [ThemeExport]
    let dark: [ThemeExport]
}

struct ThemeExport: Encodable {
    let id: String
    let name: String
    let variant: MonknotThemeVariant
    let surface: String
    let ink: String
    let accent: String
    let selection: String
    let added: String
    let removed: String
    let skill: String
    let palette: [String]

    init(_ preset: MonknotThemePreset) {
        id = preset.id
        name = preset.theme.name
        variant = preset.variant
        surface = preset.theme.background
        ink = preset.theme.foreground
        accent = preset.theme.accent
        selection = preset.theme.selectionBackground
        added = preset.theme.semanticColors.diffAdded
        removed = preset.theme.semanticColors.diffRemoved
        skill = preset.theme.semanticColors.skill
        palette = preset.theme.palette
    }
}

let payload = ThemeCatalogExport(
    sourceVersion: MonknotThemeCatalog.sourceVersion,
    light: MonknotThemeCatalog.lightPresets.map(ThemeExport.init),
    dark: MonknotThemeCatalog.darkPresets.map(ThemeExport.init)
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

do {
    let data = try encoder.encode(payload)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Unable to export Monknot themes: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
