import Foundation

@main
struct VoicePCMStreamTests {
    private static var checks = 0
    static func main() throws {
        let audio = try frame(payload: Data([0, 0, 0xff, 0x7f]))
        let end = try frame(type: "end", seq: 1, total: 2)
        let complete = audio + end
        for split in 0...complete.count {
            var parser = VoicePCMStreamParser(language: "en")
            let first = try parser.append(Data(complete.prefix(split)))
            let second = try parser.append(Data(complete.dropFirst(split)))
            try parser.finish()
            check((first + second).count == 2 && parser.ended, "每個header/PCM切點都可還原：\(split)")
        }
        var byteParser = VoicePCMStreamParser(language: "en")
        var received: [VoicePCMFrame] = []
        for byte in complete { received += try byteParser.append(Data([byte])) }
        try byteParser.finish()
        check(received.first?.payload == Data([0, 0, 0xff, 0x7f]), "逐byte解析保留PCM原資料")
        expectError(.trailingData) { _ = try byteParser.append(Data([1])) }
        for invalid in [Data([0, 0, 0, 0]), Data([0, 1, 0, 1])] {
            expectError(.invalidHeader) { var p = VoicePCMStreamParser(language: "en"); _ = try p.append(invalid) }
        }
        expectError(.overflow) {
            var p = VoicePCMStreamParser(language: "en"); _ = try p.append(Data(count: 140_000))
        }
        for change: [String: Any] in [["v": 2], ["id": "unsafe\nid"], ["seq": -1], ["seq": 1],
                                     ["payload_bytes": -1], ["payload_bytes": 65_538], ["type": "other"], ["seq": true]] {
            expectFailure { var p = VoicePCMStreamParser(language: "en"); _ = try p.append(frame(payload: Data([0, 0]), changes: change)) }
        }
        for change: [String: Any] in [["sample_rate": 0], ["sample_rate": 192_000], ["channels": 2],
                                     ["format": "float32"], ["language": "ja"], ["seed": -1], ["seed": true], ["payload_bytes": 1]] {
            expectFailure { var p = VoicePCMStreamParser(language: "en"); _ = try p.append(frame(payload: Data([0, 0]), changes: change)) }
        }
        for change: [String: Any] in [["id": "different"], ["seq": 0], ["seq": 2], ["sample_rate": 24_000], ["seed": 123]] {
            expectFailure {
                var p = VoicePCMStreamParser(language: "en")
                _ = try p.append(audio)
                _ = try p.append(frame(seq: 1, payload: Data([0, 0]), changes: change))
            }
        }
        for bytes in [Data(), Data(audio.prefix(2)), Data(audio.dropLast()), audio] {
            expectError(.truncated) { var p = VoicePCMStreamParser(language: "en"); _ = try p.append(bytes); try p.finish() }
        }
        expectError(.invalidAudio) { var p = VoicePCMStreamParser(language: "en"); _ = try p.append(frame(type: "end", total: 0)) }
        expectError(.invalidAudio) {
            var p = VoicePCMStreamParser(language: "en"); _ = try p.append(audio)
            _ = try p.append(frame(type: "end", seq: 1, total: 3))
        }
        expectError(.trailingData) { var p = VoicePCMStreamParser(language: "en"); _ = try p.append(complete + Data([0])) }
        expectError(.serverError("SOURCE_MISMATCH")) {
            var p = VoicePCMStreamParser(language: "en")
            _ = try p.append(frame(type: "error", changes: ["code": "SOURCE_MISMATCH"]))
        }
        expectError(.serverError("STREAM_FAILED")) {
            var p = VoicePCMStreamParser(language: "en")
            _ = try p.append(frame(type: "error", changes: ["code": "private text\nnot a code"]))
        }
        expectError(.overflow) {
            var p = VoicePCMStreamParser(language: "en")
            for seq in 0..<32 {
                _ = try p.append(frame(seq: seq, payload: Data(count: 65_536), changes: ["sample_rate": 8_000]))
            }
        }
        expectError(.overflow) {
            var p = VoicePCMStreamParser(language: "en")
            for seq in 0..<40 {
                _ = try p.append(frame(seq: seq, payload: Data([0, 0]), changes: ["padding": String(repeating: "a", count: 64_000)]))
            }
        }
        let caps: [String: Any] = ["version": 1, "model": "test", "languages": ["en"], "formats": ["wav", "pcm_s16le"],
                                   "styles": ["neutral", "happy"], "streaming_languages": ["en"]]
        let capability = try VoiceAudioCapabilities.decode(JSONSerialization.data(withJSONObject: caps), model: "test")
        check(capability.canStream(language: "en") && !capability.canStream(language: "ja"), "能力按語言決定串流")
        check(capability.style(.happy) == "happy" && capability.style(.sleepy) == "neutral", "只選宣告風格，缺少則自然聲音")
        for change: [String: Any] in [["model": "other"], ["version": 2], ["languages": ["unknown"]], ["streaming_languages": ["ja"]]] {
            var value = caps; value.merge(change) { _, b in b }
            expectFailure { _ = try VoiceAudioCapabilities.decode(JSONSerialization.data(withJSONObject: value), model: "test") }
        }
        for (emotion, expected) in [("happy", MikuVoiceStyle.happy), ("curious", .happy), ("sad", .gentle), ("shy", .gentle),
                                    ("sleepy", .sleepy), ("pout", .neutral), ("unknown", .neutral)] {
            check(MikuVoiceStyle.fromEmotion(emotion) == expected, "情緒映射：\(emotion)")
        }
        print("VoicePCMStream: \(checks) checks passed")
    }

    private static func frame(type: String = "audio", seq: Int = 0, payload: Data = Data(), total: Int = 0,
                              changes: [String: Any] = [:]) throws -> Data {
        var header: [String: Any] = ["v": 1, "type": type, "id": "test-id", "seq": seq, "language": "en", "seed": 42,
                                   "sample_rate": 16_000, "channels": 1, "format": "pcm_s16le", "payload_bytes": payload.count]
        if type == "end" { header["total_samples"] = total }
        header.merge(changes) { _, b in b }
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + data + payload
    }
    private static func expectFailure(_ action: () throws -> Void) {
        do { try action(); check(false, "非法輸入必須失敗") }
        catch { check(true, "非法輸入拒絕") }
    }
    private static func expectError(_ expected: VoicePCMStreamError, action: () throws -> Void) {
        do { try action(); check(false, "預期錯誤：\(expected)") }
        catch { check(error as? VoicePCMStreamError == expected, "預期\(expected)，實得\(error)") }
    }
    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
