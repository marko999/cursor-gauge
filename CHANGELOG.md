# Changelog

## v0.3.2

- Align menu bar + popover with Cursor spending pools: `C` / `O` used percents from `autoPercentUsed` / `apiPercentUsed`
- Switch collapsed status to on-demand only when OD `used > 0` (not when the dollar included meter alone is empty)
- Cursor / Other Models bars follow **used**; on-demand bar follows **remaining** (full when unused)

## v0.3.1

- Menu bar falls back to on-demand when included plan is exhausted (`$300 OD` / `100% OD`)
- Progress bars show remaining allowance (full = unused, empty = depleted)
- On-demand section moves to the top of the popover when included remaining is zero
- Hotkey **⌥⌘C** toggles the panel
- Shorter menu-bar status text

## v0.3.0

First public release of **CursorGauge**.

- Native macOS menu-bar usage/spend gauge with vibrancy popover
- `$` / `%` remaining display preference
- Included / on-demand progress, Auto / API / plan-used rows
- Per-model breakdown for the current billing cycle (unofficial dashboard events)
- Launch at Login via `SMAppService` (optional; off by default)
- Local Cursor session discovery only — tokens never persisted by this app
- Ad-hoc signed **arm64** app bundle (not notarized)

Install from GitHub Releases; right-click → **Open** on first launch (Gatekeeper).
