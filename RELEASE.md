# Marsad 0.10.0

**Release date:** 2026-11-17
**Status:** Stable

A self-hosted Phoenix LiveView dashboard for managing a fleet of Linux servers over SSH — with a mini-OS desktop, real PTY terminals, SFTP file explorer, live metrics, Docker/systemd/nginx control, and now a faster, more complete workflow.

---

## What's new in 0.10.0

| Area | Highlight |
|---|---|
| **Fleet Overview** | The landing page (`/`) now shows per-server status, CPU/disk/RAM and the latest audit events. The classic desktop moved to `/desktop`. |
| **Command Palette** | Press `Ctrl+K` to search apps, servers, pages and runbooks. Selecting a server opens its terminal instantly. |
| **Activity Timeline** | `/activity` — a searchable, filterable fleet-wide audit log (by server, action and result). |
| **Runbooks** | `/snippets` — save commands with `{{variables}}` and execute the rendered command on one or many servers in parallel. |
| **Terminal reliability** | Fixed page reloads caused by malformed PTY bytes, TUI freezes caused by SSH flow-control exhaustion, and input lag from per-keystroke round-trips. |
| **Build & delivery** | Reproducible CI, signed release artifacts for Linux/macOS/Windows, Docker image, and one-command build scripts. |

---

## Supported platforms

| Platform | Artifact | Install |
|---|---|---|
| Linux (x86_64 / arm64) | `marsad-0.10.0-linux-<arch>.tar.gz` | tar |
| macOS (x86_64 / arm64) | `marsad-0.10.0-darwin-<arch>.tar.gz` | tar |
| Windows (x86_64 / arm64) | `marsad-0.10.0-windows-<arch>.zip` | Expand-Archive |
| Docker (any platform) | `marsad:0.10.0` | docker compose |

Each artifact ships a `.sha256` file. Verify before running:

```bash
# Linux / macOS
sha256sum -c marsad-0.10.0-linux-x86_64.tar.gz.sha256
```

```powershell
# Windows
$expected = (Get-Content marsad-0.10.0-windows-x86_64.zip.sha256).Split()[0]
$actual = (Get-FileHash marsad-0.10.0-windows-x86_64.zip -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) { throw "Checksum mismatch" }
```

---

## Quick start (release tarball)

### Linux / macOS

```bash
tar -xzf marsad-0.10.0-linux-x86_64.tar.gz
cd marsad

export SECRET_KEY_BASE="$(mix phx.gen.secret 2>/dev/null || openssl rand -hex 64)"
export MARSAD_VAULT_KEY="$(openssl rand -base64 32)"
export DATABASE_PATH="$PWD/marsad.db"
export PHX_HOST="your-domain.com"
export PHX_SERVER=true

bin/marsad start
```

Open `http://localhost:4000`. On first run you'll be sent to `/setup` to create the local admin account.

### Windows (PowerShell)

```powershell
Expand-Archive marsad-0.10.0-windows-x86_64.zip -DestinationPath marsad
cd marsad

$env:SECRET_KEY_BASE = [Convert]::ToHexString((1..64 | ForEach-Object { Get-Random -Max 256 }))
$env:MARSAD_VAULT_KEY = [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Max 256 }))
$env:DATABASE_PATH = "$PWD\marsad.db"
$env:PHX_HOST = "your-domain.com"
$env:PHX_SERVER = "true"

.\bin\marsad.bat start
```

> **Keep `MARSAD_VAULT_KEY` safe.** SSH passwords and private keys are encrypted at rest with it. Losing the key means losing access to stored credentials.

---

## Docker (all platforms)

Create a `.env` next to `docker-compose.yml`:

```dotenv
SECRET_KEY_BASE=<generate with: mix phx.gen.secret>
MARSAD_VAULT_KEY=<generate with: openssl rand -base64 32>
PHX_HOST=localhost
PORT=4000
```

Then:

```bash
docker compose up -d --build
docker compose logs -f marsad
```

The SQLite database is stored in the named volume `marsad_data` at `/data/marsad.db`, so it survives container restarts. Migrations run automatically at boot.

---

## Required environment variables

| Variable | Required | Description |
|---|---|---|
| `SECRET_KEY_BASE` | Yes | Signing/encrypting cookies. Generate with `mix phx.gen.secret`. |
| `MARSAD_VAULT_KEY` | Yes | Base64 of exactly 32 bytes. AES-256-GCM key for SSH credential encryption. |
| `DATABASE_PATH` | Yes | Path to the SQLite database file. |
| `PHX_HOST` | Recommended | Public hostname used for URL generation. |
| `PHX_SERVER` | Yes (releases) | Set to `true` to start the HTTP server. |
| `PORT` | No | HTTP port, default `4000`. |
| `POOL_SIZE` | No | Ecto pool size, default `5`. |

Missing `SECRET_KEY_BASE`, `MARSAD_VAULT_KEY` or `DATABASE_PATH` intentionally prevents startup.

---

## Build from source

Prerequisites: Elixir `~> 1.17`, Erlang/OTP 27, Node.js 20.

```bash
# Linux / macOS
./scripts/build_release.sh
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1
```

The finished tarball/zip is written to `artifacts/`. For day-to-day development use `make setup`, `make dev`, `make test` and `make check`.

---

## Upgrading from 0.9.x

1. Back up `marsad.db` (and the current `MARSAD_VAULT_KEY`).
2. Stop the old process.
3. Deploy the new release and keep the same `DATABASE_PATH` and `MARSAD_VAULT_KEY`.
4. Start it — `Ecto.Migrator` applies the new `snippets` migration automatically at boot in releases.
5. Log in; `/` now opens the Fleet Overview. The old desktop is at `/desktop`.

No data migration is required for existing servers, metrics or audit logs.

---

## Verification

Every commit runs CI (format check, compile with warnings as errors, full test suite, asset build). Release artifacts are built by GitHub Actions on fresh Linux, macOS and Windows runners and published with SHA-256 checksums on the [Releases page](https://github.com/Arab-Open-Source/Marsad/releases).
