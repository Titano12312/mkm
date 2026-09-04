# TellAviv — Android release build (PowerShell)
# Usage:
#   .\tools\build_android.ps1
#   .\tools\build_android.ps1 -ApiUrl https://api.tellaviv.example.com -BuildAppBundle
param(
  [string]$ApiUrl = $env:TELLAVIV_API_URL,
  [switch]$BuildAppBundle
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
  # LAN IP for friends testing over Wi-Fi; override via -ApiUrl in production.
  $ApiUrl = 'https://api.tellaviv.example.com'
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
