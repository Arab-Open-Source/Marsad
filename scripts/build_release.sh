#!/usr/bin/env bash
# Build a production release tarball for Linux or macOS.
# Usage: ./scripts/build_release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(mix run -e 'IO.puts(Mix.Project.config()[:version])' --no-start)"
OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"          # linux / darwin
ARCH="$(uname -m)"                                          # x86_64 / arm64
case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="arm64" ;;
esac

ARTIFACT="marsad-${VERSION}-${OS_NAME}-${ARCH}"
echo "==> Building $ARTIFACT"

# runtime.exs validates these at build time. They must be replaced with real
# secrets when starting the release — see RELEASE.md.
export DATABASE_PATH="${DATABASE_PATH:-/tmp/marsad-release-build.db}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-build-time-placeholder-secret-key-base-not-for-production-use-000000000000}"
export MARSAD_VAULT_KEY="${MARSAD_VAULT_KEY:-MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=}"

echo "==> Fetching dependencies"
mix deps.get

echo "==> Installing npm packages"
npm ci --prefix assets

echo "==> Installing asset tooling"
mix assets.setup

echo "==> Building assets"
mix assets.deploy

echo "==> Compiling release (MIX_ENV=prod)"
MIX_ENV=prod mix release

echo "==> Packaging"
mkdir -p artifacts
tar -czf "artifacts/${ARTIFACT}.tar.gz" -C _build/prod/rel marsad

if command -v sha256sum >/dev/null 2>&1; then
  (cd artifacts && sha256sum "${ARTIFACT}.tar.gz" > "${ARTIFACT}.tar.gz.sha256")
elif command -v shasum >/dev/null 2>&1; then
  (cd artifacts && shasum -a 256 "${ARTIFACT}.tar.gz" > "${ARTIFACT}.tar.gz.sha256")
fi

echo "==> Done: artifacts/${ARTIFACT}.tar.gz"
