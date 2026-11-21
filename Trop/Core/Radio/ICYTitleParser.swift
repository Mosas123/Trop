import Foundation

/// Cleans the raw `StreamTitle` some stations send. It is not one format:
/// "Artist - Title", "Title by Artist", and often a station suffix such as
/// " - Classic Vinyl on walmradio.com".
struct ParsedICYTitle: Equatable, Sendable {
    let artist: String
    let title: String

    var display: String {
        artist.isEmpty ? title : "\(artist) - \(title)"
    }
}

enum ICYTitleParser {
    private static let genericTitles: Set<String> = [
        "unknown", "untitled", "live", "on air", "advert", "advertisement",
        "commercial", "jingle", "stream", "radio"
    ]

    static func parse(_ raw: String, stationName: String? = nil) -> ParsedICYTitle? {
        var text = raw
            .replacingOccurrences(of: "\u{0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = stripStationSuffix(text, stationName: stationName)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|").union(.whitespaces))
        guard text.count >= 3, text.count <= 160,
              !text.contains("http://"), !text.contains("https://"),
              !text.lowercased().hasPrefix("www.") else { return nil }
        if let station = stationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !station.isEmpty, text.caseInsensitiveCompare(station) == .orderedSame {
            return nil
        }
        guard !genericTitles.contains(text.lowercased()) else { return nil }

        // "Title by Artist" (Classic Vinyl style).
        if let range = text.range(of: " by ", options: [.caseInsensitive, .backwards]),
           range.lowerBound > text.startIndex {
            let title = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let artist = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if isUsable(title, stationName: stationName), isUsableArtist(artist) {
                return ParsedICYTitle(artist: artist, title: title)
            }
        }

        for separator in [" - ", " – ", " — "] {
            if let range = text.range(of: separator) {
                let artist = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let title = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if isUsable(title, stationName: stationName), isUsableArtist(artist) {
                    return ParsedICYTitle(artist: artist, title: title)
                }
            }
        }

        guard isUsable(text, stationName: stationName) else { return nil }
        return ParsedICYTitle(artist: "", title: text)
    }

    private static func stripStationSuffix(_ text: String, stationName: String?) -> String {
        var result = text
        // "... - Station on domain.tld"
        result = result.replacingOccurrences(
            of: #"\s+[-–—]\s+[^-–—]{1,80}?\s+on\s+[\w.-]+\.[a-z]{2,}\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // A trailing " - <station name>" when we know the station.
        if let station = stationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !station.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: station)
            result = result.replacingOccurrences(
                of: #"\s+[-–—]\s+"# + escaped + #"\s*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // " on domain.tld" without a separator.
        result = result.replacingOccurrences(
            of: #"\s+on\s+[\w.-]+\.[a-z]{2,}\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

    private static func isUsable(_ title: String, stationName: String?) -> Bool {
        guard title.count >= 2, title.count <= 140 else { return false }
        guard !genericTitles.contains(title.lowercased()) else { return false }
        if let station = stationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !station.isEmpty, title.caseInsensitiveCompare(station) == .orderedSame {
            return false
        }
        return true
    }

    private static func isUsableArtist(_ artist: String) -> Bool {
        artist.count >= 2 && artist.count <= 100
            && !genericTitles.contains(artist.lowercased())
    }
}
