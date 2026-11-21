import Foundation

/// Detects how a station is delivered before playback: HLS, direct ICY
/// (MP3/AAC with `icy-metaint`) or an exotic container that must go through
/// FFmpeg. The answer is a MIME hint for Apolo, cached per URL.
enum RadioTransport: String, Sendable {
    case hls
    case icy
    case ffmpeg
    case direct
}

actor RadioTransportResolver {
    static let shared = RadioTransportResolver()

    private struct Entry: Sendable {
        let transport: RadioTransport
        let hint: String?
        let at: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<Entry, Never>] = [:]
    private let ttl: TimeInterval = 900

    /// Returns the Apolo `sourceMIMEType` hint for this station.
    func hint(for station: RadioStation) async -> String? {
        guard let raw = station.streamURL, let url = URL(string: raw) else {
            return station.apoloMIMEHint
        }
        if let cached = cache[raw], Date().timeIntervalSince(cached.at) < ttl {
            return cached.hint
        }
        if let running = inFlight[raw] {
            return await running.value.hint
        }
        let task = Task { [station, url, raw] in
            await self.classify(station: station, url: url, raw: raw)
        }
        inFlight[raw] = task
        let entry = await task.value
        inFlight[raw] = nil
        cache[raw] = entry
        return entry.hint
    }

    private func classify(station: RadioStation, url: URL, raw: String) async -> Entry {
        if station.isHLS || url.pathExtension.lowercased() == "m3u8" {
            return Entry(transport: .hls, hint: "application/vnd.apple.mpegurl", at: Date())
        }
        let codec = (station.codec ?? "").uppercased()
        if codec.contains("OPUS") || codec.contains("OGG") || codec.contains("VORBIS") || codec.contains("FLAC") {
            return Entry(transport: .ffmpeg, hint: station.apoloMIMEHint, at: Date())
        }
        // Known Radio Browser formats should start immediately. Avoid
        // delaying the audible start with a duplicate network connection.
        if let hint = station.apoloMIMEHint, !hint.isEmpty {
            let legacy = hint == "application/x-icy"
            return Entry(transport: legacy ? .icy : .direct, hint: hint, at: Date())
        }
        if let probed = await probe(url: url) {
            return Entry(transport: probed.transport, hint: probed.hint, at: Date())
        }
        return Entry(transport: .direct, hint: station.apoloMIMEHint, at: Date())
    }

    /// Sends `Icy-MetaData: 1` and inspects only the response headers; the
    /// async byte stream is released right away so an endless radio body is
    /// never consumed.
    private func probe(url: URL) async -> (transport: RadioTransport, hint: String?)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.setValue("Thrum/1.0", forHTTPHeaderField: "User-Agent")
        // Probe only headers of an indefinite live stream. The dedicated
        // session must be canceled on every exit; dropping AsyncBytes alone
        // does not guarantee termination of a still-streaming HTTP request.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200...399).contains(http.statusCode) else {
            return nil
        }
        return Self.classifyHeaders(
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
            icyMetaInt: http.value(forHTTPHeaderField: "icy-metaint")
        )
    }

    /// "icy-metaint" is an ordinary HTTP metadata header, NOT evidence of a
    /// legacy non-HTTP `ICY 200 OK` status line. Never emit application/x-icy
    /// automatically; that MIME explicitly forces Apolo's FFmpeg live route.
    static func classifyHeaders(
        contentType: String,
        icyMetaInt: String?
    ) -> (transport: RadioTransport, hint: String?) {
        let mime = contentType
            .split(separator: ";", maxSplits: 1)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if mime.contains("mpegurl") || mime.contains("m3u8") {
            return (.hls, "application/vnd.apple.mpegurl")
        }
        if mime.contains("ogg") || mime.contains("opus") {
            return (.ffmpeg, "audio/ogg")
        }
        if mime.contains("flac") {
            return (.ffmpeg, "audio/flac")
        }
        let nativeHint: String?
        if mime.contains("mpeg") || mime.contains("mp3") {
            nativeHint = "audio/mpeg"
        } else if mime.contains("aac") {
            nativeHint = "audio/aac"
        } else {
            nativeHint = nil
        }
        if let icyMetaInt, (Int(icyMetaInt) ?? 0) > 0 {
            return (.icy, nativeHint)
        }
        return (.direct, nativeHint)
    }
}
