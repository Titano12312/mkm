# TellAviv — one-shot toolchain setup + full build (APK + Windows + installer).
# Esegui UNA volta da PowerShell amministratore:
#   .\tools\setup_and_build.ps1 -ApiUrl https://api.tellaviv.example.com
#
# Installa (se mancanti): Java 17, Flutter stable, Android cmdline-tools,
# VS 2022 Build Tools (workload C++, ~6 GB, serve solo per la build Windows),
# poi compila APK + Windows + setup .exe. Richiede ~12 GB liberi e pazienza.
param(
  [string]$ApiUrl = $env:TELLAVIV_API_URL,
  [string]$FlutterDir = 'C:\src\flutter',
  [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
  [switch]$SkipWindowsBuild
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ApiUrl)) { $ApiUrl = 'https://api.tellaviv.example.com' }
$RepoRoot = Split-Path $PSScriptRoot -Parent
$Iscc = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"

function Require-Admin {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Riavvia PowerShell come amministratore (serve per winget/VS Build Tools).'
  }
}

Require-Admin

# 1. Java 17 (Flutter/Gradle non funzionano con Java 8) -----------------------
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
  winget install -e --id EclipseAdoptium.Temurin.17.JDK --accept-source-agreements --accept-package-agreements
}
$javaHome = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
if ($javaHome) { $env:JAVA_HOME = $javaHome }

# 2. Flutter SDK --------------------------------------------------------------
if (-not (Test-Path "$FlutterDir\bin\flutter.bat")) {
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git $FlutterDir
}
$env:Path = "$FlutterDir\bin;$env:Path"
flutter precache
flutter config --enable-windows-desktop
flutter doctor

# 3. Android SDK (solo tool necessari alla APK release) ------------------------
$cmdTools = Join-Path $AndroidSdk 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path $cmdTools)) {
  $zip = "$env:TEMP\cmdtools.zip"
  Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile $zip
  Expand-Archive $zip -DestinationPath "$env:TEMP\cmdtools" -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $AndroidSdk 'cmdline-tools\latest') | Out-Null
  Copy-Item "$env:TEMP\cmdtools\cmdline-tools\*" (Join-Path $AndroidSdk 'cmdline-tools\latest') -Recurse -Force
}
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:ANDROID_HOME = $AndroidSdk
yes | & $cmdTools --licenses | Out-Null
& $cmdTools 'platform-tools' 'platforms;android-34' 'build-tools;34.0.0'
flutter doctor --android-licenses
flutter config --android-sdk $AndroidSdk

# 4. VS Build Tools (solo per `flutter build windows`) -------------------------
if (-not $SkipWindowsBuild) {
  if (-not (Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe')) {
    winget install -e --id Microsoft.VisualStudio.2022.BuildTools `
      --override '--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' `
      --accept-source-agreements --accept-package-agreements
  }
}

# 5. Build ---------------------------------------------------------------------
Push-Location (Join-Path $RepoRoot 'frontend')
try {
  if (-not (Test-Path '.\android')) { flutter create --platforms=android,windows . }
  flutter pub get
  flutter build apk --release --dart-define=API_URL=$ApiUrl
  if (-not $SkipWindowsBuild) {
    flutter build windows --release --dart-define=API_URL=$ApiUrl
  }
} finally {
  Pop-Location
}

# 6. Installer ------------------------------------------------------------------
if (-not $SkipWindowsBuild) {
  if (-not (Test-Path $Iscc)) { throw "ISCC non trovato in $Iscc" }
  & $Iscc (Join-Path $RepoRoot 'installer\tellaviv.iss')
  Write-Host 'Installer: installer\Output\TellAviv-Setup-0.1.0.exe' -ForegroundColor Green
}
Write-Host 'APK: frontend\build\app\outputs\flutter-apk\app-release.apk' -ForegroundColor Green
Write-Host 'Fatto.' -ForegroundColor Green
