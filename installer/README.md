# Installer Folder

`pathplanner_autostudio.iss` is the Inno Setup installer definition.

`build_installer.ps1` builds the installer locally or inside GitHub Actions.

Local build from repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\installer\build_installer.ps1 -Version 2026.0.0
```

For local builds, install Inno Setup 6 first.

For GitHub Actions builds, the workflow installs Inno Setup automatically.
