# TellAviv — Android release build (PowerShell)
# Usage:
#   .\tools\build_android.ps1
#   .\tools\build_android.ps1 -ApiUrl http://192.168.1.8:3000 -BuildAppBundle
param(
  [string]$ApiUrl = $env:TELLAVIV_API_URL,
  [switch]$BuildAppBundle
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
  # Production backend (Render). Override via -ApiUrl for LAN testing.
  $ApiUrl = 'https://tellaviv-backend.onrender.com'
  Write-Host "No -ApiUrl given, using $ApiUrl" -ForegroundColor Yellow
}

Push-Location (Join-Path $PSScriptRoot '..\frontend')
try {
  flutter pub get
  if ($BuildAppBundle) {
    flutter build appbundle --release --dart-define=API_URL=$ApiUrl
    Write-Host 'AAB: build\app\outputs\bundle\release\app-release.aab' -ForegroundColor Green
  } else {
    flutter build apk --release --dart-define=API_URL=$ApiUrl
    Write-Host 'APK: build\app\outputs\flutter-apk\app-release.apk' -ForegroundColor Green
  }
} finally {
  Pop-Location
}
