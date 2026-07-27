import OSLog

public enum MonknotSignposting {
    public static let subsystem = "io.github.rojhattoptamus.monknot"
    private static let logger = Logger(subsystem: subsystem, category: "performance")

    public static let workspaceScan = OSSignposter(logger: logger)
    public static let workspaceSearch = OSSignposter(logger: logger)
    public static let externalRefresh = OSSignposter(logger: logger)
    public static let pdfSearch = OSSignposter(logger: logger)
    public static let documentSelection = OSSignposter(logger: logger)
    public static let pdfPreview = OSSignposter(logger: logger)
}
