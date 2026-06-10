import Foundation

public enum DailyNotePlanner {
    public static let inboxFolderName = "inbox"

    public static func datedFileName(for date: Date, calendar: Calendar = .current) -> String {
        "\(titleDateString(for: date, calendar: calendar)).md"
    }

    public static func titleDateString(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func initialContent(for date: Date, calendar: Calendar = .current) -> String {
        "# \(titleDateString(for: date, calendar: calendar))\n\n"
    }

    public static func inboxDirectoryURL(workspaceURL: URL) -> URL {
        workspaceURL.appendingPathComponent(inboxFolderName, isDirectory: true)
    }

    public static func dailyNoteURL(
        workspaceURL: URL,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> URL {
        inboxDirectoryURL(workspaceURL: workspaceURL)
            .appendingPathComponent(datedFileName(for: date, calendar: calendar))
    }
}
