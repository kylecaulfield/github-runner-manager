import Foundation

/// Parsed representation of a runner install's `.runner` JSON file (RunnerSettings).
///
/// IMPORTANT: The keys in `.runner` are ALREADY camelCase on disk
/// (e.g. `agentId`, `agentName`, `gitHubUrl`, `serverUrl`, `workFolder`), so the
/// decoder used to read this type MUST NOT apply `.convertFromSnakeCase`. Doing so
/// would mangle keys (e.g. `gitHubUrl` -> looking for `git_hub_url`) and silently
/// drop values. The loader lives in `RunnerDiscovery.parseRunnerConfig`.
///
/// Every field is optional so that a partially-written, older, or future `.runner`
/// still decodes cleanly. Unknown keys (e.g. `skipSessionRecover`, `monitorSocketAddress`,
/// `useV2Flow`, `useRunnerAdminFlow`, `serverUrlV2`) are simply ignored because we only
/// declare the keys we care about — `Decodable` ignores any JSON keys without a matching
/// `CodingKey`.
struct RunnerConfig: Codable, Equatable {
    var agentId: Int?
    var agentName: String?
    var poolId: Int?
    var poolName: String?
    var serverUrl: String?
    var gitHubUrl: String?
    var workFolder: String?
    var disableUpdate: Bool?
    var ephemeral: Bool?

    // ASSUMPTION: The `.runner` file stores keys in camelCase exactly as listed in
    // RESEARCH.md (RunnerSettings schema). We rely on the default key-decoding
    // strategy (no conversion); the decoder configured in RunnerDiscovery must NOT
    // set keyDecodingStrategy = .convertFromSnakeCase for this type.
    enum CodingKeys: String, CodingKey {
        case agentId
        case agentName
        case poolId
        case poolName
        case serverUrl
        case gitHubUrl
        case workFolder
        case disableUpdate
        case ephemeral
    }
}
