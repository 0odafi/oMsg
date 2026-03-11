param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [string]$RepoDir = "C:\Users\odafi\Desktop",

  [string]$Remote = "origin",

  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-ReleaseVersion {
  param([string]$InputVersion)

  $resolved = $InputVersion.Trim()
  if ($resolved.StartsWith("v")) {
    $resolved = $resolved.Substring(1)
  }
  if ($resolved -notmatch '^\d+\.\d+\.\d+\+\d+$') {
    throw "Invalid version format: $InputVersion. Expected x.y.z+build or v.x.y.z+build"
  }
  return $resolved
}

$resolvedVersion = Resolve-ReleaseVersion -InputVersion $Version
$tagName = "v$resolvedVersion"

Set-Location $RepoDir

$gitTopLevel = (git rev-parse --show-toplevel).Trim()
if (-not $gitTopLevel) {
  throw "Unable to resolve git repository root."
}
Set-Location $gitTopLevel

$trackedChanges = git status --porcelain --untracked-files=no
if (-not [string]::IsNullOrWhiteSpace(($trackedChanges | Out-String))) {
  throw "Repository has tracked changes. Commit or stash them before creating a release tag."
}

$localTag = git tag --list $tagName
if (-not [string]::IsNullOrWhiteSpace(($localTag | Out-String))) {
  throw "Tag already exists locally: $tagName"
}

$remoteTag = git ls-remote --tags $Remote "refs/tags/$tagName"
if (-not [string]::IsNullOrWhiteSpace(($remoteTag | Out-String))) {
  throw "Tag already exists on ${Remote}: $tagName"
}

Write-Host "Repository:" $gitTopLevel
Write-Host "Version:" $resolvedVersion
Write-Host "Tag:" $tagName
Write-Host "Remote:" $Remote

if ($DryRun) {
  Write-Host ""
  Write-Host "Dry run only. Commands that would run:"
  Write-Host "git tag -a $tagName -m `"Release $tagName`""
  Write-Host "git push $Remote refs/tags/$tagName"
  exit 0
}

git tag -a $tagName -m "Release $tagName"
git push $Remote "refs/tags/$tagName"

Write-Host ""
Write-Host "Release tag pushed:" $tagName
Write-Host "GitHub Actions will pick it up automatically."
