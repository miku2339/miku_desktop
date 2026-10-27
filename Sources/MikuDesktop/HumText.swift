import Foundation

/// Spotting a hum in her reply ("啦啦啦～♪", "ふんふ～ん", "la la la~"). A plain "♪" at the end
/// of a line is not a hum: she uses it all the time.
enum HumText {
    private static let pattern = #"(?:啦\s*){3,}|(?<![a-z])(?:la[\s~～\-]*){3,}(?![a-z])|(?:ら\s*){3,}|(?:ラ\s*){3,}|(?:哼\s*){2,}|哼[～~]+|(?:ふん\s*){2,}|ふ[ー～~]+ん|(?:フン\s*){2,}|(?:嗯\s*){2,}[～~]*\s*♪|(?:hm+\s*){2,}|(?:mm+\s*){2,}♪|♪\s*[～~]+\s*♪"#

    static func containsHum(_ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The reply without its hum syllables, for reading aloud before the hum plays.
    static func removingHum(_ text: String) -> String {
        text.replacingOccurrences(of: "(?:" + pattern + ")" + #"[～~ー♪\s]*"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the mouth "says" while a hum clip plays: soft, mostly closed vowels.
    static let mouthText = "ふんふんふーん、ふんふーん"

    /// Audio files a hum clip may be.
    static let fileExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3"]
    /// Clips are short hums, not songs.
    static let maximumSeconds: TimeInterval = 10
    static let maximumBytes = 10 * 1_024 * 1_024

    /// ~/Library/Application Support/MikuDesktop/Hums: clips you put there yourself.
    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MikuDesktop/Hums", isDirectory: true)
    }

    /// Whether any clip is there, so she knows she may hum (checked without reading audio).
    static func hasClips(in folder: URL = defaultFolder) -> Bool {
        !candidateFiles(in: folder).isEmpty
    }

    /// Audio files of a sensible size directly in the folder; no links or subfolders.
    static func candidateFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return files.filter { url in
            guard fileExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= maximumBytes else { return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
