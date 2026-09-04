# TellAviv — Windows release build (PowerShell)
# Usage:
#   .\tools\build_windows.ps1
#   .\tools\build_windows.ps1 -ApiUrl http://192.168.1.8:3000
# Output: frontend\build\windows\x64\runner\Release\  (input for Inno Setup)
param(
  [string]$ApiUrl = $env:TELLAVIV_API_URL
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
  # Production backend (Render). Override via -ApiUrl for LAN testing.
  $ApiUrl = 'https://tellaviv-backend.onrender.com'
  Write-Host "No -ApiUrl given, using $ApiUrl" -ForegroundColor Yellow
}

# Inno Setup needs Developer Mode OR code signing for MSIX; plain flutter
# Windows build has no special requirements beyond VS Build Tools.
Push-Location (Join-Path $PSScriptRoot '..\frontend')
try {
  flutter config --enable-windows-desktop
  flutter pub get
  flutter build windows --release --dart-define=API_URL=$ApiUrl
  Write-Host 'Windows release: build\windows\x64\runner\Release\' -ForegroundColor Green
  Write-Host 'Next: iscc installer\tellaviv.iss' -ForegroundColor Cyan
} finally {
  Pop-Location
}
