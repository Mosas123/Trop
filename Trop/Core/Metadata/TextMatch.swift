import Foundation

/// Matching helpers for cross-catalogue metadata. YouTube names differ a lot
/// from Apple/Deezer: auto-generated channels are "Artist - Topic", labels add
/// "VEVO", "Official", "Music", "Records", and tracks carry "(Official Video)",
/// "feat. …", "- Remastered", etc. These helpers strip that noise so the same
/// recording matches across sources — and, just as important, so we *don't*
/// grab a wrong cover ("Drake" must not match "Drake Bell").
enum TextMatch {
    private static let suffixWords: [String] = [
        "official artist channel", "official music video", "official video",
        "official audio", "official", "vevo", "topic", "music", "records",
        "recordings", "channel", "tv"
    ]

    /// Lowercase, diacritic-insensitive, punctuation-light key.
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Song title without bracketed qualifiers or a trailing "feat. …".
    static func normalizeTitle(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(
            of: "\\s*[\\[(][^\\])]*[\\])]", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\s+(-\\s+)?(feat\\.?|ft\\.?|featuring)\\s+.*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        // Drop trailing " - Remastered 2011", "- Live", "- Radio Edit"
        text = text.replacingOccurrences(
            of: "\\s+-\\s+(remaster(ed)?|live|radio edit|album version|single version).*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        // Album editions: "Deluxe Edition", "Special Edition", …
        text = text.replacingOccurrences(
            of: "\\b(deluxe|special|expanded|anniversary|bonus) (edition|version)\\b.*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return normalize(text)
    }

    /// Title as it should be sent to a catalogue search: keeps casing, strips
    /// video/lyrics/remaster suffixes and featured acts.
    static func queryTitle(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(
            of: "\\s*[\\[(][^\\])]*[\\])]", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\s+(-\\s+)?(feat\\.?|ft\\.?|featuring)\\s+.*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "\\s+-\\s+(official\\s+(music\\s+)?(video|audio)|lyrics?|lyric\\s+video|audio|video|visualizer).*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "\\s+-\\s+(remaster(ed)?|live|radio edit|album version|single version).*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Primary artist name, without channel suffixes or featured acts.
    static func normalizeArtist(_ value: String) -> String {
        var text = channelArtistName(value)
        // "Artist - Topic" (YouTube auto-generated channel)
        text = text.replacingOccurrences(
            of: "\\s+-\\s*topic\\s*$", with: "", options: [.regularExpression, .caseInsensitive]
        )
        // Take the first act when several are listed.
        for separator in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", " x "] {
            if let range = text.range(of: separator, options: .caseInsensitive) {
                text = String(text[..<range.lowerBound])
            }
        }
        if let comma = text.firstIndex(of: ",") {
            text = String(text[..<comma])
        }
        var words = normalize(text).split(separator: " ").map(String.init)
        // Trim leading "the"
        if words.first == "the" { words.removeFirst() }
        // Strip known channel/label words from the end.
        while let last = words.last, suffixWords.contains(last) {
            words.removeLast()
        }
        // "AdeleVEVO" (no space) → "adele"
        if words.count == 1, let only = words.first, only.count > 4, only.hasSuffix("vevo") {
            words[0] = String(only.dropLast(4))
        }
        return words.joined(separator: " ")
    }

    /// Artist name to use in a catalogue query (keeps casing, strips noise).
    static func queryArtist(_ value: String) -> String {
        var text = channelArtistName(value)
        text = text.replacingOccurrences(
            of: "\\s+-\\s*topic\\s*$", with: "", options: [.regularExpression, .caseInsensitive]
        )
        for separator in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            if let range = text.range(of: separator, options: .caseInsensitive) {
                text = String(text[..<range.lowerBound])
            }
        }
        for word in suffixWords {
            text = text.replacingOccurrences(
                of: "\\s+\(word)\\s*$", with: "", options: [.regularExpression, .caseInsensitive]
            )
        }
        // Concatenated "ArtistVEVO" / "ArtistOfficial".
        text = text.replacingOccurrences(
            of: "(?<=[a-z0-9])(vevo|official)$", with: "", options: [.regularExpression, .caseInsensitive]
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// VEVO channel names often join the artist's words. Expand camel case
    /// only for that explicit suffix, leaving ordinary stage names untouched.
    static func channelArtistName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4, trimmed.lowercased().hasSuffix("vevo") else { return value }
        return String(trimmed.dropLast(4))
            .replacingOccurrences(of: "(?<=[a-z])(?=[A-Z])", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recording/edition identity must be evaluated BEFORE normalizeTitle
    /// strips all parenthetical qualifiers. Otherwise "Niagara Falls
    /// (Instrumental)" becomes the same title as the vocal album recording.
    static func versionMarkers(_ value: String) -> Set<String> {
        // Read the unstripped title. Parentheses and suffixes can describe a
        // different recording; normalizing them away before matching is unsafe.
        let text = normalize(value)
        let words = Set(text.split(separator: " ").map(String.init))
        var markers: Set<String> = []
        if words.contains("instrumental") || words.contains("instrumentals") {
            markers.insert("instrumental")
        }
        for marker in [
            "karaoke", "remix", "mix", "live", "acoustic", "demo", "cover",
            "slowed", "nightcore", "clean", "explicit", "extended", "bootleg",
            "mashup", "medley", "rework", "edit", "remaster", "remastered",
            "reverb", "tribute"
        ] where words.contains(marker) {
            markers.insert(marker)
        }
        if words.contains("sped"), words.contains("up") {
            markers.insert("sped-up")
        }
        if words.contains("a"), words.contains("cappella")
            || words.contains("acapella") || words.contains("acappella") {
            markers.insert("acappella")
        }
        if text.contains("radio edit") { markers.insert("radio-edit") }
        if text.contains("radio mix") { markers.insert("radio-mix") }
        if text.contains("album version") { markers.insert("album-version") }
        if text.contains("single version") { markers.insert("single-version") }
        if text.contains("en vivo") { markers.insert("live") }
        if text.contains("original mix") { markers.insert("original-mix") }
        return markers
    }

    static func versionsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        versionMarkers(lhs) == versionMarkers(rhs)
    }

    static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard versionsCompatible(lhs, rhs) else { return false }
        let a = normalizeTitle(lhs)
        let b = normalizeTitle(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // Containment only for reasonably long strings, to avoid "Intro" hits.
        if a.count >= 4, b.count >= 4 {
            return a.contains(b) || b.contains(a)
        }
        return false
    }

    /// Karaoke/tribute/sped-up uploads that pollute catalogue matches.
    static func isSuspiciousVersion(_ title: String) -> Bool {
        // Inspect the ORIGINAL label: normalizeTitle deliberately discards
        // "(Instrumental)", "(Karaoke)" and other disqualifying variants.
        let text = normalize(title)
        let markers = [
            "karaoke", "tribute", "made famous", "instrumental",
            "8d audio", "sped up", "nightcore", "reverb",
            "in the style of", "cover by", "originally performed"
        ]
        return markers.contains { text.contains($0) }
    }

    static func albumsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard versionsCompatible(lhs, rhs) else { return false }
        let a = normalizeTitle(lhs)
        let b = normalizeTitle(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if a.count >= 4, b.count >= 4 {
            return a.contains(b) || b.contains(a)
        }
        return false
    }

    static func artistsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizeArtist(lhs)
        let b = normalizeArtist(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let aTokens = a.split(separator: " ")
        let bTokens = b.split(separator: " ")
        // "Drake" vs "Drake Bell" must NOT match: only allow containment when
        // the shorter name has at least two words ("New Order" in "New Order UK").
        if min(aTokens.count, bTokens.count) >= 2 {
            return a.contains(b) || b.contains(a)
        }
        return false
    }
}

extension TextMatch {
    struct RecordingQuery {
        let title: String
        let artist: String
    }

    /// Upload titles may identify the performers more accurately than the
    /// uploader field. Interpret that format only with explicit video markers,
    /// missing credits, or a prefix agreeing with the existing performer.
    static func recordingQuery(title: String, artist: String) -> RecordingQuery {
        let promotional = normalize(title)
        let marked = ["official video", "official music video", "video oficial", "official audio",
                      "audio oficial", "lyric video", "video lyric", "visualizer"].contains { promotional.contains($0) }
        for separator in [" - ", " – ", " — "] {
            guard let range = title.range(of: separator) else { continue }
            let prefix = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let track = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, !track.isEmpty,
               marked || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || artistsMatch(prefix, artist) {
                return RecordingQuery(title: recordingTitle(track), artist: queryArtist(prefix))
            }
        }
        return RecordingQuery(title: recordingTitle(title), artist: queryArtist(artist))
    }

    /// Remove upload labels, preserving meaningful recording versions such as
    /// remix, live, acoustic, remaster and radio edit.
    static func recordingTitle(_ title: String) -> String {
        let label = #"(?:official(?:\s+music)?\s+(?:video|audio)|v[ií]deo\s+oficial|audio\s+oficial|lyric\s+video|lyrics?|letra|visuali[sz]er)"#
        var value = title.replacingOccurrences(
            of: #"\s*[\[(]\s*"# + label + #"\s*[\])]"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"\s+(?:[-–—|]\s*)?"# + label + #"\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"\s*[\[(]\s*(?:feat\.?|ft\.?|featuring)\s+[^\])]*[\])]"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recordingsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard versionsCompatible(lhs, rhs) else { return false }
        let a = normalize(recordingTitle(lhs))
        let b = normalize(recordingTitle(rhs))
        return !a.isEmpty && a == b
    }

    /// Fail-closed policy for substituting audio from another catalogue.
    /// Unlike a search-result ranking, missing performer and missing timing
    /// without an exact album are NOT evidence of recording identity.
    /// A FLAC/Atmos quality label cannot bypass this verification.
    static func verifiedAudioSource(
        wantedTitle: String,
        wantedArtist: String,
        wantedAlbum: String? = nil,
        wantedDuration: Int? = nil,
        candidateTitle: String,
        candidateArtist: String?,
        candidateAlbum: String? = nil,
        candidateDuration: Int? = nil
    ) -> Bool {
        let performer = normalizeArtist(wantedArtist)
        guard !performer.isEmpty,
              let candidateArtist,
              performer == normalizeArtist(candidateArtist),
              recordingsMatch(wantedTitle, candidateTitle) else { return false }

        let requestedRelease = normalize(wantedAlbum ?? "")
        let foundRelease = normalize(candidateAlbum ?? "")
        if !requestedRelease.isEmpty, !foundRelease.isEmpty,
           requestedRelease != foundRelease { return false }

        let releaseVerified = !requestedRelease.isEmpty
            && !foundRelease.isEmpty && requestedRelease == foundRelease
        if let wantedDuration, wantedDuration > 0,
           let candidateDuration, candidateDuration > 0 {
            // Allow codec rounding/lead-in but not a materially different mix.
            return abs(candidateDuration - wantedDuration) <= max(8, wantedDuration / 30)
        }
        return releaseVerified
    }

    /// Catalogue text searches can return no hits when a video's comma-separated
    /// list of performers is sent verbatim. Validate credits after retrieval.
    static func catalogueArtist(_ artist: String) -> String {
        queryArtist(artist.components(separatedBy: ",").first ?? artist)
    }
}
