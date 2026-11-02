import Foundation

@main
struct MikuSpeechAuthorizationTests {
    static func main() throws {
        try testLoopbackEndpointPolicy()
        try testLocalRequestsNeverCarryRemoteCredentials()
        try testOpenAISpeechBody()
        try testCapabilitiesRequest()
        try testAudioModelDiscovery()
        testWAVValidation()
        print("PASS: local speech authorization and wire checks")
    }

    private static func testLoopbackEndpointPolicy() throws {
        for value in [
            "http://127.0.0.1:8000/v1",
            "http://localhost:8888/v1",
            "http://[::1]:8000/v1"
        ] {
            try MikuSpeechAuthorization.validateServiceEndpoint(try url(value))
        }

        for value in [
            "https://127.0.0.1:8000/v1",
            "http://0.0.0.0:8000/v1",
            "http://192.168.1.2:8000/v1",
            "http://miku-tts.qimake.si/v1",
            "https://miku-tts.qimake.si/v1",
            "http://user@127.0.0.1:8000/v1",
            "http://127.0.0.1:8000/",
            "http://127.0.0.1:8000/v1/audio",
            "http://127.0.0.1:8000/v1?next=remote",
            "http://127.0.0.1:8000/v1#remote"
        ] {
            do {
                try MikuSpeechAuthorization.validateServiceEndpoint(try url(value))
                preconditionFailure("Untrusted endpoint was accepted: \(value)")
            } catch MikuSpeechAuthorization.AuthorizationError.untrustedServiceURL {
                continue
            }
        }
    }

    private static func testLocalRequestsNeverCarryRemoteCredentials() throws {
        let endpoint = try url("http://127.0.0.1:8000/v1")
        for value in [
            "http://127.0.0.1:8000/v1/models/status",
            "http://127.0.0.1:8000/v1/audio/speech"
        ] {
            let request = try MikuSpeechAuthorization.localRequest(url: try url(value), endpoint: endpoint)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        }

        for value in [
            "http://localhost:8000/v1/audio/speech",
            "http://127.0.0.1:8001/v1/audio/speech",
            "http://127.0.0.1:8000/v1/../api/jobs",
            "http://127.0.0.1:8000/api/jobs",
            "http://127.0.0.1:8000/v1/audio/speech?model=anything",
            "https://miku-tts.qimake.si/api/jobs"
        ] {
            do {
                _ = try MikuSpeechAuthorization.localRequest(url: try url(value), endpoint: endpoint)
                preconditionFailure("Cross-origin or out-of-base request was accepted: \(value)")
            } catch MikuSpeechAuthorization.AuthorizationError.untrustedServiceURL {
                continue
            }
        }
    }

    private static func testCapabilitiesRequest() throws {
        let endpoint = try url("http://127.0.0.1:8000/v1")
        let request = try MikuSpeechAuthorization.capabilitiesRequest(model: "owner/tts-model", endpoint: endpoint)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        precondition(components.path == "/v1/audio/capabilities")
        precondition(components.queryItems == [URLQueryItem(name: "model", value: "owner/tts-model")])
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        for (model, target) in [("bad\nmodel", endpoint), ("tts", try url("https://example.com/v1"))] {
            do {
                _ = try MikuSpeechAuthorization.capabilitiesRequest(model: model, endpoint: target)
                preconditionFailure("Invalid capability request was accepted")
            } catch MikuSpeechAuthorization.AuthorizationError.untrustedServiceURL {}
        }
        let data = try MikuSpeechWire.speechBody(model: "tts", input: "Hello", language: "en", style: "neutral", streaming: true)
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(body["response_format"] as? String == "pcm_s16le" && body["stream"] as? Bool == true)
        precondition(body["style"] as? String == "neutral")
    }

    private static func testOpenAISpeechBody() throws {
        let data = try MikuSpeechWire.speechBody(
            model: "owner/tts-model",
            input: "你好",
            language: "zh"
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        precondition(object == [
            "model": "owner/tts-model",
            "input": "你好",
            "language": "zh",
            "response_format": "wav"
        ])
        precondition(MikuSpeechWire.validModelID("owner/tts-model"))
        precondition(!MikuSpeechWire.validModelID(" owner/tts-model "))
        precondition(!MikuSpeechWire.validModelID("\n"))
        precondition(MikuSpeechWire.isAudioContentType("audio/wav; charset=binary"))
        precondition(MikuSpeechWire.isAudioContentType("application/octet-stream"))
        precondition(!MikuSpeechWire.isAudioContentType("application/json"))
    }

    private static func testAudioModelDiscovery() throws {
        let status = Data(#"""
        {
          "models": [
            {"id":"voice-b","engine_type":"audio_tts","model_type":null,"owned_by":"local"},
            {"id":"chat-model","engine_type":"llm","model_type":"llm","owned_by":"local"},
            {"id":"voice-a","engine_type":"other","model_type":"audio_tts","owned_by":"unknown"}
          ],
          "model_count":3
        }
        """#.utf8)
        let models = try MikuSpeechWire.audioModelIDs(from: status)
        precondition(models == ["voice-a", "voice-b"])

        let generic = Data(#"{"object":"list","data":[{"id":"manual-model","object":"model","created":1,"owned_by":"local"}]}"#.utf8)
        try MikuSpeechWire.validateModelsResponse(generic)
        do {
            try MikuSpeechWire.validateModelsResponse(Data(#"{"object":"model","data":[]}"#.utf8))
            preconditionFailure("Invalid /v1/models object was accepted")
        } catch is DecodingError {}
    }

    private static func testWAVValidation() {
        precondition(MikuSpeechWire.validWAV(wav(sampleRate: 24_000)))
        precondition(MikuSpeechWire.validWAV(wav(sampleRate: 32_000)))
        precondition(MikuSpeechWire.validWAV(wav(sampleRate: 48_000)))
        precondition(!MikuSpeechWire.validWAV(wav(sampleRate: 7_999)))
        precondition(!MikuSpeechWire.validWAV(Data("not audio".utf8)))
    }

    private static func wav(sampleRate: UInt32) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
        }
        func u32(_ value: UInt32) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 24) & 0xff))
        }
        ascii("RIFF")
        u32(38)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        ascii("data")
        u32(2)
        u16(0)
        return data
    }

    private static func url(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw TestError.invalidFixture }
        return url
    }

    private enum TestError: Error {
        case invalidFixture
    }
}
