import Foundation

/// A radio station from the free, public Radio Browser directory
/// (https://www.radio-browser.info). No account, no API key.
struct RadioStation: Identifiable, Hashable, Decodable, Sendable {
    let stationuuid: String
    let name: String
    let url: String
    let urlResolved: String?
    let favicon: String?
    let tags: String?
    let country: String?
    let codec: String?
    let bitrate: Int?
    /// Radio Browser's HLS flag (0/1). It is a hint, not proof.
    let hls: Int?

    var id: String { stationuuid }

    var isHLS: Bool { hls == 1 }

    /// Direct stream URL, preferring the server-resolved one.
    var streamURL: String? {
        let resolved = urlResolved?.trimmingCharacters(in: .whitespaces) ?? ""
        if resolved.hasPrefix("http") { return resolved }
        let raw = url.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("http") { return raw }
        return nil
    }

    /// Radio Browser's codec is a hint, not proof of a stream's container.
    /// It helps Apolo choose FFmpeg for opaque Ogg/Opus/FLAC endpoints.
    var apoloMIMEHint: String? {
        if isHLS { return "application/vnd.apple.mpegurl" }
        let format = (codec ?? "").uppercased()
        if format.contains("OPUS") { return "audio/opus" }
        if format.contains("OGG") || format.contains("VORBIS") {
            return "audio/ogg"
        }
        if format.contains("FLAC") { return "audio/flac" }
        if format.contains("MP3") || format.contains("MPEG") {
            return "audio/mpeg"
        }
        if format.contains("AAC") { return "audio/aac" }
        if format.contains("HLS") { return "application/vnd.apple.mpegurl" }
        // Legacy raw ICY requires a known station hint, not a guess based on
        // a generic MP3 codec label (which most modern stations also use).
        if format.contains("ICY") { return "application/x-icy" }
        return nil
    }

    var iconURL: String? {
        guard let favicon, favicon.hasPrefix("http") else { return nil }
        return favicon
    }

    var subtitle: String {
        var parts: [String] = []
        if let country, !country.isEmpty { parts.append(country) }
        let codecName = (codec ?? "").trimmingCharacters(in: .whitespaces)
        if !codecName.isEmpty {
            if let bitrate, bitrate > 0 {
                parts.append("\(codecName) \(bitrate) kbps")
            } else {
                parts.append(codecName)
            }
        }
        return parts.joined(separator: " • ")
    }

    enum CodingKeys: String, CodingKey {
        case stationuuid
        case name
        case url
        case urlResolved = "url_resolved"
        case favicon
        case tags
        case country
        case codec
        case bitrate
        case hls
    }
}

enum RadioBrowserError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Radio Browser returned HTTP \(code)."
        }
    }
}

enum RadioBrowser {
    private static let host = "https://de1.api.radio-browser.info"

    /// Most-clicked stations across the directory.
    static func topStations(limit: Int = 80) async throws -> [RadioStation] {
        guard let url = URL(string: "\(host)/json/stations/topclick/\(limit)") else {
            return []
        }
        return try await fetch(url)
    }

    /// Stations carrying a genre tag (e.g. "jazz", "rock").
    static func stations(tag: String, limit: Int = 80) async throws -> [RadioStation] {
        try await query(URLQueryItem(name: "tag", value: tag), limit: limit)
    }

    /// Free-text station search by name.
    static func search(_ text: String, limit: Int = 80) async throws -> [RadioStation] {
        try await query(URLQueryItem(name: "name", value: text), limit: limit)
    }

    private static func query(_ item: URLQueryItem, limit: Int) async throws -> [RadioStation] {
        var components = URLComponents(string: "\(host)/json/stations/search")
        components?.queryItems = [
            item,
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        guard let url = components?.url else { return [] }
        return try await fetch(url)
    }

    private static func fetch(_ url: URL) async throws -> [RadioStation] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Radio Browser asks clients to identify themselves.
        request.setValue("Thrum/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RadioBrowserError.http(status)
        }
        return try JSONDecoder().decode([RadioStation].self, from: data)
    }
}
