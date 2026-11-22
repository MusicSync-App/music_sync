<#
.SYNOPSIS
  Build and publish a MusicSync Android release (GitHub Release with app-release.apk + version.json).

.DESCRIPTION
  1. Bumps the "+N" build number in musicsync_app/pubspec.yaml (optionally sets a new version name).
  2. flutter build apk --release
  3. Computes sha256 + size, writes build/release/version.json (update-server contract format).
  4. gh release create v<name>+<code> app-release.apk version.json --repo <Repo>
  The update server picks the new release up within ~5 minutes (manifest cache).

  -DryRun does everything except changing pubspec.yaml, building and calling gh: it prints the
  planned actions and writes a preview version.json.

.EXAMPLE
  .\release.ps1 -Notes "Remedieri si teme noi"
  .\release.ps1 -Notes "Versiune noua" -VersionName 1.2.0 -MinSupported 3
  .\release.ps1 -Notes "test" -DryRun

  Compatible with Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Notes,
    [string]$VersionName,
    [int]$MinSupported = 0,
    # "<owner>/<repo>" of the app repository. Default: parsed from `git remote get-url origin`.
    [string]$Repo,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$AppDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Pubspec = Join-Path $AppDir 'pubspec.yaml'
$ApkPath = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
$OutDir = Join-Path $AppDir 'build\release'
$VersionJsonPath = Join-Path $OutDir 'version.json'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Plan([string]$msg) { Write-Host "[dry-run] $msg" -ForegroundColor Yellow }

function Get-RepoFromOrigin {
    $url = (& git -C $AppDir remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $url) { throw "Could not read 'git remote get-url origin'. Pass -Repo <owner>/<repo>." }
    $url = "$url".Trim()
    # https://github.com/owner/repo(.git)  |  git@github.com:owner/repo(.git)  |  ssh://git@github.com/owner/repo
    $m = [regex]::Match($url, 'github\.com[:/]+([^/]+)/([^/]+?)(\.git)?/?$')
    if (-not $m.Success) { throw "Origin '$url' is not a GitHub URL. Pass -Repo <owner>/<repo>." }
    return "$($m.Groups[1].Value)/$($m.Groups[2].Value)"
}

if (-not $Repo) { $Repo = Get-RepoFromOrigin }
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid -Repo '$Repo' (expected owner/repo)." }
if ($VersionName -and $VersionName -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -VersionName '$VersionName' (expected X.Y.Z)." }
if (-not $Notes.Trim()) { throw '-Notes must not be empty.' }

# ---------------------------------------------------------------- version bump
$pubspecText = [System.IO.File]::ReadAllText($Pubspec, [System.Text.Encoding]::UTF8)
$rx = [regex]'(?m)^version:[ \t]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)[ \t]*(\r?)$'
$m = $rx.Match($pubspecText)
if (-not $m.Success) { throw "Could not find 'version: X.Y.Z+N' in $Pubspec" }
$oldName = $m.Groups[1].Value
$oldCode = [int]$m.Groups[2].Value
$newCode = $oldCode + 1
$newName = if ($VersionName) { $VersionName } else { $oldName }
$tag = "v$newName+$newCode"
$newPubspec = $rx.Replace($pubspecText, "version: $newName+$newCode`$3", 1)

Write-Step "Repo: $Repo"
Write-Step "Version: $oldName+$oldCode -> $newName+$newCode (tag $tag)"

# ---------------------------------------------------------------- minSupported
if ($MinSupported -le 0) {
    $MinSupported = 1
    if (-not $DryRun) {
        # Keep the previous release's minSupported unless told otherwise.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("musicsync-prev-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            & gh release download --repo $Repo --pattern version.json --dir $tmp 2>$null | Out-Null
            $prev = Join-Path $tmp 'version.json'
            if ($LASTEXITCODE -eq 0 -and (Test-Path $prev)) {
                $prevJson = [System.IO.File]::ReadAllText($prev, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($prevJson.minSupported) { $MinSupported = [int]$prevJson.minSupported }
            }
        } catch { } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    } else {
        Write-Plan "would read minSupported from the latest release's version.json (using 1 for the preview)"
    }
}
if ($MinSupported -gt $newCode) { throw "-MinSupported ($MinSupported) cannot exceed the new versionCode ($newCode)." }
Write-Step "minSupported: $MinSupported"

# ---------------------------------------------------------------- build
if ($DryRun) {
    Write-Plan "would update $Pubspec : 'version: $oldName+$oldCode' -> 'version: $newName+$newCode'"
    Write-Plan "would run (in $AppDir): flutter build apk --release"
} else {
    foreach ($tool in 'flutter', 'gh') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found in PATH." }
    }
    & gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gh is not authenticated. Run 'gh auth login'." }

    [System.IO.File]::WriteAllText($Pubspec, $newPubspec, $Utf8NoBom)
    Write-Step 'flutter build apk --release'
    Push-Location $AppDir
    try {
        & flutter build apk --release
        $buildOk = ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
    if (-not $buildOk -or -not (Test-Path $ApkPath)) {
        [System.IO.File]::WriteAllText($Pubspec, $pubspecText, $Utf8NoBom)
        throw 'flutter build failed; pubspec.yaml restored.'
    }
}

# ---------------------------------------------------------------- version.json
if (Test-Path $ApkPath) {
    $sha256 = (Get-FileHash -Algorithm SHA256 -Path $ApkPath).Hash.ToLowerInvariant()
    $size = [long](Get-Item $ApkPath).Length
    if ($DryRun) { Write-Plan "hash/size below are from the EXISTING APK at $ApkPath (not rebuilt)" }
} else {
    $sha256 = ('0' * 64)
    $size = [long]0
    Write-Plan "no APK at $ApkPath; using placeholder sha256/size"
}

$apkUrl = "https://github.com/$Repo/releases/download/$tag/app-release.apk"
$version = [ordered]@{
    versionCode  = $newCode
    versionName  = $newName
    apkUrl       = $apkUrl
    sha256       = $sha256
    size         = $size
    notes        = $Notes
    minSupported = $MinSupported
    publishedAt  = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}
$json = $version | ConvertTo-Json -Depth 3
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
[System.IO.File]::WriteAllText($VersionJsonPath, $json, $Utf8NoBom)
Write-Step "Wrote $VersionJsonPath"
Write-Host $json

# ---------------------------------------------------------------- GitHub release
$notesFile = Join-Path $OutDir 'release-notes.txt'
[System.IO.File]::WriteAllText($notesFile, $Notes, $Utf8NoBom)
$ghArgs = @('release', 'create', $tag, $ApkPath, $VersionJsonPath,
            '--repo', $Repo, '--title', "MusicSync $newName ($newCode)", '--notes-file', $notesFile)

if ($DryRun) {
    Write-Plan ("would run: gh " + (($ghArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '))
    Write-Plan 'no files changed except the preview version.json / release-notes.txt under build\release'
} else {
    Write-Step "gh release create $tag"
    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed. pubspec.yaml is already bumped to $newName+$newCode; fix the problem and re-run 'gh $($ghArgs -join ' ')'."
    }
    Write-Step "Released $tag -> $apkUrl"
    Write-Host "Remember to commit the version bump: git commit -am `"Release $newName+$newCode`"" -ForegroundColor Green
}
