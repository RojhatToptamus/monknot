import Foundation
import MonknotCore

let service = WorkspaceReadOnlyExportService()

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }

    do {
        let response = try service.handle(requestData: Data(trimmed.utf8))
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        let payload = ["error": error.localizedDescription]
        let data = try JSONEncoder().encode(payload)
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        exit(1)
    }
}
