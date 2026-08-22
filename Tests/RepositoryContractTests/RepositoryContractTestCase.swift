import Foundation
import XCTest

class RepositoryContractTestCase: XCTestCase {

    func sourceEntries(named arrayName: String, in script: String) throws -> Set<String> {
        guard let startRange = script.range(of: "\(arrayName)=(") else {
            throw NSError(domain: "RepositoryContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(arrayName) array"])
        }
        guard let endRange = script[startRange.upperBound...].range(of: "\n)") else {
            throw NSError(domain: "RepositoryContractTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(arrayName) terminator"])
        }

        let section = script[startRange.upperBound..<endRange.lowerBound]
        return Set(section
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> String? in
                guard line.hasPrefix("\""), line.hasSuffix("\"") else { return nil }
                return String(line.dropFirst().dropLast())
            })
    }

    func swiftSources(under directory: URL) throws -> Set<String> {
        let root = repositoryRoot
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sources: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            sources.insert(relativePath)
        }
        return sources
    }
}
