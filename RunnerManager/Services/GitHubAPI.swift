import Foundation

/// Thin async wrapper over the GitHub REST API for the subset of endpoints RunnerManager needs:
/// minting registration / remove tokens, listing & deleting self-hosted runners, and fetching the
/// latest `actions/runner` release.
///
/// SECURITY: the PAT (`token`) is held transiently for the lifetime of a single API instance and is
/// sent ONLY as a `Authorization: Bearer` header to api.github.com. It is never logged, persisted, or
/// surfaced. Release downloads (handled elsewhere) deliberately use a `token: nil` instance so the PAT
/// is never forwarded across the redirect to the signed object store.
struct GitHubAPI {
    /// Fine-grained (or classic) PAT. `nil` is allowed: the public release endpoint works
    /// unauthenticated (subject to the lower 60/hr unauthenticated rate limit).
    let token: String?
    let session: URLSession

    init(token: String?, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// GitHub's REST API host. All runner/release endpoints hang off this base.
    private static let apiBase = "https://api.github.com"

    /// All GitHub JSON we decode is snake_case (`tag_name`, `browser_download_url`, `total_count`,
    /// `expires_at`, …); the model property names are camelCase, so we let the decoder convert.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: - Self-hosted runner endpoints

    /// POST `…/actions/runners/registration-token` — mints a short-lived (~1h) token used by
    /// `config.sh --token` to register a NEW runner. No request body; success is 201.
    /// Requires the PAT to have repository/org **Administration: Read and write**.
    func registrationToken(scope: RunnerScope) async throws -> RegistrationToken {
        let url = try runnerEndpointURL(scope: scope, suffix: "/actions/runners/registration-token")
        let data = try await send(url: url, method: "POST", expecting: [201], scopeForHints: scope)
        return try decode(RegistrationToken.self, from: data, url: url)
    }

    /// POST `…/actions/runners/remove-token` — mints a short-lived token used by
    /// `config.sh remove --token` to de-register a runner. No request body; success is 201.
    /// Requires **Administration: Read and write** like `registrationToken`.
    func removeToken(scope: RunnerScope) async throws -> RegistrationToken {
        let url = try runnerEndpointURL(scope: scope, suffix: "/actions/runners/remove-token")
        let data = try await send(url: url, method: "POST", expecting: [201], scopeForHints: scope)
        return try decode(RegistrationToken.self, from: data, url: url)
    }

    /// GET `…/actions/runners` — lists registered runners (the only source of server-side labels).
    /// Paginates with `per_page=100`, walking pages until a short page is returned or the
    /// reported `total_count` has been collected. Used for label enrichment.
    func listRunners(scope: RunnerScope) async throws -> [APIRunner] {
        guard let basePath = scope.apiBasePath else {
            throw AppError.generic("unsupported scope")
        }
        let perPage = 100
        var page = 1
        var collected: [APIRunner] = []

        while true {
            // Build `…/actions/runners?per_page=100&page=N`.
            guard var components = URLComponents(string: Self.apiBase + basePath + "/actions/runners") else {
                throw AppError.generic("Could not build runner list URL for \(scope.displayName).")
            }
            components.queryItems = [
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            guard let url = components.url else {
                throw AppError.generic("Could not build runner list URL for \(scope.displayName).")
            }

            let data = try await send(url: url, method: "GET", expecting: [200], scopeForHints: scope)
            let response = try decode(APIRunnersResponse.self, from: data, url: url)
            collected.append(contentsOf: response.runners)

            // Stop once we've seen everything the server reported, or once a page comes back short
            // (the last page is < perPage), or if a page returns nothing (defensive against loops).
            if response.runners.count < perPage { break }
            if collected.count >= response.totalCount { break }
            page += 1
        }
        return collected
    }

    /// DELETE `…/actions/runners/{id}` — removes a runner registration via the API (no remove-token
    /// needed). Success is 204. Requires **Administration: Read and write**.
    func deleteRunner(scope: RunnerScope, id: Int) async throws {
        guard let basePath = scope.apiBasePath else {
            throw AppError.generic("unsupported scope")
        }
        guard let url = URL(string: Self.apiBase + basePath + "/actions/runners/\(id)") else {
            throw AppError.generic("Could not build runner delete URL for \(scope.displayName).")
        }
        _ = try await send(url: url, method: "DELETE", expecting: [204], scopeForHints: scope)
    }

    // MARK: - Releases

    /// GET `…/repos/actions/runner/releases/latest` — the latest published runner release.
    /// This endpoint is public, so it works without a PAT (auth only raises the rate limit).
    func latestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: Self.apiBase + "/repos/actions/runner/releases/latest") else {
            throw AppError.generic("Could not build latest-release URL.")
        }
        let data = try await send(url: url, method: "GET", expecting: [200], scopeForHints: nil)
        return try decode(GitHubRelease.self, from: data, url: url)
    }

    // MARK: - Helpers

    /// Build the full URL for a runner endpoint from `scope.apiBasePath`, e.g.
    /// `https://api.github.com/repos/owner/repo/actions/runners/registration-token`.
    /// Throws `.generic("unsupported scope")` for `.unknown` scopes (no usable API path).
    private func runnerEndpointURL(scope: RunnerScope, suffix: String) throws -> URL {
        guard let basePath = scope.apiBasePath else {
            throw AppError.generic("unsupported scope")
        }
        guard let url = URL(string: Self.apiBase + basePath + suffix) else {
            throw AppError.generic("Could not build URL for \(scope.displayName).")
        }
        return url
    }

    /// Performs a request and returns the body on a 2xx whose status is in `expecting`.
    /// On any other status, parses GitHub's `{"message": …}` body into an `AppError.github`,
    /// adding an Administration-permission hint for 401/403/404 (see `errorMessage`).
    private func send(url: URL, method: String, expecting: [Int], scopeForHints: RunnerScope?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Required GitHub headers. We pin the API version per GitHub's recommendation.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub expects a User-Agent on every request; identify ourselves (no PAT is in this header).
        request.setValue("RunnerManager", forHTTPHeaderField: "User-Agent")
        // Authorization is sent ONLY when a PAT is present (release reads work unauthenticated).
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Surface transport failures (offline, DNS, TLS) as a github error so callers have one path.
            throw AppError.github(status: -1, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.github(status: -1, message: "No HTTP response from \(url.host ?? "GitHub").")
        }

        if expecting.contains(http.statusCode) {
            return data
        }

        // Non-2xx (or unexpected 2xx): pull GitHub's error message and build a helpful AppError.
        let message = Self.errorMessage(status: http.statusCode, body: data, scope: scopeForHints, isWriteEndpoint: method != "GET")
        throw AppError.github(status: http.statusCode, message: message)
    }

    /// Extract `{"message": …}` from a GitHub error body, then append context-specific guidance for
    /// the auth/permission statuses (401/403/404). A 404 on a runner endpoint frequently means the PAT
    /// lacks the **Administration** permission rather than a truly missing resource, so we say so.
    private static func errorMessage(status: Int, body: Data, scope: RunnerScope?, isWriteEndpoint: Bool) -> String {
        // Try to surface GitHub's own message; fall back to a generic phrase.
        var message = "GitHub request failed."
        if let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let serverMessage = parsed["message"] as? String,
           !serverMessage.isEmpty {
            message = serverMessage
        }

        switch status {
        case 401, 403:
            if scope != nil {
                // Scoped/authed runner endpoint: a 401/403 almost always means the PAT is missing or
                // lacks the required permission, so make that explicit.
                message += " (check the PAT and that it has Administration: Read and write)"
            } else {
                // Public (unauthenticated) release read: a 403 here is almost always rate limiting,
                // NOT a permissions problem — the Administration hint would be misleading.
                message += " (this is usually GitHub API rate limiting for unauthenticated requests; set a PAT or wait and retry)"
            }
        case 404 where scope != nil:
            // For runner endpoints a 404 is usually a permissions problem, not a missing resource.
            if isWriteEndpoint {
                message += " (a 404 here usually means the PAT is missing the Administration: Read and write permission for this repository/organization)"
            } else {
                message += " (if you expected this to exist, the PAT may be missing the Administration permission for this repository/organization)"
            }
        default:
            break
        }
        return message
    }

    /// Decode JSON into `T`, mapping any failure to `AppError.parse` with the endpoint for context.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL) throws -> T {
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            throw AppError.parse("Failed to parse GitHub response from \(url.path): \(error.localizedDescription)")
        }
    }
}
