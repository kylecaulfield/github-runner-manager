import SwiftUI

/// A single row in the sidebar list representing one discovered runner.
///
/// Layout (left → right):
///   [status dot]  name                          version  [Update]  [spinner]
///                 scope.displayName (secondary)
///
/// The row is a pure presentation of the `Runner` model plus the app's busy set: it reads
/// `AppState.busyRunnerIDs` to decide whether to show an in-flight spinner, but it performs
/// no actions itself (selection/navigation is handled by the enclosing `List`). It never
/// touches services, the network, or secrets.
struct RunnerRowView: View {
    /// The runner this row displays. Passed by value; the list owns the source of truth.
    let runner: Runner

    /// The app state is observed so the busy spinner appears/disappears live as actions
    /// (start/stop/update/remove) begin and end for this runner.
    @EnvironmentObject private var appState: AppState

    /// True while an action for this runner is in flight (drives the trailing spinner and
    /// dims the row slightly so the user sees it is temporarily acted upon).
    private var isBusy: Bool {
        appState.busyRunnerIDs.contains(runner.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status severity → colored dot (green/orange/red/gray). Reflects the LOCAL
            // launchd service status.
            StatusDot(status: runner.status)

            // GitHub's server-side view (online/offline + busy), shown only when known
            // (i.e. a PAT enrichment matched this runner by name). nil → omit entirely so
            // we never imply an "offline" state we haven't actually observed.
            if let online = runner.gitHubOnline {
                APIStateBadge(online: online, busy: runner.isBusyOnGitHub)
            }

            // Name (primary) over scope (secondary). Both single-line and truncated so long
            // owner/repo strings don't blow out the sidebar width.
            VStack(alignment: .leading, spacing: 2) {
                Text(runner.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(scopeSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Trailing cluster: installed version, an "Update" badge when newer is available,
            // and a small progress spinner while this runner is busy.
            HStack(spacing: 8) {
                if let version = runner.installedVersion, !version.isEmpty {
                    Text(version)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if runner.updateAvailable {
                    UpdateBadge()
                }

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        // Constrain the spinner so it doesn't change the row height.
                        .frame(width: 14, height: 14)
                        .accessibilityLabel(Text("Working"))
                }
            }
        }
        .padding(.vertical, 2)
        // Dim the row slightly while busy to reinforce the in-flight state.
        .opacity(isBusy ? 0.6 : 1.0)
        // Collapse the row into a single, descriptive accessibility element.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Secondary line under the name. We show the runner's scope (owner/repo, org, or
    /// enterprises/name). For an unparseable scope this is just the raw URL.
    private var scopeSubtitle: String {
        runner.scope.displayName
    }

    /// A combined description for assistive technologies: name, scope, status, and version.
    private var accessibilityLabel: String {
        var parts: [String] = [runner.name, runner.scope.displayName, runner.status.shortLabel]
        if let online = runner.gitHubOnline {
            parts.append(online ? "GitHub online" : "GitHub offline")
            if runner.isBusyOnGitHub {
                parts.append("running a job")
            }
        }
        if let version = runner.installedVersion, !version.isEmpty {
            parts.append("version \(version)")
        }
        if runner.updateAvailable {
            parts.append("update available")
        }
        if isBusy {
            parts.append("working")
        }
        return parts.joined(separator: ", ")
    }
}
