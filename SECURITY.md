# Security Policy

## Supported versions

| Version        | Supported          |
| -------------- | ------------------ |
| latest release | :white_check_mark: |
| older releases | :x:                |

Only the latest GitHub release is supported
(currently `v0.1.0-canary` line). If you run an older build, upgrade first
and re-test — the issue may already be fixed.

## Reporting a vulnerability

**Do not open a public issue or pull request for security bugs.**

Email the maintainer directly using the contact on the GitHub profile
([@AbdElMajidOuhamane](https://github.com/AbdElMajidOuhamane)) with:

- the vulnerability and its impact
- a minimal reproduction (smallest `.js` file that triggers it)
- affected versions (`ff --version` output)

What happens next:

1. Acknowledgment within **48 hours**.
2. Triage and a fix developed privately.
3. Coordinated patch release, then a public advisory after the fix ships.
   Credit is given to the reporter unless anonymity is requested.

## Scope

In scope: the `ff` runtime and release binaries (engine, APIs, networking,
TLS, SQLite/Postgres clients, package installer).

Out of scope: third-party vendored libraries are patched by upgrading the
vendor pin — report upstream CVEs against those with the pinned version
listed by `./scripts/fetch-vendors.sh`.

This policy complements [CONTRIBUTING.md](CONTRIBUTING.md#security-issues).
