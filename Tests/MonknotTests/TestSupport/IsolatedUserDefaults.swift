import Foundation

final class IsolatedUserDefaults {
    let suiteName: String
    let userDefaults: UserDefaults

    init(prefix: String = "MonknotTests") {
        suiteName = "\(prefix).\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}
