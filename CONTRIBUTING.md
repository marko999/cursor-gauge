# Contributing

Thanks for helping with CursorGauge.

## Prerequisites

- macOS 13+
- Apple Silicon recommended (current release packaging is arm64-only)
- Swift 5.9+ via Xcode or Command Line Tools

## Build & test

```bash
make test          # CursorGaugeCoreTests assert runner
make app           # dist/CursorGauge.app (ad-hoc signed)
make smoke-check   # bundle / codesign / credential-path scan
```

Optional local release zip (not committed):

```bash
make release-zip   # dist/CursorGauge-v0.3.4-macOS-arm64.zip + .sha256
```

## Workflow

1. Fork and branch from `main`.
2. Keep changes focused; preserve the local-session security model (no token persistence or logging).
3. Run `make test` and `make app` before opening a PR.
4. Do not commit `.build/`, `dist/`, zip/checksum artifacts, DBs, env files, or credentials.

## Code layout

- `Sources/CursorGaugeCore` — auth, API, parsing, preferences (testable)
- `Sources/CursorGauge` — AppKit menu-bar UI
- `Tests/CursorGaugeCoreTests` — CLT-friendly assert runner (no XCTest)

## Security expectations

Never include real tokens, cookies, `state.vscdb`, or personal spend data in commits, issues, or CI logs. See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree your contributions are licensed under the MIT License in `LICENSE`.
