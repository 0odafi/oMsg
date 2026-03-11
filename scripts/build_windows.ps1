param(
  [string]$ProjectDir = "C:\Users\odafi\Desktop\oMsg\omsg_app",
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"

function Resolve-AppVersion {
  param(
    [string]$ProjectDir,
    [string]$RequestedVersion
  )

  $resolved = $RequestedVersion.Trim()
  if ([string]::IsNullOrWhiteSpace($resolved)) {
    $pubspecPath = Join-Path $ProjectDir "pubspec.yaml"
    if (-not (Test-Path $pubspecPath)) {
      throw "pubspec.yaml not found: $pubspecPath"
    }
    $versionLine = Select-String -Path $pubspecPath -Pattern '^version:\s*(.+)\s*$' | Select-Object -First 1
    if (-not $versionLine) {
      throw "version: line not found in $pubspecPath"
    }
    $resolved = $versionLine.Matches[0].Groups[1].Value.Trim()
  }

  if ($resolved.StartsWith("v")) {
    $resolved = $resolved.Substring(1)
  }
  if ($resolved -notmatch '^\d+\.\d+\.\d+\+\d+$') {
    throw "Invalid version format: $resolved. Expected x.y.z+build"
  }
  return $resolved
}

$Version = Resolve-AppVersion -ProjectDir $ProjectDir -RequestedVersion $Version
$buildParts = $Version.Split("+", 2)
$buildName = $buildParts[0]
$buildNumber = $buildParts[1]

Set-Location $ProjectDir
flutter pub get
flutter build windows --release --build-name=$buildName --build-number=$buildNumber

$root = Split-Path $ProjectDir -Parent
$target = Join-Path $root "dist\windows\$Version"
New-Item -ItemType Directory -Force -Path $target | Out-Null

Copy-Item -Path (Join-Path $ProjectDir "build\windows\x64\runner\Release\*") -Destination $target -Recurse -Force

$safeVersion = $Version.Replace("+", "_")
$archive = Join-Path $root "dist\windows\omsg_windows_$safeVersion.zip"
Compress-Archive -Path (Join-Path $target "*") -DestinationPath $archive -Force

Write-Host "Windows build is ready:"
Write-Host $target
Write-Host $archive
