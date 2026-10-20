import Foundation

/// Weather and sun times handed to the wallpaper pages.
struct WeatherSnapshot: Sendable, Equatable {
    var kind: String
    var intensity: Double
    var wind: Double
    var cloud: Double
    var temperature: Double?
    /// Sunrise / sunset in the Mac's local time, as fractional hours.
    var sunrise: Double?
    var sunset: Double?
    var isLive: Bool

    var payload: [String: Any] {
        ["kind": kind, "intensity": intensity, "wind": wind, "cloud": cloud]
    }

    static let fallback = WeatherSnapshot(kind: "clear", intensity: 0, wind: 0.15, cloud: 0.15, temperature: nil, sunrise: nil, sunset: nil, isLive: false)
}

struct WeatherCity: Sendable {
    let key: String
    let latitude: Double
    let longitude: Double
}

/// Real weather from Open-Meteo (free, no API key), or a fixed weather chosen in Settings.
@MainActor
final class WeatherService {
    nonisolated static let modeKey = "weatherMode"
    nonisolated static let cityKey = "weatherCity"
    nonisolated static let ambientKey = "ambientEnabled"
    nonisolated static let modes = ["auto", "clear", "cloudy", "rain", "storm", "snow", "fog"]
    nonisolated static let cities: [WeatherCity] = [
        WeatherCity(key: "tokyo", latitude: 35.6812, longitude: 139.7671),
        WeatherCity(key: "yokohama", latitude: 35.4437, longitude: 139.6380),
        WeatherCity(key: "osaka", latitude: 34.6937, longitude: 135.5023),
        WeatherCity(key: "kyoto", latitude: 35.0116, longitude: 135.7681),
        WeatherCity(key: "nagoya", latitude: 35.1815, longitude: 136.9066),
        WeatherCity(key: "sapporo", latitude: 43.0618, longitude: 141.3545),
        WeatherCity(key: "fukuoka", latitude: 33.5902, longitude: 130.4017),
        WeatherCity(key: "hongkong", latitude: 22.3193, longitude: 114.1694),
        WeatherCity(key: "taipei", latitude: 25.0330, longitude: 121.5654)
    ]

    nonisolated static var mode: String {
        let stored = UserDefaults.standard.string(forKey: modeKey) ?? "auto"
        return modes.contains(stored) ? stored : "auto"
    }

    nonisolated static var city: WeatherCity {
        let stored = UserDefaults.standard.string(forKey: cityKey) ?? "tokyo"
        return cities.first { $0.key == stored } ?? cities[0]
    }

    nonisolated static var ambientEnabled: Bool {
        UserDefaults.standard.object(forKey: ambientKey) as? Bool ?? true
    }

    var onUpdate: ((WeatherSnapshot) -> Void)?
    private(set) var latest: WeatherSnapshot = .fallback
    private(set) var lastError: String?
    private var liveWeather: WeatherSnapshot?
    private var timer: Timer?
    private var fetchTask: Task<Void, Never>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Re-applies the settings immediately and fetches fresh data in the background.
    func refresh() {
        publish()
        fetchTask?.cancel()
        let city = Self.city
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await WeatherService.fetch(city: city, session: session)
                guard !Task.isCancelled else { return }
                liveWeather = snapshot
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
            }
            publish()
        }
    }

    private func publish() {
        var snapshot = liveWeather ?? .fallback
        let mode = Self.mode
        if mode != "auto" {
            snapshot.kind = mode
            snapshot.intensity = mode == "clear" ? 0 : (mode == "storm" ? 0.9 : 0.7)
            snapshot.cloud = mode == "clear" ? 0.1 : (mode == "fog" ? 0.7 : 0.88)
            snapshot.isLive = false
        }
        latest = snapshot
        onUpdate?(snapshot)
    }

    // MARK: - Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable {
            let weather_code: Int
            let cloud_cover: Double?
            let wind_speed_10m: Double?
            let wind_direction_10m: Double?
            let temperature_2m: Double?
        }

        struct Daily: Decodable {
            let sunrise: [String]
            let sunset: [String]
        }

        let current: Current
        let daily: Daily?
        let utc_offset_seconds: Int
    }

    private static func fetch(city: WeatherCity, session: URLSession) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(city.latitude)),
            URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "weather_code,cloud_cover,wind_speed_10m,wind_direction_10m,temperature_2m"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let (kind, intensity) = classify(code: decoded.current.weather_code)
        let speed = decoded.current.wind_speed_10m ?? 8
        let direction = (decoded.current.wind_direction_10m ?? 270) * .pi / 180
        // Wind "from the west" pushes rain to the right of the screen.
        let wind = max(-1, min(1, -sin(direction) * min(1, speed / 35)))
        let offset = decoded.utc_offset_seconds
        return WeatherSnapshot(
            kind: kind,
            intensity: intensity,
            wind: wind,
            cloud: (decoded.current.cloud_cover ?? 30) / 100,
            temperature: decoded.current.temperature_2m,
            sunrise: decoded.daily?.sunrise.first.flatMap { localHours($0, utcOffset: offset) },
            sunset: decoded.daily?.sunset.first.flatMap { localHours($0, utcOffset: offset) },
            isLive: true
        )
    }

    /// WMO weather interpretation codes → our weather kinds.
    private static func classify(code: Int) -> (String, Double) {
        switch code {
        case 0: return ("clear", 0)
        case 1: return ("clear", 0)
        case 2: return ("cloudy", 0.4)
        case 3: return ("cloudy", 0.8)
        case 45, 48: return ("fog", 0.75)
        case 51, 53, 55, 56, 57: return ("rain", 0.3)
        case 61, 80: return ("rain", 0.45)
        case 63, 81, 66: return ("rain", 0.65)
        case 65, 82, 67: return ("rain", 0.9)
        case 71, 77, 85: return ("snow", 0.4)
        case 73: return ("snow", 0.65)
        case 75, 86: return ("snow", 0.9)
        case 95, 96, 99: return ("storm", 0.9)
        default: return ("cloudy", 0.5)
        }
    }

    /// "2026-10-20T05:52" in the city's time → hours in the Mac's local time zone.
    private static func localHours(_ value: String, utcOffset: Int) -> Double? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffset)
        guard let date = formatter.date(from: value) else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }
}
