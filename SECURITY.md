# Security Policy

## Supported versions

Security fixes are considered for the latest published release on GitHub (`v0.3.x` and newer).

## Reporting a vulnerability

Please report security issues privately:

1. Prefer [GitHub Security Advisories](https://github.com/marko999/cursor-gauge/security/advisories/new) for this repository, **or**
2. Open a GitHub issue **without** secrets, tokens, cookies, session dumps, spending figures, or personal paths — describe impact and reproduction at a high level, then request a private channel.

Do **not** attach Cursor session databases, Keychain exports, JWTs, cookie values, `.env` files, or screenshots that show account/spend details.

## Token-handling / security model (summary)

CursorGauge is an unofficial local helper. It:

- Reads the existing Cursor access token from the local Cursor state DB (read-only `sqlite3`) or Keychain fallback.
- Holds tokens **only in memory** for the duration of a request.
- Builds a dashboard session cookie in memory and sends it only as an HTTPS `Cookie` header to Cursor hosts.
- Does **not** write tokens to disk, logs, preferences, the app bundle, or release artifacts.
- Surfaces **sanitized** error strings in the UI (no response bodies, Authorization headers, or cookie values).

Threat model assumptions:

- The Mac user already trusts the signed-in Cursor desktop app.
- Anyone who can read the local Cursor state DB / Keychain can already obtain the same session material.
- Network traffic goes only to Cursor endpoints (`api2.cursor.sh`, `cursor.com`); this project does not operate a backend.

## What we will not accept in public issues

- Pasted access tokens, JWTs, or `WorkosCursorSessionToken` values
- Copies of `state.vscdb` or other credential stores
- Personal spending / invoice figures as “proof”
- Requests to bypass Gatekeeper, disable SIP, or otherwise weaken macOS security for distribution

Thank you for helping keep users safe.
