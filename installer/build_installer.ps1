param(
    [string]$Version = "2026.0.0",
    [string]$AppName = "PathPlanner AutoStudio",
    [string]$Publisher = "Nick Wight",
    [switch]$SkipFlutterBuild
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$InstallerDir = $PSScriptRoot
$IssFile = Join-Path $InstallerDir "pathplanner_autostudio.iss"
$OutputDir = Join-Path $InstallerDir "Output"

Write-Host ""
Write-Host "== PathPlanner AutoStudio Installer Build =="
Write-Host "Repo:      $RepoRoot"
Write-Host "Version:   $Version"
Write-Host ""

Push-Location $RepoRoot
try {
    if (-not $SkipFlutterBuild) {
        Write-Host "== Flutter build =="
        flutter clean
        flutter pub get
        flutter build windows --release
    }

    $ReleaseDir = Join-Path $RepoRoot "build\windows\x64\runner\Release"
    if (-not (Test-Path $ReleaseDir)) {
        throw "Release directory not found: $ReleaseDir"
    }

    $PreferredExe = Get-ChildItem $ReleaseDir -Filter "*.exe" |
        Where-Object { $_.Name -match "pathplanner" } |
        Select-Object -First 1

    if ($null -eq $PreferredExe) {
        $PreferredExe = Get-ChildItem $ReleaseDir -Filter "*.exe" | Select-Object -First 1
    }

    if ($null -eq $PreferredExe) {
        throw "No .exe found in $ReleaseDir"
    }

    $ExeName = $PreferredExe.Name
    Write-Host "Detected app exe: $ExeName"

    $Iscc = Get-Command "iscc.exe" -ErrorAction SilentlyContinue
    if ($null -ne $Iscc) {
        $IsccPath = $Iscc.Source
    } else {
        $Candidates = @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
        )

        $IsccPath = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $IsccPath) {
        throw @"
Could not find ISCC.exe.

Install Inno Setup 6, then rerun this script.
Default install path is usually:
  C:\Program Files (x86)\Inno Setup 6\ISCC.exe
"@
    }

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }

    Write-Host ""
    Write-Host "== Inno Setup =="
    Write-Host "ISCC:      $IsccPath"
    Write-Host "Output:    $OutputDir"
    Write-Host ""

    & $IsccPath `
        "/DMyAppName=$AppName" `
        "/DMyAppVersion=$Version" `
        "/DMyAppPublisher=$Publisher" `
        "/DMyAppExeName=$ExeName" `
        "/DBuildDir=$ReleaseDir" `
        "/DOutputDir=$OutputDir" `
        $IssFile

    $Installer = Join-Path $OutputDir "PathPlanner-AutoStudio-Setup-$Version.exe"
    if (Test-Path $Installer) {
        Write-Host ""
        Write-Host "Done:"
        Write-Host "  $Installer"
    } else {
        Write-Host ""
        Write-Host "Build finished, but expected installer was not found:"
        Write-Host "  $Installer"
        Write-Host "Check the Inno Setup output above."
    }
}
finally {
    Pop-Location
}
