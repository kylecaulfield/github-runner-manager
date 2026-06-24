# RunnerManager

A native macOS menu bar app for managing the self-hosted [GitHub Actions](https://docs.github.com/actions/hosting-your-own-runners) runners installed on **this Mac**.

RunnerManager is a SwiftUI [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra) (agent / `LSUIElement`) app — it lives in the menu bar with no Dock icon. It discovers runner installs already on disk, shows each one's live status, and drives the standard GitHub runner tooling (`config.sh`, `svc.sh`, and the underlying `launchctl` LaunchAgent) to start, stop, create, update, and remove runners. It shells out to those scripts **locally** — there is no remote host, no agent, and no daemon. The menu bar icon reflects the aggregate health of every discovered runner (all running, some stopped, or errored).

It is pure Swift + SwiftUI + Foundation + Security + AppKit — **no third-party dependencies**.

---

## Requirements

- **macOS 13.0 (Ventura) or later** — the deployment target.
- **Xcode 16 or later** to build.
- An Apple Silicon Mac (the runner package this app installs is `osx-arm64`).

You do **not** need an Apple Developer account to build and run it locally (see below).

---

## Building & running

1. Open `RunnerManager.xcodeproj` in **Xcode 16+**.
2. Select the **RunnerManager** scheme.
3. **Build & Run** (⌘R).

The project is configured to **ad-hoc sign** the app (the *“Sign to Run Locally”* identity — `CODE_SIGN_IDENTITY = "-"`, manual signing, no development team). That means it builds and runs **with no Apple Developer account and no team selected**. Nothing else needs to be configured.

When it launches you'll see a new icon in the menu bar (there is no Dock icon or app window — it's an agent app). Click the icon to open the management popover; use ⌘, to open Settings.

### App Sandbox

**The App Sandbox is intentionally OFF.** RunnerManager must `exec` external tools — `config.sh`, `svc.sh`, `launchctl`, `tar`, and `Runner.Listener` — and read/scan arbitrary directories under your home folder. The sandbox forces exec'd child processes to inherit the app's container and forbids the broad filesystem and process access this app needs, so it cannot run sandboxed. There is no `.entitlements` file in the project; the sandbox is simply not enabled.

This is fine for a self-distributed (non-Mac-App-Store) utility. **If you want to distribute this app to others**, you should:

- Sign with a **Developer ID Application** certificate,
- Enable the **Hardened Runtime**, and
- **Notarize** the app with Apple.

The Hardened Runtime is compatible with this app's behavior — it does not require the App Sandbox. The Keychain item the app stores (a plain generic password — see below) needs **no entitlement** of its own.

---

## Permissions

RunnerManager needs very little:

- **Keychain.** The first time the app reads or writes your stored PAT, macOS may prompt for Keychain access. Choose **Allow** (or **Always Allow** to avoid being asked again). The PAT is stored as a standard generic-password Keychain item under the service `com.github.runnermanager.pat`.
- **Filesystem (`~/actions-runner`, etc.).** Discovery only reads directories you already own under your home folder, so no special TCC / privacy permission is required for the default search roots. (If you add a custom search path inside a TCC-protected location — e.g. Desktop, Documents, or Downloads — macOS may show its usual one-time access prompt for that folder.)

The app never runs anything as root and never asks for an administrator password — the runner service is a **per-user LaunchAgent**, not a system daemon.

---

## GitHub Personal Access Token (PAT)

Several features need to talk to the GitHub REST API: minting a registration token to create a runner, minting a remove token to de-register one, and listing runners to display their **labels**. For these, RunnerManager uses a PAT you provide in **Settings**.

### Exact scopes

**Fine-grained PAT** (recommended) — grant, on **each target repository**:

> **Repository permissions → Administration → Read and write**

- **Read** alone is enough to *list* runners and display their labels.
- **Write** is additionally required to *mint registration and remove tokens* (i.e. to create or de-register runners) and to delete a runner via the API.

For **organization** or **enterprise** runners, grant the equivalent **Administration: Read and write** at the organization/enterprise level.

**Classic PAT equivalent:** the **`repo`** scope.

> A `404` from a runner endpoint almost always means the PAT is missing the **Administration** permission for that repository/organization, rather than a genuinely missing resource — the app's error messages call this out.

### Where the PAT lives

The PAT is stored **only in the macOS Keychain**. It is **never** written to disk, to `UserDefaults`, or to logs. It is read transiently at the moment an API call needs it, sent only as an `Authorization: Bearer` header to `api.github.com`, and is never forwarded across the redirect to GitHub's download host. Registration and remove tokens (minted on demand, valid ~1 hour) are likewise used transiently and discarded. Any command surfaced in an error message is run through a redactor so a token never appears in the UI or logs.

You can set or clear the PAT at any time in **Settings**; the UI only ever shows *whether* a PAT is set, never its value.

> **No PAT?** You can still discover, start/stop/restart, view logs, and update existing runners, and you can *create* a runner using the **Paste-block** flow (which carries its own registration token). Labels won't be shown without a PAT (they're server-side only), and removal falls back to a local-only de-register.

---

## Discovery

RunnerManager finds runners by scanning the filesystem — no subprocess, no network — so it is fast and safe to run continuously.

### What counts as a runner install

A directory is treated as a runner install **only if it directly contains all three markers**:

- `config.sh`
- `svc.sh`
- `.runner` (written by GitHub once a runner has been *configured* — this is what distinguishes a real install from an unpacked-but-unconfigured tarball)

### Search roots

By default these roots are scanned (each tilde-expanded; only existing directories are used):

| Root | Purpose |
| --- | --- |
| `~/actions-runner` | the conventional single-runner install path |
| `~/actions-runners` | the conventional parent directory for multiple runners (and the default install root for new runners) |
| `~` | your home directory, scanned depth-limited as a catch-all |

You can add, remove, or pick (via a folder chooser) **custom search roots** in **Settings**.

### Depth

Scanning is **depth-limited**. For each root: if the root itself is a runner install it's used as-is; otherwise the scan descends up to **max discovery depth** levels, skipping the runner's own internal/noise directories (`_work`, `_diag`, `externals`, `bin`, `node_modules`) and all hidden (dot) directories. Symlinks are not followed.

The **discovery depth** is configurable in Settings (default **3**, clamped to **1–6**). A higher depth digs deeper below each root at the cost of a slower scan; depth `1` means “only the immediate children of each root.” The default roots plus a small depth comfortably cover the standard `~/actions-runner` / `~/actions-runners/<name>` layouts; raise it only if you keep runners nested more deeply.

---

## Features

- **Discover & list** — automatically finds every runner install under your search roots and lists them with a status dot, name, scope (`owner/repo`, `org`, or `enterprises/name`), installed version, and an **update** badge when a newer release is available. Statuses are **polled** on a configurable interval (default 5s, 2–60s).
- **Status & control** — per-runner **Start**, **Stop**, and **Restart**, driven through `svc.sh` (which wraps `launchctl load -w` / `unload` on the per-user LaunchAgent). The detail view shows the live status and PID.
- **Logs** — tail the runner's logs in-app (newest `_diag/Runner_*.log` / `Worker_*.log`, plus the LaunchAgent `stdout`/`stderr` under `~/Library/Logs/<label>/`), with auto-refresh and a **Reveal in Finder** action.
- **Create a runner** — two ways:
  - **Stored PAT:** fill in owner/repo (or an org), an optional name, labels, runner group, and install root. The app mints a registration token via the API, downloads and extracts the runner package, runs `config.sh --unattended --replace`, then installs and starts the service.
  - **Paste the block:** paste the snippet GitHub shows on *“Add new self-hosted runner.”* The app parses the `--url`, registration `--token`, and (if present) the version straight out of the block — **no PAT required**. Works with both the macOS/Linux (`config.sh`/`curl`) and Windows (`config.cmd`/`Invoke-WebRequest`) variants.
- **Update** — update a runner's binaries **in place while preserving its registration** (`.runner`, `.credentials*`, `.env`, `.service`, `_work/`, `_diag/` are all kept). The flow stops the service, extracts the new release over the install directory, then restarts — it does **not** de-register/re-register. **Update All** updates every runner that reports an available update, one at a time.
- **Remove** — de-register a runner from GitHub and tear down its service. The app stops and uninstalls the LaunchAgent, then (with a PAT) mints a fresh remove token and runs `config.sh remove`, with an API `DELETE` as a backstop; without a PAT it falls back to a **local-only** removal (`config.sh remove --local`), leaving the registration to be cleared from GitHub's UI. Optionally, it can also **delete the install directory** (a separate confirmation).

---

## Assumptions worth knowing

A few behaviors are inherent to how GitHub's runner tooling works and are surfaced here so there are no surprises:

- **Installed version** is read by executing `<install>/bin/Runner.Listener --version`, which prints the bare version and makes no network call. There is no plain-text `VERSION` file in the package, so this is the authoritative method.
- **Labels are server-side only.** They are *not* stored in `.runner`; the only way to know a runner's labels is the GitHub API. So labels are displayed only when a **PAT** is configured — without one, the detail view notes that labels require a PAT.
- **The runner runs as a per-user LaunchAgent** (`~/Library/LaunchAgents/<label>.plist`), not a system LaunchDaemon. It only runs **while you are logged in** with an active GUI session, and it stops when you log out. This is GitHub's own design for the macOS runner service.
- **Other users' runners are out of scope.** Discovery only reads directories you can access; another user's install directory is POSIX-unreadable and is skipped.

---

## Troubleshooting

- **“The registration / remove token was rejected (expired or invalid).”** Registration and remove tokens last only about **an hour**. If you paste a block or leave a Create/Remove dialog open too long, mint a fresh token (or re-open the *Add new self-hosted runner* page) and try again. RunnerManager mints its own tokens immediately before shelling out, so this usually only bites the paste-block path.
- **“Must not run with sudo.”** `svc.sh` refuses to run as root. RunnerManager never invokes `sudo`, so seeing this means the app (or the shell that launched it) is running elevated. Run it as your normal user. The app's error message includes the exact `cd <dir> && ./svc.sh <cmd>` line you can run in Terminal yourself.
- **`launchctl` load/unload fails (privilege / session errors).** A user-domain LaunchAgent needs an **active GUI login session**. If you're operating over SSH or with no logged-in session, `launchctl load`/`unload` can fail with domain/permission errors. Log in graphically and retry, or run the suggested `cd <dir> && ./svc.sh <start|stop>` command in Terminal from within your login session — RunnerManager surfaces that exact command in the error.
- **A runner doesn't appear.** Confirm its directory contains all three of `config.sh`, `svc.sh`, and `.runner`, that it's under one of your search roots, and that the **discovery depth** is high enough to reach it. Add a custom search root in Settings if it lives elsewhere.
- **No labels shown.** Labels require a configured **PAT** with at least **Administration: Read**. Set one in Settings.
