# Marsad

![Marsad Logo](priv/static/images/logo.png)

A Phoenix LiveView server fleet management dashboard with a mini-OS desktop interface. Manage your VPS fleet through an elegant browser-based desktop with SSH terminal, file explorer, Docker container management, systemd service control, nginx configuration, and live metrics -- all wrapped in a polished, themeable UI.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Getting Started](#getting-started)
- [Configuration](#configuration)
- [Development](#development)
- [Production Deployment](#production-deployment)
- [Security Notes](#security-notes)
- [License](#license)

## Overview

Marsad (Arabic for "observatory" or "watchtower") is a self-hosted web application that provides a unified desktop-style interface for managing a fleet of Linux servers over SSH. Rather than juggling multiple terminal sessions, SFTP clients, and monitoring tools, Marsad consolidates these workflows into a single, real-time, browser-based desktop environment.

The application is built with Phoenix LiveView and Elixir, leveraging OTP for concurrent, fault-tolerant SSH session management. Each managed server gets its own supervised GenServer that maintains a persistent SSH connection, enabling instant command execution and file operations without per-request connection overhead.

## Features

### Mini-OS Desktop Interface
- Draggable, resizable windows with a taskbar and app launcher
- Real-time updates via LiveView's WebSocket connection
- Themeable UI with light/dark modes and six accent colors
- Code editors with syntax highlighting for remote files

### Server Fleet Management
- Add, edit, and remove SSH server connections
- Support for password and private key authentication
- Automatic host key fingerprint recording (TOFU)
- Server reachability testing with online/offline status tracking

### Integrated Terminal
- xterm.js-powered SSH terminal emulator
- One exec channel per submitted line
- Command transcript history per terminal window

### SFTP File Explorer
- Remote directory browsing with breadcrumb navigation
- File upload (up to 50 MB per file, 3 concurrent)
- File preview with syntax highlighting
- Inline code editing with save-to-remote
- Create directories, delete files and folders

### Live Metrics and Monitoring
- CPU load (1m, 5m, 15m), memory usage, disk utilization
- Network I/O (RX/TX) tracking
- Per-core CPU detection (handles cgroup-limited environments)
- Process table with sort, filter, and kill capabilities
- Historical charting with configurable time ranges (1h, 6h, 24h, 7d, custom)
- Auto-refresh with configurable interval (minimum 5 seconds)

### Docker Container Management
- List all containers with status, image, and port information
- Start, stop, and restart containers
- View container logs (last 200 lines)
- Live resource stats (CPU, memory, network, block I/O)
- Full container inspection via `docker inspect`

### Systemd Service Control
- List all service units with load, active, sub, and description states
- Filter by text search or state (all, active, failed, inactive)
- Sort by name or state
- Start, stop, and restart services
- View unit journal logs (last 200 lines)
- Preview and edit unit files with automatic daemon-reload on save

### Nginx Web Server Management
- Service status with config test result
- Reload and restart nginx
- Full configuration dump viewer
- Config file browser under `/etc/nginx` with path confinement
- Edit config files with save capability
- Error log viewer (last 100 lines)

## Architecture

### Core Contexts

**Fleet** -- Server CRUD, SSH session lifecycle, and remote execution. Uses a Registry and DynamicSupervisor to manage one `ServerSession` process per active server. Sessions are started lazily and terminated when a server is updated or deleted.

**Services** -- Pure functional wrappers around Docker, systemd, and nginx commands. All remote names interpolated into shell commands are strictly validated against an allow-list regex to prevent command injection.

**SSH** -- A behaviour defining the remote transport interface. The default implementation (`SshAdapter`) uses OTP `:ssh` and `:ssh_sftp`. A future agent-based transport can implement this same behaviour without changing callers.

**Metrics** -- Database-backed storage of server health snapshots with pruning of data older than 48 hours. Chart data is computed from snapshot history.

**Settings** -- Key/value store for application settings (theme mode, accent color, metrics polling interval). Unknown or missing values fall back to curated defaults.

### Connection Model

```
Web Browser  <--WebSocket-->  LiveView Process
                                  |
                                  | (via Registry lookup)
                                  v
                           ServerSession (GenServer)
                                  |
                                  | (persistent SSH connection)
                                  v
                           Remote Linux Server
```

Each server gets a supervised GenServer that holds a long-lived SSH connection. On first use (command execution, file listing, etc.), the session establishes the connection, decrypts the stored credential, authenticates, and records the host key fingerprint. Subsequent operations reuse the connection. If the connection drops, the session transparently reconnects on the next request.

### Credential Security

SSH secrets (passwords and private keys) are encrypted at rest using AES-256-GCM via OTP's `:crypto` module. The encryption key is read from the `:marsad, :vault_key` application environment variable (base64, 32 bytes). In dev and test environments, a non-secret fallback key is used so the application boots with zero setup.

In production, you **must** set the `MARSAD_VAULT_KEY` environment variable. Losing this key means losing access to stored credentials.

## Getting Started

### Prerequisites

- Elixir ~> 1.17
- Erlang/OTP (compatible with your Elixir version)
- Node.js (for asset compilation)
- SQLite (via ecto_sqlite3 dependency)

### Installation

1. Clone the repository:

```bash
git clone <repository-url>
cd marsad
```

2. Install dependencies and set up the database:

```bash
mix setup
```

This runs `deps.get`, `ecto.setup` (create, migrate, seed), `assets.setup` (install Tailwind and esbuild), and `assets.build`.

3. Start the Phoenix server:

```bash
mix phx.server
```

4. Open your browser at `http://localhost:4000`.

The root URL opens the desktop environment directly.

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MARSAD_VAULT_KEY` | Production only | Dev fallback | Base64-encoded 32-byte key for AES-256-GCM credential encryption |
| `SECRET_KEY_BASE` | Production only | Dev fallback | Phoenix secret key for signing/encrypting cookies |
| `DATABASE_PATH` | Production only | `marsad_dev.db` (dev) | Path to the SQLite database file |
| `PORT` | No | `4000` | HTTP port to listen on |
| `PHX_HOST` | Production recommended | `example.com` | Public hostname (used for URL generation) |
| `POOL_SIZE` | No | `5` | Ecto connection pool size |
| `PHX_SERVER` | Production recommended | `false` | Set to `true` to enable the HTTP server in releases |

### Application Settings

Runtime-configurable settings are stored in the database and accessible via the Settings app on the desktop:

- **Theme mode**: `light` or `dark` (default: `dark`)
- **Accent color**: `ocean`, `royal`, `emerald`, `violet`, `amber`, `rose` (default: `ocean`)
- **Metrics interval**: Polling interval in milliseconds, minimum 5000 (default: 15000)

## Development

### Useful Mix Tasks

```bash
# Run tests
mix test

# Run only previously failed tests
mix test --failed

# Run tests in a specific file
mix test test/marsad/fleet_test.exs

# Format code
mix format

# Full pre-commit checks (compile, deps unlock unused, format, test)
mix precommit
```

### Dev Tools

In development, the following are available at `/dev`:

- **LiveDashboard** (`/dev/dashboard`) -- Phoenix request and telemetry metrics
- **Mailbox Preview** (`/dev/mailbox`) -- Preview emails sent by the application

Both are mounted only when `dev_routes` is enabled (default in dev/test).

### Project Structure

```
lib/
  marsad/                        -- Application contexts (business logic)
    application.ex               -- OTP application and supervisor tree
    repo.ex                      -- Ecto repository
    fleet/                       -- Server fleet management
      server.ex                  -- Server schema and changesets
      server_session.ex          -- GenServer holding SSH connections
      credential_vault.ex        -- AES-256-GCM at-rest encryption
      services.ex                -- Docker, systemd, nginx operations
      sys_info.ex                -- Health metrics collection and parsing
    ssh/                         -- SSH transport layer
      ssh_adapter.ex             -- OTP :ssh / :ssh_sftp implementation
    metrics/                     -- Historical metrics
      snapshot.ex                -- Metrics snapshot schema
    settings/                    -- Application settings
  marsad_web/                    -- Web interface
    live/desktop_live.ex         -- Main LiveView (mini-OS desktop)
    desktop/                     -- Panel components
      docker_panel.ex            -- Docker container panel
      systemd_panel.ex           -- Systemd service panel
      nginx_panel.ex             -- Nginx management panel
    router.ex                    -- Routes
    endpoint.ex                  -- Phoenix endpoint
    telemetry.ex                 -- Telemetry metrics
priv/
  repo/
    migrations/                  -- Ecto database migrations
  static/                        -- Compiled assets
```

## Production Deployment

### Release

Build and run a production release:

```bash
# Set required environment variables
export DATABASE_PATH=/etc/marsad/marsad.db
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export MARSAD_VAULT_KEY=$(openssl rand -base64 32)
export PHX_HOST=your-domain.com
export PHX_SERVER=true

# Build the release
MIX_ENV=prod mix release

# Run it
bin/marsad start
```

### Docker

The application manages Docker containers on remote servers; the application itself can also be containerized. Ensure that `DATABASE_PATH` points to a persistent volume and that `MARSAD_VAULT_KEY` is preserved across restarts.

### Important Notes

- **SSL**: In production, the endpoint is configured to force SSL. Behind a reverse proxy, set `rewrite_on: [:x_forwarded_proto]`.
- **Database**: SQLite is used for simplicity. For higher concurrency or multi-node deployments, consider switching to PostgreSQL by updating the repository configuration.
- **SSH Key Forwarding**: The application uses direct SSH connections from the server where Marsad runs. Ensure that host can reach your managed servers on the configured SSH ports.

## Security Notes

- Credentials are encrypted at rest but decrypted in memory for SSH authentication.
- Host keys are accepted on first use (TOFU) and recorded for display. Future versions may enforce host key verification.
- All names interpolated into remote shell commands are validated against a strict allow-list regex (`~r/\A[\w@:.+=,~-]+\z/`).
- Nginx file access is confined under `/etc/nginx` with path traversal protection.
- PID values are validated (1 to 4,194,303) before being passed to `kill`.
- Private key material written to temporary files is created with exclusive access mode and removed after use.

## License

This project is licensed under the Creative Commons Attribution-NonCommercial 4.0 International License (CC BY-NC 4.0).

You are free to:

- **Share** -- copy and redistribute the material in any medium or format
- **Adapt** -- remix, transform, and build upon the material

Under the following terms:

- **Attribution** -- You must give appropriate credit, provide a link to the license, and indicate if changes were made.
- **NonCommercial** -- You may not use the material for commercial purposes.

See the [LICENSE](./LICENSE) file for the full license text.
