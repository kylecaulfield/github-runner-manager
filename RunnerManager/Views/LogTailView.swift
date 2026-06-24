import SwiftUI

/// A live tail of a runner's log files.
///
/// Lets the user pick among the available log sources for a runner (newest `_diag/Runner_*.log`,
/// newest `_diag/Worker_*.log`, launchd stdout/stderr — whichever currently exist), shows the last
/// N lines in a monospaced, scrollable view, and can auto-refresh on the same cadence as status
/// polling. Reading is delegated entirely to `LogReader`, which reads only the trailing bytes of a
/// file off the main thread, so this view never blocks the UI even for large logs.
///
/// THREADING: the actual file read (`LogReader.tail`) is pure filesystem work; we run it in a
/// `Task.detached` so the (potentially several-hundred-KB) read and string decode happen off the
/// main thread, then publish the result back on the main actor.
struct LogTailView: View {
    /// The runner whose logs are shown. Passed in by `RunnerDetailView`.
    let runner: Runner

    /// Settings supply the tail line count and the auto-refresh interval (poll interval).
    @EnvironmentObject private var settings: AppSettings

    // MARK: - Local UI state

    /// The available log sources for this runner, recomputed when the runner changes.
    @State private var sources: [LogSource] = []

    /// The currently selected source's id (== file path). Optional so the picker can show a
    /// placeholder when there are no sources.
    @State private var selectedSourceID: String?

    /// The most recently read tail text for the selected source.
    @State private var tailText: String = ""

    /// Whether auto-refresh is enabled. Off by default so we don't read logs the user isn't watching.
    @State private var autoRefresh: Bool = false

    /// True while a (re)load is in flight, to show a small spinner and avoid overlapping reads.
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlBar

            Divider()

            logBody
        }
        // Recompute the source list whenever the runner identity changes (e.g. selecting a
        // different runner reuses this view). `.task(id:)` also runs once on first appearance.
        .task(id: runner.id) {
            reloadSources()
            await refresh()
        }
        // Drive auto-refresh as a cancellable async loop tied to the toggle + selected source.
        // Changing either restarts the loop; turning the toggle off cancels it.
        .task(id: autoRefreshTaskKey) {
            guard autoRefresh, selectedSourceID != nil else { return }
            await autoRefreshLoop()
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            // Source picker. We bind to an optional id and tag each item with its (optional) id so
            // the selection types line up. A placeholder tag covers the "no source" case.
            Picker("Log", selection: $selectedSourceID) {
                if sources.isEmpty {
                    Text("No logs").tag(String?.none)
                } else {
                    ForEach(sources) { source in
                        Text(source.title).tag(String?.some(source.id))
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(sources.isEmpty)
            // When the user picks a different source, re-read its tail.
            .onChange(of: selectedSourceID) { _ in
                Task { await refresh() }
            }

            Toggle("Auto-refresh", isOn: $autoRefresh)
                .toggleStyle(.checkbox)
                .disabled(selectedSourceID == nil)
                .help("Re-read the log every \(Int(settings.pollIntervalSeconds.rounded())) seconds")

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            // Manual refresh.
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
            .disabled(selectedSourceID == nil || isLoading)

            // Reveal the selected log file in Finder.
            Button {
                if let url = selectedSource?.url {
                    LogReader.revealInFinder(url)
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Reveal log file in Finder")
            .disabled(selectedSource == nil)

            // Open the _diag directory (where Runner_*/Worker_* logs live).
            Button {
                LogReader.revealInFinder(runner.diagDirectory)
            } label: {
                Image(systemName: "folder")
            }
            .help("Open the _diag folder in Finder")
        }
    }

    // MARK: - Log body

    @ViewBuilder
    private var logBody: some View {
        if sources.isEmpty {
            // No diag/launchd logs exist yet (e.g. a freshly-configured runner that hasn't run).
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No logs available yet.")
                    .foregroundColor(.secondary)
                Text("Logs appear once the runner starts or runs a job.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if tailText.isEmpty {
            Text(isLoading ? "Reading…" : "Log is empty.")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } else {
            // Monospaced, horizontally + vertically scrollable, selectable log text. We show the
            // last `settings.logTailLines` lines (computed by LogReader.tail). The text is read-only.
            ScrollView([.vertical, .horizontal]) {
                Text(tailText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 280)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Derived

    /// The currently selected `LogSource`, if any.
    private var selectedSource: LogSource? {
        guard let id = selectedSourceID else { return nil }
        return sources.first { $0.id == id }
    }

    /// A composite key so the auto-refresh `.task` restarts when the toggle, the selected source,
    /// or the poll interval changes (the loop reads the interval each tick, but restarting also
    /// applies a brand-new interval promptly).
    private var autoRefreshTaskKey: String {
        "\(autoRefresh)|\(selectedSourceID ?? "-")|\(settings.pollIntervalSeconds)"
    }

    // MARK: - Loading

    /// Recompute the source list for the current runner and keep / fix the selection.
    ///
    /// Runs on the main actor (it only does cheap directory listings via `LogReader.logSources`,
    /// which stat a handful of files). If the previously-selected source is gone, fall back to the
    /// first available source.
    private func reloadSources() {
        let newSources = LogReader.logSources(for: runner)
        sources = newSources

        // Preserve the selection if it still exists; otherwise pick the highest-priority source.
        if let current = selectedSourceID, newSources.contains(where: { $0.id == current }) {
            // keep current selection
        } else {
            selectedSourceID = newSources.first?.id
        }
    }

    /// Re-read the tail of the selected source off the main thread and publish it.
    ///
    /// Reading is delegated to `LogReader.tail`, which caps the read at ~256 KB from the end of the
    /// file. We hop off-main via `Task.detached` so neither the read nor the UTF-8 decode of a
    /// large tail blocks the UI.
    private func refresh() async {
        guard let source = selectedSource else {
            tailText = ""
            return
        }
        isLoading = true
        defer { isLoading = false }

        let url = source.url
        let lines = max(1, settings.logTailLines)
        // Off-main read; LogReader.tail never throws (returns "" on any IO error).
        let text = await Task.detached(priority: .userInitiated) {
            LogReader.tail(url, lines: lines)
        }.value

        // Only apply if the selection hasn't changed underneath us while we were reading.
        if selectedSourceID == source.id {
            tailText = text
        }
    }

    /// Auto-refresh loop: re-read the selected log, then sleep for the poll interval, until the
    /// surrounding `.task` is cancelled (toggle off / selection change / view disappear).
    ///
    /// We also re-scan the source list each tick so a freshly-rotated `_diag` log (the runner names
    /// these per session and never reuses them) is picked up without a manual refresh.
    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            // Re-scan sources so a newer Runner_*/Worker_* log replaces a stale selection's file.
            reloadSources()
            await refresh()

            let interval = max(2.0, settings.pollIntervalSeconds)
            let nanos = UInt64((interval * 1_000_000_000).rounded())
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                // Sleep throws on cancellation — exit the loop cleanly.
                break
            }
        }
    }
}
