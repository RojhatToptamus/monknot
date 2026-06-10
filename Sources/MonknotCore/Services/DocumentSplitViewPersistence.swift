import CryptoKit
import Foundation

public enum DocumentSplitViewPersistence: Sendable {
    private static let keyPrefix = "Monknot.markdownSplitView."
    private static let ratioKeyPrefix = "Monknot.markdownSplitRatio."
    private static let legacyGlobalKey = "Monknot.markdownSplitView"

    public static let defaultSourcePaneRatio = 0.5
    public static let minSourcePaneRatio = 0.25
    public static let maxSourcePaneRatio = 0.75

    public static func storageKey(forDocumentPath path: String) -> String {
        keyPrefix + pathHash(path)
    }

    public static func ratioStorageKey(forDocumentPath path: String) -> String {
        ratioKeyPrefix + pathHash(path)
    }

    public static func pathHash(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func isEnabled(forDocumentPath path: String, defaults: UserDefaults = .standard) -> Bool {
        let key = storageKey(forDocumentPath: path)
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return defaults.bool(forKey: legacyGlobalKey)
    }

    public static func setEnabled(_ enabled: Bool, forDocumentPath path: String, defaults: UserDefaults = .standard) {
        let key = storageKey(forDocumentPath: path)
        if defaults.object(forKey: key) != nil {
            guard defaults.bool(forKey: key) != enabled else { return }
        } else if defaults.bool(forKey: legacyGlobalKey) == enabled {
            return
        }

        defaults.set(enabled, forKey: key)
    }

    public static func sourcePaneRatio(forDocumentPath path: String, defaults: UserDefaults = .standard) -> Double {
        let key = ratioStorageKey(forDocumentPath: path)
        guard defaults.object(forKey: key) != nil else {
            return defaultSourcePaneRatio
        }
        return clampedSourcePaneRatio(defaults.double(forKey: key))
    }

    public static func setSourcePaneRatio(_ ratio: Double, forDocumentPath path: String, defaults: UserDefaults = .standard) {
        let key = ratioStorageKey(forDocumentPath: path)
        let clampedRatio = clampedSourcePaneRatio(ratio)
        if defaults.object(forKey: key) != nil {
            guard abs(defaults.double(forKey: key) - clampedRatio) > 0.0001 else { return }
        } else if abs(clampedRatio - defaultSourcePaneRatio) <= 0.0001 {
            return
        }

        defaults.set(clampedRatio, forKey: key)
    }

    public static func clampedSourcePaneRatio(_ ratio: Double) -> Double {
        min(maxSourcePaneRatio, max(minSourcePaneRatio, ratio))
    }

    /// Moves a per-document split preference when a file is renamed or moved on disk.
    public static func remapDocumentPath(
        from sourcePath: String,
        to destinationPath: String,
        defaults: UserDefaults = .standard
    ) {
        let sourceKey = storageKey(forDocumentPath: sourcePath)
        if defaults.object(forKey: sourceKey) != nil {
            let wasEnabled = defaults.bool(forKey: sourceKey)
            defaults.removeObject(forKey: sourceKey)
            defaults.set(wasEnabled, forKey: storageKey(forDocumentPath: destinationPath))
        }

        let sourceRatioKey = ratioStorageKey(forDocumentPath: sourcePath)
        guard defaults.object(forKey: sourceRatioKey) != nil else { return }
        let ratio = defaults.double(forKey: sourceRatioKey)
        defaults.removeObject(forKey: sourceRatioKey)
        defaults.set(ratio, forKey: ratioStorageKey(forDocumentPath: destinationPath))
    }
}
