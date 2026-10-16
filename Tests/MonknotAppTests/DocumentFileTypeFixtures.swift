import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Real files of every kind Monknot lists, generated into a folder so each test reads what a user's
/// disk would hold.
enum DocumentFileTypeFixtures {
    /// A 1 × 1 lossless WebP, for systems whose ImageIO reads WebP but cannot write it.
    static let tinyWebP = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!

    static func image(width: Int, height: Int, seed: UInt8 = 0) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: CGFloat(seed) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: max(1, width / 4), height: max(1, height / 4)))
        return context.makeImage()!
    }

    static func canWriteImage(_ type: UTType) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type.identifier)
    }

    /// Encodes `frames` as one image file; several frames make an animation.
    static func writeImage(
        _ frames: [CGImage],
        as type: UTType,
        to url: URL,
        properties: [CFString: Any] = [:]
    ) throws {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw fixtureError("ImageIO cannot write \(type.identifier)")
        }
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw fixtureError("ImageIO could not encode \(url.lastPathComponent)")
        }
        try (output as Data).write(to: url)
    }

    static func writePDF(to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 120)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw fixtureError("Could not create a PDF context") }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 60, height: 40))
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
    }

    /// Half a second of a 440 Hz tone as 16-bit mono PCM.
    static func writeWAV(to url: URL) throws {
        let sampleRate = 8_000
        let samples = (0..<(sampleRate / 2)).map { index -> Int16 in
            Int16(sin(Double(index) * 2 * .pi * 440 / Double(sampleRate)) * 8_000)
        }
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payloadSize = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payloadSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payloadSize))
        samples.forEach { append($0) }
        try data.write(to: url)
    }

    /// A one-second 2:1 H.264 QuickTime movie of solid frames.
    static func writeMovie(to url: URL) async throws {
        let width = 64
        let height = 32
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? fixtureError("The movie writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = 10
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw fixtureError("The movie writer has no pixel buffer pool")
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw fixtureError("No pixel buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
            memset(base, Int32(frame * 20), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: 10))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? fixtureError("The movie writer did not finish")
        }
    }

    static func fixtureError(_ description: String) -> NSError {
        NSError(domain: "DocumentFileTypeFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
