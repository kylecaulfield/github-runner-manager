import Foundation

/// Pure filesystem discovery of self-hosted GitHub Actions runner installs on this Mac.
///
/// This service does NOT run any subprocess and makes NO network calls — it only reads the
/// local filesystem — so it is safe to invoke from a background `Task`/`Task.detached`. The
/// resulting `Runner` values carry only discovery-time facts (`status` stays `.unknown`,
/// versions/labels stay nil/empty); live enrichment happens later in `ServiceController`,
/// `VersionReader`, and `GitHubAPI`.
enum RunnerDiscovery {

    // MARK: - Constants

    /// Directory names we never descend into while scanning for installs. These are the
    /// runner's own large/working subtrees plus common noise — recursing into them wastes
    /// time and can never contain a *separate* runner install.
    private static let skippedDirectoryNames: Set<String> = [
        "_work", "_diag", "externals", "bin", "node_modules"
    ]

    /// The three on-disk markers that, together, identify a runner install directory.
    private static let configScriptName = "config.sh"
    private static let serviceScriptName = "svc.sh"
    private static let dotRunnerName = ".runner"
    private static let dotServiceName = ".service"

    // MARK: - Public API

    /// Pure filesystem scan (no Process, no network). Safe to call from a background task.
    ///
    /// For each root: if the root directory itself is a runner install, it is included as-is;
    /// otherwise the scan descends up to `maxDepth` levels, skipping `_work`, `_diag`,
    /// `externals`, `bin`, `node_modules`, and hidden directories (names starting with "."),
    /// collecting every install directory it finds. Results are de-duplicated by install path
    /// (a runner reachable from two roots appears once).
    ///
    /// - Parameters:
    ///   - roots: The directories to scan (already tilde-expanded by the caller).
    ///   - maxDepth: How many levels below each root to descend. `maxDepth <= 0` means
    ///     "consider only the root itself".
    static func discover(roots: [URL], maxDepth: Int) -> [Runner] {
        var seenPaths = Set<String>()
        var results: [Runner] = []

        for root in roots {
            for installDir in installDirectories(under: root, maxDepth: maxDepth) {
                // Identity is the standardized path; collapse duplicates across roots.
                let key = installDir.standardizedFileURL.path
                if seenPaths.insert(key).inserted {
                    results.append(makeRunner(installPath: installDir))
                }
            }
        }
        return results
    }

    /// A directory is a runner install iff it directly contains `config.sh` AND `svc.sh`
    /// AND `.runner`. (`.runner` is only written once a runner has been configured, so its
    /// presence distinguishes a real install from an unpacked-but-unconfigured tarball.)
    static func isRunnerInstall(_ directory: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        func fileExists(_ name: String) -> Bool {
            let path = directory.appendingPathComponent(name).path
            // The markers must be regular files, not directories.
            return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }

        return fileExists(configScriptName)
            && fileExists(serviceScriptName)
            && fileExists(dotRunnerName)
    }

    /// Decode the install's `.runner` JSON, or return nil if it is missing/unreadable/invalid.
    ///
    /// Uses a plain `JSONDecoder` with the DEFAULT key strategy. The `.runner` keys are already
    /// camelCase on disk (`agentId`, `gitHubUrl`, `serverUrl`, …), so applying
    /// `.convertFromSnakeCase` here would mangle them (e.g. look for `git_hub_url`) and silently
    /// drop values. Unknown keys decode harmlessly because `RunnerConfig` only declares the
    /// keys it cares about.
    static func parseRunnerConfig(at directory: URL) -> RunnerConfig? {
        let dotRunner = directory.appendingPathComponent(dotRunnerName)
        guard let data = try? Data(contentsOf: dotRunner) else { return nil }
        // NOTE: do NOT set keyDecodingStrategy = .convertFromSnakeCase (see doc comment).
        let decoder = JSONDecoder()
        return try? decoder.decode(RunnerConfig.self, from: data)
    }

    /// Resolve the launchd service label and LaunchAgent plist URL from the install's `.service`
    /// file, handling both platforms' formats:
    ///
    ///  - macOS: the `.service` file contains the ABSOLUTE plist path, e.g.
    ///    `/Users/me/Library/LaunchAgents/actions.runner.owner-repo.name.plist`. We take the
    ///    plist's basename minus `.plist` as the label, and the path itself as `plistPath`.
    ///  - Linux/systemd: the `.service` file contains just the unit name, e.g.
    ///    `actions.runner.owner-repo.name.service`. We strip a trailing `.service` to get the
    ///    label; there is no plist, so `plistPath` is nil.
    ///
    /// Returns `(nil, nil)` when the `.service` file is missing or empty; `makeRunner` then
    /// falls back to a constructed label.
    static func parseServiceFile(at directory: URL) -> (label: String?, plistPath: URL?) {
        let serviceFile = directory.appendingPathComponent(dotServiceName)
        guard let raw = try? String(contentsOf: serviceFile, encoding: .utf8) else {
            return (nil, nil)
        }
        // The file is a single line; be tolerant of trailing newlines/whitespace and, in case a
        // tool ever writes more than one line, use the first non-empty line.
        let content = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !content.isEmpty else { return (nil, nil) }

        if content.hasSuffix(".plist") {
            // macOS: absolute plist path. Label is the basename without ".plist".
            let plistURL = URL(fileURLWithPath: content)
            let label = plistURL.deletingPathExtension().lastPathComponent
            return (label.isEmpty ? nil : label, plistURL)
        }

        if content.hasSuffix(".service") {
            // Linux/systemd unit name: strip the trailing ".service" to get the label.
            let label = String(content.dropLast(".service".count))
            return (label.isEmpty ? nil : label, nil)
        }

        // ASSUMPTION: any other single-line content is treated as the bare service label
        // (no extension to strip, and no plist path available).
        return (content, nil)
    }

    /// Build a `Runner` from an install directory, combining the parsed `.runner`, the derived
    /// scope, and the service label/plist. When `.service` is absent, the label is constructed
    /// as `actions.runner.<sanitized-scope>.<name>` (matching svc.sh's `SVC_NAME` scheme) and
    /// the plist path is derived as `~/Library/LaunchAgents/<label>.plist`.
    static func makeRunner(installPath: URL) -> Runner {
        // Normalize so `id` (== installPath.path) is stable regardless of trailing slashes
        // or `..`/`.` components in the discovered URL.
        let normalizedInstall = installPath.standardizedFileURL

        let config = parseRunnerConfig(at: normalizedInstall)

        // Name: configured agent name when present, else the install dir's last component.
        let name: String = {
            if let agentName = config?.agentName, !agentName.isEmpty {
                return agentName
            }
            return normalizedInstall.lastPathComponent
        }()

        // Scope from the configured gitHubUrl; empty/missing URL -> .unknown("").
        let scope = RunnerScope.parse(from: config?.gitHubUrl ?? "")

        // Prefer the authoritative label/plist from `.service`; otherwise construct a fallback.
        let parsedService = parseServiceFile(at: normalizedInstall)
        let label: String?
        let plistPath: URL?
        if let serviceLabel = parsedService.label, !serviceLabel.isEmpty {
            label = serviceLabel
            // Use the plist path from `.service` when available (macOS); otherwise derive the
            // conventional LaunchAgents path from the label so the UI/logs can still resolve it.
            plistPath = parsedService.plistPath ?? launchAgentPlistURL(for: serviceLabel)
        } else {
            // No `.service` on disk: construct the label svc.sh *would* use.
            let constructed = constructedServiceLabel(scope: scope, name: name)
            label = constructed
            plistPath = constructed.map(launchAgentPlistURL(for:))
        }

        return Runner(
            id: normalizedInstall.path,
            installPath: normalizedInstall,
            name: name,
            config: config,
            scope: scope,
            serviceLabel: label,
            servicePlistPath: plistPath
        )
    }

    // MARK: - Scanning internals

    /// Collect install directories at/under `root` up to `maxDepth` levels deep.
    ///
    /// Depth semantics: `root` is depth 0. If the root itself is an install it is returned and
    /// we do NOT descend into it (a runner install never contains another install). Otherwise
    /// each immediate subdirectory is depth 1, and so on until `maxDepth` is reached.
    private static func installDirectories(under root: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default

        // The root must be an existing directory to be worth scanning.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var found: [URL] = []

        // Iterative DFS with explicit depth tracking (avoids deep recursion and lets us cap depth).
        var stack: [(url: URL, depth: Int)] = [(root.standardizedFileURL, 0)]

        while let (dir, depth) = stack.popLast() {
            if isRunnerInstall(dir) {
                // Found an install: record it and do not descend further into it.
                found.append(dir)
                continue
            }

            // Only descend if we have not yet reached the depth limit.
            guard depth < maxDepth else { continue }

            for child in childDirectories(of: dir) {
                stack.append((child, depth + 1))
            }
        }

        return found
    }

    /// The immediate subdirectories of `directory` worth descending into: real directories
    /// (following symlinks would risk cycles, so we skip symlinks), excluding hidden names
    /// (leading ".") and the well-known runner/noise directories.
    private static func childDirectories(of directory: URL) -> [URL] {
        let fm = FileManager.default
        // .skipsHiddenFiles also drops dotfiles like `.runner`, which we don't want to descend
        // into anyway; combined with the explicit "leading dot" check below it's belt-and-braces.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            // Unreadable directory (e.g. another user's install, POSIX-denied): skip silently.
            return []
        }

        var children: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }                    // hidden dir
            if skippedDirectoryNames.contains(name) { continue }   // runner internals / noise

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Skip symlinks to avoid traversal cycles and following links out of the search root.
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                children.append(entry.standardizedFileURL)
            }
        }
        return children
    }

    // MARK: - Service label construction

    /// Construct the launchd service label svc.sh would generate for this runner:
    /// `actions.runner.<sanitized scope>.<sanitized name>`.
    ///
    /// Per RESEARCH.md the scope component is `{owner}-{repo}` for repo scope or the
    /// `{org}`/`{enterprise}` name otherwise, and both the scope and runner-name components are
    /// sanitized: spaces become `_`, and any character outside `[0-9a-zA-Z._-]` becomes `-`.
    /// (svc.sh may additionally truncate very long names with a random suffix — we cannot
    /// reproduce that, which is exactly why `.service` is preferred when present.)
    ///
    /// Returns nil only when there is no usable name component (which should not happen for a
    /// real install, since the name defaults to the install dir's basename).
    private static func constructedServiceLabel(scope: RunnerScope, name: String) -> String? {
        let scopeComponent: String
        switch scope {
        case let .repo(owner, repo):
            scopeComponent = "\(owner)-\(repo)"
        case let .org(org):
            scopeComponent = org
        case let .enterprise(enterprise):
            scopeComponent = enterprise
        case .unknown:
            // No reliable scope to embed; svc.sh would use the configured value, which we don't
            // have. Use a stable placeholder so a label can still be constructed.
            scopeComponent = "unknown"
        }

        let scopeSan = sanitizeServiceComponent(scopeComponent)
        let nameSan = sanitizeServiceComponent(name)
        guard !nameSan.isEmpty else { return nil }
        // ASSUMPTION: an empty sanitized scope is still acceptable; the label then collapses an
        // extra dot, which `launchctl` tolerates. Real installs always have a scope component.
        return "actions.runner.\(scopeSan).\(nameSan)"
    }

    /// Sanitize one component of a service label exactly as svc.sh does: replace spaces with `_`,
    /// then replace every remaining character outside `[0-9a-zA-Z._-]` with `-`.
    private static func sanitizeServiceComponent(_ raw: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if scalar == " " {
                result.append("_")
            } else if isAllowedServiceScalar(scalar) {
                result.append(scalar)
            } else {
                result.append("-")
            }
        }
        return String(result)
    }

    /// Whether a scalar is in the allowed set `[0-9a-zA-Z._-]` for a service-label component.
    private static func isAllowedServiceScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."z", "A"..."Z", ".", "_", "-":
            return true
        default:
            return false
        }
    }

    /// `~/Library/LaunchAgents/<label>.plist` resolved against the current user's real home.
    private static func launchAgentPlistURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }
}
