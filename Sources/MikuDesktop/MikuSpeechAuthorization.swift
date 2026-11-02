import Foundation

enum MikuSpeechAuthorization {
    enum AuthorizationError: Error, Equatable {
        case untrustedServiceURL
    }

    static let defaultEndpoint = "http://127.0.0.1:8000/v1"

    static func localRequest(url: URL, endpoint: URL) throws -> URLRequest {
        try validateServiceEndpoint(endpoint)
        guard isLoopbackServiceURL(url), sameOrigin(url, endpoint),
              url.standardized.path == url.path,
              url.path.hasPrefix(endpoint.path + "/") else {
            throw AuthorizationError.untrustedServiceURL
        }
        return URLRequest(url: url)
    }

    static func capabilitiesRequest(model: String, endpoint: URL) throws -> URLRequest {
        guard MikuSpeechWire.validModelID(model) else { throw AuthorizationError.untrustedServiceURL }
        let base = endpoint.appendingPathComponent("audio/capabilities")
        var request = try localRequest(url: base, endpoint: endpoint)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components?.url else { throw AuthorizationError.untrustedServiceURL }
        request.url = url
        return request
    }

    static func validateServiceEndpoint(_ url: URL) throws {
        guard isLoopbackServiceURL(url), url.path == "/v1" else {
            throw AuthorizationError.untrustedServiceURL
        }
    }

    static func isLoopbackServiceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return true
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 80) == (rhs.port ?? 80)
    }
}

enum MikuSpeechWire {
    struct SpeechBody: Encodable {
        let model: String
        let input: String
        let language: String
        let responseFormat: String
        let stream: Bool?
        let style: String?

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case language
            case stream, style
            case responseFormat = "response_format"
        }
    }

    private struct ModelStatusResponse: Decodable {
        let models: [ModelStatus]
    }

    private struct ModelStatus: Decodable {
        let id: String
        let engineType: String?
        let modelType: String?

        enum CodingKeys: String, CodingKey {
            case id
            case engineType = "engine_type"
            case modelType = "model_type"
        }
    }

    private struct ModelsResponse: Decodable {
        let object: String
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
    }

    static func speechBody(model: String, input: String, language: String, style: String? = nil, streaming: Bool = false) throws -> Data {
        try JSONEncoder().encode(SpeechBody(model: model, input: input, language: language,
                                           responseFormat: streaming ? "pcm_s16le" : "wav",
                                           stream: streaming ? true : nil, style: style))
    }

    static func audioModelIDs(from data: Data) throws -> [String] {
        let response = try JSONDecoder().decode(ModelStatusResponse.self, from: data)
        let models = response.models.compactMap { model in
            let engine = model.engineType?.lowercased()
            let type = model.modelType?.lowercased()
            return engine == "audio_tts" || type == "audio_tts" ? model.id : nil
        }.filter(validModelID)
        return Array(Set(models)).sorted()
    }

    static func validateModelsResponse(_ data: Data) throws {
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        guard response.object == "list", response.data.allSatisfy({ validModelID($0.id) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid model id"))
        }
    }

    static func validModelID(_ value: String) -> Bool {
        let bytes = value.utf8
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed
            && !trimmed.isEmpty
            && bytes.count <= 512
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isAudioContentType(_ value: String?) -> Bool {
        guard let type = value?.split(separator: ";", maxSplits: 1).first?.lowercased() else { return false }
        return type == "audio/wav" || type == "audio/x-wav" || type == "application/octet-stream"
    }

    static func validWAV(_ data: Data) -> Bool {
        guard data.count >= 44,
              ascii(data, offset: 0, count: 4) == "RIFF",
              ascii(data, offset: 8, count: 4) == "WAVE" else {
            return false
        }
        var offset = 12
        var validFormat = false
        var hasAudio = false
        while offset + 8 <= data.count {
            let name = ascii(data, offset: offset, count: 4)
            guard let sizeValue = uint32(data, offset: offset + 4) else { return false }
            let size = Int(sizeValue)
            let content = offset + 8
            guard content <= data.count, size <= data.count - content else { return false }
            if name == "fmt " {
                guard size >= 16,
                      uint16(data, offset: content) == 1,
                      let channels = uint16(data, offset: content + 2), (1...2).contains(channels),
                      let sampleRate = uint32(data, offset: content + 4), (8_000...192_000).contains(sampleRate),
                      let bits = uint16(data, offset: content + 14), [16, 24, 32].contains(bits) else {
                    return false
                }
                validFormat = true
            } else if name == "data" {
                hasAudio = size > 0
            }
            let paddedSize = size + (size % 2)
            guard paddedSize <= data.count - content else { return false }
            offset = content + paddedSize
        }
        return validFormat && hasAudio
    }

    private static func ascii(_ data: Data, offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { return nil }
        return String(data: data.subdata(in: offset..<(offset + count)), encoding: .ascii)
    }

    private static func uint16(_ data: Data, offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
