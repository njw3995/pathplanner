# Release Process

## One-time repo setup

Commit these files:

```text
.github/workflows/windows-installer-release.yml
installer/build_installer.ps1
installer/pathplanner_autostudio.iss
INSTALL_WINDOWS.md
RELEASE_STEPS.md
```

Append `.gitignore.additions` into your existing `.gitignore`.

Do **not** commit:

```text
build/
installer/Output/
*.exe
```

## Normal release flow

From your local repo:

```powershell
git status
git add .github/workflows/windows-installer-release.yml installer/build_installer.ps1 installer/pathplanner_autostudio.iss INSTALL_WINDOWS.md RELEASE_STEPS.md .gitignore
git commit -m "Add Windows installer release workflow"
git push
```

Then create a release tag:

```powershell
git tag v2026.0.0
git push origin v2026.0.0
```

GitHub Actions will build the Windows app, build the installer, and attach the installer to a GitHub Release.

## Updating later

Make your code changes, then tag a new version:

```powershell
git add .
git commit -m "Update AutoStudio"
git push

git tag v2026.0.1
git push origin v2026.0.1
```

Users download the new installer from GitHub Releases and run it. Because the installer AppId stays the same, it updates the existing install.

## Manual build from GitHub

You can also run the workflow manually:

1. Go to GitHub.
2. Open **Actions**.
3. Choose **Build Windows Installer**.
4. Click **Run workflow**.
5. Enter a version.
6. Choose whether to create a GitHub Release.

If `create_release` is false, the installer is available as a workflow artifact instead of a Release asset.
