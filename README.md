# CursorGauge

**Cursor usage and spend, at a glance.**

Native macOS menu-bar app that shows your signed-in Cursor plan remaining allowance next to the clock (works while Cursor Agent/Home UI is open). Standalone AppKit app with no runtime dependencies beyond macOS.

**Platform:** macOS 13+ (Apple Silicon / arm64 for this release)  
**Version:** 0.3.0  
**Not affiliated with Cursor / Anysphere.** Cursor does not publish a stable third-party usage API; endpoints and response shapes can change without notice.

## Screenshot

> _Product screenshot placeholder — add a menu-bar / popover capture here after release._

## Features

- Discovers the existing Cursor session on this Mac (no pasted token)
- Compact menu-bar title: **`$86`** / **`21%`**, or **`$300 OD`** / **`100% OD`** when the included plan is exhausted
- Global hotkey **⌥⌘C** toggles the panel even when the status item is crowded out of the menu bar
- Click the status item for a native vibrancy popover (AppKit `NSVisualEffectView` + standard controls):
  - **Header** — remaining allowance + last-updated
  - **Included / on-demand** — used, limit, remaining with native progress bars
  - **Auto / API / plan used %** and billing reset as compact rows
  - **Models** — expandable per-model attribution for the **current billing cycle** from dashboard usage events (unofficial semantics; not an invoice)
  - **Settings** — display preference (`$` / `%`), hotkey note, optional **Launch at Login**
- Footer actions: **Refresh**, **Open Cursor Usage Dashboard**, **Quit**
- Summary auto-refresh every **5 minutes**
- Model event breakdown fetched when the popover opens or on manual Refresh, cached ~**15 minutes**
- Refresh after wake / app activation when summary is older than **2 minutes**
- Non-overlapping summary and model requests
- Agent-only UI (`LSUIElement` — no Dock icon)

## Install from Releases

1. Download `CursorGauge-v0.3.0-macOS-arm64.zip` from [GitHub Releases](https://github.com/marko999/cursor-gauge/releases).
2. Unzip — you should get `CursorGauge.app`.
3. **First open (Gatekeeper):** right-click the app → **Open** → confirm. Ad-hoc signed builds are **not notarized**, so double-click alone may be blocked.
4. Optional: move `CursorGauge.app` to `/Applications` (recommended if you enable Launch at Login).

This release is **arm64-only** (Apple Silicon). It is **ad-hoc signed**, not Developer ID signed and **not notarized**.

To quit: popover → **Quit CursorGauge**, or:

```bash
pkill -x CursorGauge
```

### Launch at Login

Optional toggle in **Settings** uses macOS 13+ `SMAppService.mainApp`. It is **off by default** and never forced on.

Registration is most reliable when the app bundle is installed under `/Applications`. Running from a local `dist/` build may fail with a clear error in Settings; install into Applications (or approve Login Items in System Settings) if you want it at login.

## Security model

| Topic | Behavior |
| --- | --- |
| Session discovery | Reads `cursorAuth/accessToken` from Cursor’s local SQLite DB via `/usr/bin/sqlite3` in **read-only** mode. Falls back to Keychain service `cursor-access-token` / account `cursor-user`. |
| Token storage | Never written to disk, logs, plist, or the app bundle. Held in memory only for each request. |
| Dashboard cookie | Built in memory as `WorkosCursorSessionToken=<URL-encoded sub::token>` from JWT `sub` + access token. Attached only as a request `Cookie` header. Never logged, persisted, or bundled. |
| Network (summary) | HTTPS only to **`https://api2.cursor.sh`** Connect RPC paths. |
| Network (details) | HTTPS only to **`https://cursor.com`** exact paths `/api/usage-summary` and `/api/dashboard/get-filtered-usage-events`. Ephemeral `URLSession` (no cookie jar / URL cache). POSTs set `Origin: https://cursor.com`. |
| Preferences | Non-sensitive display mode in `UserDefaults`. Launch at Login is registered with the system Login Items service (no tokens). |
| Errors / UI | Sanitized messages only — no response bodies, tokens, Authorization headers, or cookies. |
| Large DB | Does not load `state.vscdb` into the process; uses system `sqlite3`. |

See [SECURITY.md](SECURITY.md) for reporting guidance.

### Local paths (macOS)

- State DB: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- Key: `ItemTable.key = cursorAuth/accessToken`

## Privacy

- No telemetry, analytics, or crash reporting from this app.
- No third-party network calls beyond Cursor’s documented unofficial endpoints above.
- Usage numbers appear only in the local menu bar / popover; nothing is uploaded to this project’s authors or GitHub.

## Build & test

Requires Apple Command Line Tools (or Xcode) with Swift 5.9+ on Apple Silicon.

```bash
cd cursor-gauge
make test
make app
make smoke-check
```

Artifact:

```text
dist/CursorGauge.app
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow.

## Project layout

| Path | Role |
| --- | --- |
| `Sources/CursorGaugeCore/` | Auth discovery, API client, parse/format, events aggregation, preferences |
| `Sources/CursorGauge/` | AppKit status item + vibrancy popover |
| `Tests/CursorGaugeCoreTests/` | Pure parsing/formatting/aggregation tests (CLT-friendly assert runner; no XCTest) |
| `Resources/Info.plist` | Bundle metadata (`LSUIElement`) |
| `scripts/build-app.sh` | Release build + `.app` + ad-hoc codesign |
| `Makefile` | `test` / `app` / `smoke-check` / `release-zip` |

## Fragility / known limits

- Relies on **undocumented** Cursor local storage keys and API routes (Connect RPC + dashboard web APIs).
- Requires Cursor signed in on this Mac.
- Dashboard cookie shape (`WorkosCursorSessionToken`) and event field semantics can change without notice.
- Event volume in a busy billing cycle may hit the max-page guard (partial model totals).
- If Cursor encrypts or relocates tokens, discovery fails safely in the menu bar.
- Expired JWTs: this app does not refresh or write tokens; sign out/in in Cursor if the API returns 401/403.
- Built with **Command Line Tools + SwiftPM** (no full Xcode required). Ad-hoc signed only — not Developer ID / notarized.
- First launch via Finder may show Gatekeeper prompts; prefer right-click → **Open**.
- **Launch at Login** via `SMAppService` is unreliable until the app is in `/Applications` (or approved under Login Items).
- v0.3.0 release ZIP is **arm64-only**.

## License

MIT — see `LICENSE`.
