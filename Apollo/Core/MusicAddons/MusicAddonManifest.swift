import Foundation

/// The MVP accepts declarative, HTTPS-only JSON providers. It deliberately
/// does not execute remotely supplied scripts or download executable code.
enum MusicAddonCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case search
    case catalog
    case stream
    case lyrics
    case metadata
    case history
}

struct MusicAddonManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let description: String?
    let capabilities: [MusicAddonCapability]
    /// Keys are capability names; values are same-origin absolute paths.
    let endpoints: [String: String]
    /// Present for Stremio addons; nil for native Apollo v1 manifests.
    var protocolKind: MusicAddonProtocolKind? = nil
    var stremio: StremioDescriptor? = nil
}

enum MusicAddonProtocolKind: String, Codable, Sendable, Equatable {
    case apolloV1
    case stremio
}

/// The subset of a Stremio manifest needed to search and resolve audio.
struct StremioDescriptor: Codable, Sendable, Equatable {
    struct Resource: Codable, Sendable, Equatable {
        let name: String
    }
    struct Extra: Codable, Sendable, Equatable {
        let name: String
    }
    struct Catalog: Codable, Sendable, Equatable {
        let type: String
        let id: String
        let name: String?
        let extra: [Extra]?
    }
    struct Setting: Codable, Sendable, Equatable {
        struct Option: Codable, Sendable, Equatable {
            let value: String
            let label: String?
        }
        let key: String
        let type: String?
        let label: String?
        let options: [Option]?
        /// Stremio/Eclipse addons may declare toggle defaults as JSON booleans,
        /// not strings (e.g. NullBeat Atmos). Normalize scalar values so an
        /// optional setting never invalidates the entire addon manifest.
        let `default`: String?

        enum CodingKeys: String, CodingKey {
            case key, type, label, options, `default`
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            options = try container.decodeIfPresent([Option].self, forKey: .options)
            if let string = try? container.decode(String.self, forKey: .default) {
                self.default = string
            } else if let boolean = try? container.decode(Bool.self, forKey: .default) {
                self.default = boolean ? "true" : "false"
            } else if let integer = try? container.decode(Int.self, forKey: .default) {
                self.default = String(integer)
            } else if let number = try? container.decode(Double.self, forKey: .default),
                      number.isFinite {
                self.default = String(number)
            } else {
                // Unsupported optional default types must not block the
                // provider's validated capabilities and required fields.
                self.default = nil
            }
        }
    }
    let resources: [Resource]
    let types: [String]
    let catalogs: [Catalog]
    /// Stremio manifests that carry music wrap tracks as movie/series items;
    /// the declared content type is the only way to tell them apart.
    var contentType: String? = nil
    var settings: [Setting]? = nil

    /// Eclipse offers direct /search and /resolve resources. A manifest may
    /// advertise these alongside browse catalogs; Stremio's search= catalog
    /// extra must not override the explicit Eclipse resource contract.
    var usesEclipseRouting: Bool {
        let names = Set(resources.map { $0.name.lowercased() })
        return !names.isDisjoint(with: ["search", "resolve", "isrc"])
    }

    func offers(_ resource: String) -> Bool {
        resources.contains { $0.name.caseInsensitiveCompare(resource) == .orderedSame }
    }
}

/// Audio tiers an addon says it can serve. The manifest settings are the only
/// declaration we have; addons without them are assumed to be FLAC sources.
struct AddonCapabilities: Sendable, Equatable {
    var cd = false
    var hiRes = false
    var atmos = false
    var aac320 = false

    var hasLossless: Bool { cd || hiRes }
    var hasAny: Bool { hasLossless || aac320 || atmos }

    mutating func formUnion(_ other: AddonCapabilities) {
        cd = cd || other.cd
        hiRes = hiRes || other.hiRes
        atmos = atmos || other.atmos
        aac320 = aac320 || other.aac320
    }
}

extension MusicAddonInstallation {
    var audioCapabilities: AddonCapabilities {
        guard let descriptor = manifest.stremio else { return AddonCapabilities() }
        let settings = descriptor.settings ?? []
        var caps = AddonCapabilities()
        let quality = settings.first { $0.key.lowercased() == "quality" }
        let values = (quality?.options ?? []).map { $0.value.lowercased() }
        if values.isEmpty || values == ["auto"] {
            // No declared options: treat it as a FLAC source (Nebula does this).
            caps.cd = true
            caps.hiRes = true
        } else {
            for value in values {
                if value.contains("hires") || value.contains("hi-res") || value.contains("hi_res") {
                    caps.hiRes = true
                }
                if value.contains("lossless") || value.contains("cd") || value == "flac" {
                    caps.cd = true
                }
                if value.contains("320") || value.contains("high") || value.contains("aac") {
                    caps.aac320 = true
                }
                if value.contains("atmos") {
                    caps.atmos = true
                }
                if value == "max" {
                    caps.cd = true
                    caps.hiRes = true
                }
            }
        }
        if settings.contains(where: { $0.key.lowercased() == "atmos" }) {
            caps.atmos = true
        }
        return caps
    }
}

enum MusicAddonError: Error, Equatable, LocalizedError {
    case insecureManifestURL
    case invalidManifest
    case unsupportedSchema
    case invalidIdentity
    case invalidCapabilities
    case unsafeEndpoint
    case alreadyInstalled
    case notInstalled
    case requiresCapabilityApproval
    case tooManyAddons

    var errorDescription: String? {
        switch self {
        case .insecureManifestURL: return String(localized: "Addons must use a public HTTPS manifest URL.")
        case .invalidManifest: return String(localized: "This is not a valid Apollo Music Addon manifest. Check that the provider supports the Apollo v1 music protocol.")
        case .unsupportedSchema: return String(localized: "This addon requires an unsupported manifest version.")
        case .invalidIdentity: return String(localized: "The addon name, identifier or version is invalid.")
        case .invalidCapabilities: return String(localized: "The addon declares invalid capabilities.")
        case .unsafeEndpoint: return String(localized: "An addon endpoint is invalid or unsafe.")
        case .alreadyInstalled: return String(localized: "This addon is already installed.")
        case .notInstalled: return String(localized: "This addon is not installed.")
        case .requiresCapabilityApproval: return String(localized: "The addon update requires approval for new permissions.")
        case .tooManyAddons: return String(localized: "The addon limit has been reached.")
        }
    }
}

struct MusicAddonPackage: Sendable {
    let manifestURL: URL
    let manifest: MusicAddonManifest

    /// The URL (not just the manifest id) scopes provider identity. Distinct
    /// hosts may use the same developer-chosen id without colliding.
    var installationKey: String { "\(manifestURL.absoluteString)#\(manifest.id)" }

    /// The caller may only use a capability declared and validated above.
    func endpointURL(for capability: MusicAddonCapability) -> URL? {
        guard manifest.capabilities.contains(capability),
              let path = manifest.endpoints[capability.rawValue],
              var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Hard-limit untrusted input before JSON decoding. This handles content
    /// already obtained by a separate, policy-enforcing fetcher (future PR).
    static func parse(_ data: Data, from url: URL) throws -> MusicAddonPackage {
        guard let canonical = canonicalManifestURL(url) else { throw MusicAddonError.insecureManifestURL }
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw MusicAddonError.invalidManifest
        }
        if let stremio = Self.parseStremio(data, at: canonical) {
            return stremio
        }
        guard let manifest = try? JSONDecoder().decode(MusicAddonManifest.self, from: data) else {
            throw MusicAddonError.invalidManifest
        }
        guard manifest.schemaVersion == 1 else { throw MusicAddonError.unsupportedSchema }
        guard validIdentifier(manifest.id),
              (1...80).contains(manifest.name.count),
              manifest.name.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.name,
              let version = parseVersion(manifest.version), version.allSatisfy({ $0 >= 0 }),
              (manifest.description?.count ?? 0) <= 500 else {
            throw MusicAddonError.invalidIdentity
        }
        let declared = manifest.capabilities.map(\.rawValue)
        guard !declared.isEmpty,
              declared.count == Set(declared).count,
              declared.count <= MusicAddonCapability.allCases.count,
              Set(declared) == Set(manifest.endpoints.keys) else {
            throw MusicAddonError.invalidCapabilities
        }
        guard manifest.endpoints.values.allSatisfy(safeEndpointPath) else {
            throw MusicAddonError.unsafeEndpoint
        }
        return MusicAddonPackage(manifestURL: canonical, manifest: manifest)
    }

    /// Accepts a Stremio addon manifest (resources/types/catalogs) and maps it
    /// to the internal capability model. Read-only: no scripts, no code.
    private static func parseStremio(_ data: Data, at url: URL) -> MusicAddonPackage? {
        struct RawResource: Decodable {
            let name: String
            init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(),
                   let value = try? container.decode(String.self) {
                    name = value
                    return
                }
                struct Object: Decodable { let name: String }
                name = try Object(from: decoder).name
            }
        }
        struct RawManifest: Decodable {
            let id: String
            let name: String
            let version: String
            let description: String?
            let resources: [RawResource]
            let types: [String]?
            let catalogs: [StremioDescriptor.Catalog]?
            let contentType: String?
            let settings: [StremioDescriptor.Setting]?
        }
        guard let raw = try? JSONDecoder().decode(RawManifest.self, from: data) else { return nil }
        let resources = raw.resources.map { StremioDescriptor.Resource(name: $0.name.lowercased()) }
        let names = Set(resources.map(\.name))
        let catalogs = raw.catalogs ?? []
        let hasSearch = names.contains("search") || catalogs.contains { catalog in
            catalog.extra?.contains { $0.name.lowercased() == "search" } == true
        }
        var capabilities: [MusicAddonCapability] = []
        if hasSearch || names.contains("catalog") { capabilities.append(.search) }
        if names.contains("stream") { capabilities.append(.stream) }
        if names.contains("meta") { capabilities.append(.metadata) }
        guard !capabilities.isEmpty else { return nil }
        let manifest = MusicAddonManifest(
            schemaVersion: 1,
            id: raw.id,
            name: raw.name,
            version: Self.normalizedVersion(raw.version),
            description: raw.description,
            capabilities: capabilities,
            endpoints: [:],
            protocolKind: .stremio,
            stremio: StremioDescriptor(
                resources: resources,
                types: raw.types ?? [],
                catalogs: catalogs,
                contentType: raw.contentType,
                settings: raw.settings
            )
        )
        return MusicAddonPackage(manifestURL: url, manifest: manifest)
    }

    private static func normalizedVersion(_ version: String) -> String {
        parseVersion(version) == nil ? "1.0.0" : version
    }

    private static func validIdentifier(_ id: String) -> Bool {
        guard (3...64).contains(id.count),
              let first = id.first, first.isASCII && first.isLetter,
              let last = id.last, last.isASCII && last.isLetter || last.isNumber else { return false }
        return id.allSatisfy { ch in
            (ch.isASCII && ch.isLowercase && ch.isLetter) ||
            (ch.isASCII && ch.isNumber) || ch == "." || ch == "_" || ch == "-"
        } && !id.contains("..")
    }

    private static func parseVersion(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    private static func safeEndpointPath(_ path: String) -> Bool {
        guard (2...200).contains(path.count), path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("//"), !path.contains("..") else { return false }
        // Restrict to URI path characters that do not require decoding.
        // Prohibits credentials, external origins, query strings, fragments,
        // percent-encoded traversal, redirects encoded into a URL, etc.
        return path.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
            (48...57).contains(byte) || byte == 47 || byte == 95 || byte == 45
        }
    }

    /// Preflight validation must run *before* any network request.
    /// The package is fully validated again after download.
    static func validatedManifestURL(_ url: URL) -> URL? {
        canonicalManifestURL(url)
    }

    private static func canonicalManifestURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              !rawHost.isEmpty, components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil else { return nil }
        let host = rawHost.lowercased()
        let disallowedSuffixes = [".local", ".localhost", ".internal", ".invalid", ".test"]
        guard host.contains("."), host != "localhost", host != "127.0.0.1",
              !host.hasSuffix("."),
              !disallowedSuffixes.contains(where: host.hasSuffix),
              !host.contains(":"),
              !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }),
              !host.hasPrefix("-"), !host.contains("..") else { return nil }
        let rawPath = components.percentEncodedPath
        guard rawPath.hasSuffix("/manifest.json"),
              !rawPath.contains("%"), !rawPath.contains("//"), !rawPath.contains(".."),
              rawPath.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 47 || byte == 95 ||
                  byte == 45 || byte == 46 || byte == 61
              }) else { return nil }
        components.scheme = "https"
        components.host = host
        if components.port == 443 { components.port = nil }
        return components.url
    }
}
