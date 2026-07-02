import Foundation

/// Where a runner is registered: a single repository, an organization, an enterprise,
/// or an unrecognized URL we couldn't classify. Derived from a runner's `gitHubUrl`
/// (config.sh `--url`).
enum RunnerScope: Equatable, Hashable {
    case repo(owner: String, repo: String)
    case org(String)
    case enterprise(String)
    /// The raw URL we couldn't parse into a known scope.
    case unknown(String)

    /// Parse from a gitHubUrl like `https://github.com/owner/repo` or `https://github.com/org`
    /// or `https://github.com/enterprises/name`. Handles trailing slashes and `.git`.
    static func parse(from gitHubURL: String) -> RunnerScope {
        let trimmed = gitHubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown(gitHubURL) }

        // Isolate the path portion. Prefer URLComponents so query/fragment are dropped,
        // but fall back to manual stripping of the scheme+host when the string isn't a
        // strict URL (still try to be lenient).
        var pathString: String
        if let components = URLComponents(string: trimmed), components.host != nil {
            pathString = components.path
        } else {
            // Strip a leading scheme (e.g. "https://") then the host segment.
            var rest = trimmed
            if let schemeRange = rest.range(of: "://") {
                rest = String(rest[schemeRange.upperBound...])
            }
            // Drop the host: everything up to and including the first "/".
            if let slashIndex = rest.firstIndex(of: "/") {
                pathString = String(rest[slashIndex...])
            } else {
                // No path at all (e.g. "https://github.com") -> nothing to classify.
                return .unknown(gitHubURL)
            }
        }

        // Normalize the path: strip a trailing ".git", trailing slashes, then split.
        if pathString.hasSuffix(".git") {
            pathString = String(pathString.dropLast(4))
        }
        // Split on "/" and discard empty components (handles leading/trailing slashes).
        let segments = pathString.split(separator: "/").map(String.init)

        guard let first = segments.first, !first.isEmpty else {
            return .unknown(gitHubURL)
        }

        // Enterprise: /enterprises/<name>
        if first.lowercased() == "enterprises" {
            if segments.count >= 2, !segments[1].isEmpty {
                return .enterprise(segments[1])
            }
            return .unknown(gitHubURL)
        }

        switch segments.count {
        case 1:
            // /org
            return .org(first)
        default:
            // /owner/repo (ignore any deeper path segments)
            let repo = segments[1]
            if repo.isEmpty {
                return .org(first)
            }
            return .repo(owner: first, repo: repo)
        }
    }

    var displayName: String {
        switch self {
        case let .repo(owner, repo): return "\(owner)/\(repo)"
        case let .org(name): return name
        case let .enterprise(name): return "enterprises/\(name)"
        case let .unknown(raw): return raw
        }
    }

    /// The `https://github.com/…` URL to pass to config.sh `--url`.
    var webURL: String {
        switch self {
        case let .repo(owner, repo): return "https://github.com/\(owner)/\(repo)"
        case let .org(name): return "https://github.com/\(name)"
        case let .enterprise(name): return "https://github.com/enterprises/\(name)"
        case let .unknown(raw): return raw
        }
    }

    /// The GitHub web page that lists this scope's self-hosted runners (for "Open on GitHub").
    var runnersSettingsURL: URL? {
        switch self {
        case let .repo(owner, repo): return URL(string: "https://github.com/\(owner)/\(repo)/settings/actions/runners")
        case let .org(org): return URL(string: "https://github.com/organizations/\(org)/settings/actions/runners")
        case let .enterprise(name): return URL(string: "https://github.com/enterprises/\(name)/settings/actions/runners")
        case .unknown: return nil
        }
    }

    /// API base path for the self-hosted runner endpoints, e.g. `/repos/owner/repo`
    /// or `/orgs/org` or `/enterprises/name`. Returns nil for `.unknown`.
    var apiBasePath: String? {
        switch self {
        case let .repo(owner, repo): return "/repos/\(owner)/\(repo)"
        case let .org(name): return "/orgs/\(name)"
        case let .enterprise(name): return "/enterprises/\(name)"
        case .unknown: return nil
        }
    }

    /// config.sh `--runnergroup` is only valid for org/enterprise scopes; repo scope rejects it.
    var supportsRunnerGroup: Bool {
        switch self {
        case .org, .enterprise: return true
        case .repo, .unknown: return false
        }
    }
}
