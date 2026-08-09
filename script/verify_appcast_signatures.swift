import CryptoKit
import Foundation

enum VerificationError: Error, CustomStringConvertible {
    case usage
    case invalidPublicKey
    case missingFeedSignature
    case invalidFeedSignatureMetadata
    case invalidFeedSignature
    case missingArchiveSignature
    case invalidArchiveSignature

    var description: String {
        switch self {
        case .usage:
            return "usage: verify_appcast_signatures.swift APPCAST DMG PUBLIC_KEY_FILE"
        case .invalidPublicKey:
            return "Sparkle public key is missing or invalid"
        case .missingFeedSignature:
            return "appcast signed-feed block is missing"
        case .invalidFeedSignatureMetadata:
            return "appcast signed-feed length or signature is malformed"
        case .invalidFeedSignature:
            return "appcast signed-feed signature is invalid"
        case .missingArchiveSignature:
            return "appcast enclosure Ed25519 signature is missing"
        case .invalidArchiveSignature:
            return "appcast enclosure Ed25519 signature is invalid"
        }
    }
}

func firstMatch(_ pattern: String, in string: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    guard let match = expression.firstMatch(in: string, range: range),
          let captureRange = Range(match.range(at: 1), in: string)
    else {
        return nil
    }
    return String(string[captureRange])
}

func verify() throws {
    guard CommandLine.arguments.count == 4 else { throw VerificationError.usage }

    let appcastURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let publicKeyURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let appcastData = try Data(contentsOf: appcastURL)
    let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    let publicKeyString = try String(contentsOf: publicKeyURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let publicKeyData = Data(base64Encoded: publicKeyString), publicKeyData.count == 32,
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    else {
        throw VerificationError.invalidPublicKey
    }

    let signingMarker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let signingMarkerRange = appcastData.range(of: signingMarker, options: .backwards) else {
        throw VerificationError.missingFeedSignature
    }
    let contentData = appcastData[..<signingMarkerRange.lowerBound]
    guard let signingBlock = String(data: appcastData[signingMarkerRange.lowerBound...], encoding: .utf8),
          let feedSignatureString = firstMatch(#"edSignature: ([A-Za-z0-9+/]{86}==)"#, in: signingBlock),
          let declaredLengthString = firstMatch(#"length: ([1-9][0-9]*)"#, in: signingBlock),
          let declaredLength = Int(declaredLengthString),
          declaredLength == contentData.count,
          let feedSignature = Data(base64Encoded: feedSignatureString), feedSignature.count == 64
    else {
        throw VerificationError.invalidFeedSignatureMetadata
    }
    guard publicKey.isValidSignature(feedSignature, for: contentData) else {
        throw VerificationError.invalidFeedSignature
    }

    guard let appcastString = String(data: appcastData, encoding: .utf8),
          let archiveSignatureString = firstMatch(#"(?:sparkle:)?edSignature=\"([A-Za-z0-9+/]{86}==)\""#, in: appcastString),
          let archiveSignature = Data(base64Encoded: archiveSignatureString), archiveSignature.count == 64
    else {
        throw VerificationError.missingArchiveSignature
    }
    guard publicKey.isValidSignature(archiveSignature, for: archiveData) else {
        throw VerificationError.invalidArchiveSignature
    }
}

do {
    try verify()
    print("Verified Sparkle feed and archive Ed25519 signatures")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
