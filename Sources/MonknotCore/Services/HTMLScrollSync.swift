import Foundation

public enum HTMLScrollSync: Sendable {
    public static func scrollFraction(forLine line: Int, totalLines: Int) -> Double {
        guard totalLines > 1 else { return 0 }
        let clampedLine = max(1, min(line, totalLines))
        return Double(clampedLine - 1) / Double(totalLines - 1)
    }

    public static func line(forScrollFraction fraction: Double, totalLines: Int) -> Int {
        guard totalLines > 0 else { return 1 }
        guard totalLines > 1 else { return 1 }
        let clampedFraction = min(1, max(0, fraction))
        return max(1, min(totalLines, Int((clampedFraction * Double(totalLines - 1)).rounded()) + 1))
    }

    public static func totalLines(in text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
