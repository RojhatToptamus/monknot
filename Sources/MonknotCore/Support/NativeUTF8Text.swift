import Foundation

/// Native, contiguous UTF-8 copies of document text.
///
/// `NSTextView.string` is a bridged `NSBigMutableString`. Swift compares bridged strings scalar by
/// scalar with Unicode normalization, so every equality check on a document's text costs time
/// proportional to the position of the first difference — about 14 ms for a 190 KB note. Native
/// UTF-8 strings compare with `memcmp`. Converting once per edit (one bulk UTF-8 copy) keeps every
/// later comparison cheap.
public enum NativeUTF8Text {
    /// Returns `text` itself when it is already native UTF-8, otherwise a native copy with identical
    /// UTF-16 content. Text that cannot round-trip through UTF-8 (an unpaired surrogate) is returned
    /// unchanged rather than altered.
    public static func copy(of text: String) -> String {
        if text.utf8.withContiguousStorageIfAvailable({ _ in true }) == true {
            return text
        }
        return copy(of: text as NSString) ?? text
    }

    /// A native UTF-8 copy of `string`, or `nil` when it contains an unpaired surrogate.
    public static func copy(of string: NSString) -> String? {
        guard let data = string.data(using: String.Encoding.utf8.rawValue, allowLossyConversion: false) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
