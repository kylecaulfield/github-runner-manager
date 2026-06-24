import Foundation

/// GitHub REST API response models.
///
/// All of these are decoded by `GitHubAPI` using a `JSONDecoder` whose
/// `keyDecodingStrategy` is `.convertFromSnakeCase`. That means the GitHub
/// snake_case JSON keys (`tag_name`, `browser_download_url`, `total_count`,
/// `expires_at`, …) map automatically onto the camelCase Swift property names
/// below. Do NOT add explicit `CodingKeys` that reintroduce snake_case here —
/// the decoder already handles the conversion.

/// Response of POST .../actions/runners/registration-token and .../remove-token.
/// `expires_at` is intentionally kept as a `String` (raw ISO-8601 with offset, e.g.
/// "2020-01-22T12:13:35.123-08:00") so we never have to fight date-format parsing;
/// the token is transient and discarded after use.
struct RegistrationToken: Codable, Equatable {
    let token: String
    let expiresAt: String
}

/// A single downloadable asset attached to a GitHub release.
struct GitHubAsset: Codable, Equatable {
    let name: String
    let browserDownloadUrl: URL
    let size: Int?
}

/// A GitHub release (we only ever fetch actions/runner's latest release).
struct GitHubRelease: Codable, Equatable {
    let tagName: String   // e.g. "v2.335.1"
    let name: String?
    let assets: [GitHubAsset]

    /// Normalized version string with any leading 'v' / whitespace stripped, e.g. "2.335.1".
    var version: String { Version.normalize(tagName) }

    /// The macOS Apple-Silicon runner asset.
    ///
    /// GitHub names this asset `actions-runner-osx-arm64-<version>.tar.gz`
    /// (the version embedded here has NO leading 'v', unlike `tagName`). We match by
    /// the documented prefix + extension rather than reconstructing the URL, since the
    /// release JSON already gives us a valid (possibly signed-redirecting) download URL.
    func macOSArm64Asset() -> GitHubAsset? {
        assets.first { asset in
            asset.name.hasPrefix("actions-runner-osx-arm64-") && asset.name.hasSuffix(".tar.gz")
        }
    }
}

/// A label attached to a self-hosted runner (from GET .../actions/runners).
/// `type` is "read-only" (built-in) or "custom"; kept optional for forward-compat.
struct APILabel: Codable, Equatable {
    let name: String
    let type: String?
}

/// A self-hosted runner as reported by the GitHub API. Labels live server-side only
/// (they are NOT in the on-disk `.runner`), so this is the source of truth for labels.
struct APIRunner: Codable, Equatable {
    let id: Int
    let name: String
    let os: String?
    let status: String?
    let busy: Bool?
    let labels: [APILabel]
}

/// Envelope of GET .../actions/runners (paginated; `total_count` -> `totalCount`).
struct APIRunnersResponse: Codable {
    let totalCount: Int
    let runners: [APIRunner]
}
