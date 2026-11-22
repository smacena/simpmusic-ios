import Foundation

/// A Latin-script reading for lyric lines in Japanese, Chinese or Korean, using the system:
/// the word tokenizer's Latin transcription for Japanese (it knows kanji readings), the
/// Mandarin→Latin transform for Chinese (pinyin with tones), Hangul→Latin for Korean.
/// Lines already in Latin script get nothing.
enum Romanizer {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lyrics.romanize") }
        set { UserDefaults.standard.set(newValue, forKey: "lyrics.romanize") }
    }

    private static var cache: [String: String] = [:]

    static func reading(for line: String) -> String? {
        guard enabled, !line.isEmpty else { return nil }
        if let hit = cache[line] { return hit.isEmpty ? nil : hit }
        let result = compute(line) ?? ""
        cache[line] = result
        return result.isEmpty ? nil : result
    }

    private static func compute(_ line: String) -> String? {
        var kana = false, han = false, hangul = false
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x3040 ... 0x30FF, 0x31F0 ... 0x31FF: kana = true
            case 0x4E00 ... 0x9FFF, 0x3400 ... 0x4DBF: han = true
            case 0xAC00 ... 0xD7AF, 0x1100 ... 0x11FF, 0x3130 ... 0x318F: hangul = true
            default: break
            }
        }
        if kana { return japanese(line) }
        if hangul { return line.applyingTransform(.toLatin, reverse: false) }
        if han { return line.applyingTransform(.mandarinToLatin, reverse: false) }
        return nil
    }

    private static func japanese(_ line: String) -> String? {
        let text = line as CFString
        let length = CFStringGetLength(text)
        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, text, CFRangeMake(0, length), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var words: [String] = []
        var token = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while token != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String, !latin.isEmpty {
                words.append(latin)
            } else if let r = Range(NSRange(location: range.location, length: range.length), in: line) {
                words.append(String(line[r]))
            }
            token = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
