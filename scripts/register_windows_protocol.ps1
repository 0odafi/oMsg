param(
  [string]$Scheme = "omsg",
  [string]$ExePath = "",
  [switch]$Remove
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ExePath)) {
  $ExePath = Join-Path $PSScriptRoot "..\\omsg_app\\build\\windows\\x64\\runner\\Release\\omsg_app.exe"
}

$resolvedExe = [System.IO.Path]::GetFullPath($ExePath)
$registryPath = "HKCU:\\Software\\Classes\\$Scheme"

if ($Remove) {
  if (Test-Path $registryPath) {
    Remove-Item -Path $registryPath -Recurse -Force
    Write-Output "Removed Windows protocol registration for $Scheme"
  } else {
    Write-Output "Protocol $Scheme is not registered"
  }
  exit 0
}

if (!(Test-Path $resolvedExe)) {
  throw "Executable not found: $resolvedExe"
}

New-Item -Path $registryPath -Force | Out-Null
Set-ItemProperty -Path $registryPath -Name "(default)" -Value "URL:$Scheme Protocol"
New-ItemProperty -Path $registryPath -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null

$iconPath = Join-Path $registryPath "DefaultIcon"
New-Item -Path $iconPath -Force | Out-Null
Set-ItemProperty -Path $iconPath -Name "(default)" -Value "`"$resolvedExe`",0"

$commandPath = Join-Path $registryPath "shell\\open\\command"
New-Item -Path $commandPath -Force | Out-Null
Set-ItemProperty -Path $commandPath -Name "(default)" -Value "`"$resolvedExe`" `"%1`""

Write-Output "Registered ${Scheme}:// protocol for $resolvedExe"
