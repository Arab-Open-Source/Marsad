# Build a production release ZIP for Windows.
# Usage: powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1
$ErrorActionPreference = "Stop"

Set-Location (Join-Path $PSScriptRoot "..")

$version = (& mix run -e 'IO.puts(Mix.Project.config()[:version])' --no-start).Trim()
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  "AMD64" { "x86_64" }
  "ARM64" { "arm64" }
  default { $env:PROCESSOR_ARCHITECTURE.ToLower() }
}
$artifact = "marsad-$version-windows-$arch"

Write-Host "==> Building $artifact"

# runtime.exs validates these at build time. Replace them with real secrets
# when starting the release — see RELEASE.md.
$env:DATABASE_PATH = if ($env:DATABASE_PATH) { $env:DATABASE_PATH } else { "C:\temp\marsad-release-build.db" }
$env:SECRET_KEY_BASE = if ($env:SECRET_KEY_BASE) { $env:SECRET_KEY_BASE } else { "build-time-placeholder-secret-key-base-not-for-production-use-000000000000" }
$env:MARSAD_VAULT_KEY = if ($env:MARSAD_VAULT_KEY) { $env:MARSAD_VAULT_KEY } else { "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" }

Write-Host "==> Fetching dependencies"
mix deps.get
if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed" }

Write-Host "==> Installing asset tooling"
mix assets.setup
if ($LASTEXITCODE -ne 0) { throw "mix assets.setup failed" }

Write-Host "==> Building assets"
mix assets.deploy
if ($LASTEXITCODE -ne 0) { throw "mix assets.deploy failed" }

Write-Host "==> Compiling release (MIX_ENV=prod)"
$env:MIX_ENV = "prod"
mix release
if ($LASTEXITCODE -ne 0) { throw "mix release failed" }

Write-Host "==> Packaging"
New-Item -ItemType Directory -Force -Path artifacts | Out-Null
Compress-Archive -Path "_build\prod\rel\marsad\*" -DestinationPath "artifacts\$artifact.zip" -Force
$hash = (Get-FileHash "artifacts\$artifact.zip" -Algorithm SHA256).Hash.ToLower()
Set-Content -Path "artifacts\$artifact.zip.sha256" -Value "$hash  $artifact.zip" -Encoding ascii

Write-Host "==> Done: artifacts\$artifact.zip"
