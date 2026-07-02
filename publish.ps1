# ═══════════════════════════════════════════════════════════════════════
#  Pantry — publish a new release
#
#  Usage:
#     .\publish.ps1                       (prompts for version + notes)
#     .\publish.ps1 -Version 0.1.1 -Notes "Added expiration reminders"
#
#  What it does:
#     1. Bumps the version in pubspec.yaml (and the build number)
#     2. Commits the change
#     3. Creates a v<version> tag with your release notes
#     4. Pushes — which triggers GitHub Actions to build the signed APK
#        and publish it as a Release your phone can pull (Settings → Check).
# ═══════════════════════════════════════════════════════════════════════
param(
    [string]$Version,
    [string]$Notes
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# --- read current version from pubspec.yaml ---
$pubspec = 'pubspec.yaml'
$lines = Get-Content $pubspec
$verLine = $lines | Where-Object { $_ -match '^version:\s' } | Select-Object -First 1
if (-not $verLine) { Write-Error "Could not find version: in pubspec.yaml"; exit 1 }
$current = ($verLine -replace '^version:\s*', '').Trim()
$currentName = $current.Split('+')[0]
$currentBuild = if ($current.Contains('+')) { [int]$current.Split('+')[1] } else { 0 }
Write-Host "Current version: $current" -ForegroundColor Cyan

# --- get target version ---
if (-not $Version) {
    $Version = Read-Host "New version number (e.g. 0.1.1) [current name: $currentName]"
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Write-Error "Version must look like 0.1.1"; exit 1
}
$newBuild = $currentBuild + 1
$newVersion = "$Version+$newBuild"

# --- get release notes ---
if (-not $Notes) {
    $Notes = Read-Host "What's new in this version?"
}
if (-not $Notes) { $Notes = "Maintenance update." }

Write-Host ""
Write-Host "About to release:" -ForegroundColor Yellow
Write-Host "  version : $newVersion  (tag v$Version)"
Write-Host "  notes   : $Notes"
$ok = Read-Host "Proceed? (y/n)"
if ($ok -ne 'y') { Write-Host "Cancelled."; exit 0 }

# --- bump pubspec ---
$lines = $lines | ForEach-Object { if ($_ -match '^version:\s') { "version: $newVersion" } else { $_ } }
Set-Content -Path $pubspec -Value $lines -Encoding utf8
Write-Host "Bumped pubspec.yaml -> $newVersion" -ForegroundColor Green

# --- commit, tag, push ---
git add -A
git commit -m "Release v$Version"
git tag -a "v$Version" -m "$Notes"
git push origin HEAD
git push origin "v$Version"

Write-Host ""
Write-Host "Pushed tag v$Version. GitHub Actions is now building the APK." -ForegroundColor Green
Write-Host "Watch progress:  https://github.com/scenicprints/pantry/actions" -ForegroundColor Cyan
Write-Host "When it finishes, open the app -> Settings -> Check for updates." -ForegroundColor Cyan
