#!/usr/bin/env python3
# Force uploaded collaboration autos to render only through host PathPlanner GUI.
#
# This fixes the "still looks point-to-point" problem by removing the browser
# uploaded auto samples from the field render path entirely.
#
# New behavior:
# - Browser uploads .auto + .path files.
# - Host saves them into the active project as team-prefixed files.
# - Host immediately builds a real GhostAutoOverlay from the saved .auto file
#   using the existing PathPlanner overlay pipeline.
# - The browser field renders the host-published snapshot autos only.
# - Raw browser team auto samples are ignored for drawing on both host and
#   browser. They are just upload metadata.
#
# Run from PathPlanner repo root:
#
#   python repair_pathplanner_collab_force_host_rendered_uploaded_autos.py
#   dart format lib/widgets/editor/split_auto_editor.dart lib/collab/collab_server.dart
#   flutter analyze lib
#   flutter run
#
# After running:
#   Stop/start the collaboration session and hard refresh browser pages.

from __future__ import annotations

import argparse
from pathlib import Path


HOST_OVERLAY_HELPERS = "  void _setCollabTeamAutoVisible(String teamKey, bool visible) {\n    setState(() {\n      if (visible) {\n        _hiddenCollabTeamAutoKeys.remove(teamKey);\n      } else {\n        _hiddenCollabTeamAutoKeys.add(teamKey);\n      }\n\n      final overlayName = _collabTeamGhostOverlayNames[teamKey];\n      if (overlayName != null) {\n        for (final overlay in _ghostOverlays) {\n          if (overlay.name == overlayName) {\n            overlay.visible = visible;\n            break;\n          }\n        }\n      }\n\n      _publishCollabSnapshot();\n    });\n\n    _refreshPreviewDuration();\n\n    try {\n      _ghostOverlayDialogSetState?.call(() {});\n    } catch (_) {\n      _ghostOverlayDialogSetState = null;\n    }\n  }\n\n  GhostAutoOverlay? _ensureCollabSavedAutoGhostOverlay({\n    required String teamKey,\n    required String savedAutoName,\n    required Object? color,\n  }) {\n    final existingOverlayName = _collabTeamGhostOverlayNames[teamKey];\n\n    if (existingOverlayName != null) {\n      final existingIndex =\n          _ghostOverlays.indexWhere((overlay) => overlay.name == existingOverlayName);\n\n      if (existingIndex >= 0 &&\n          existingOverlayName == savedAutoName &&\n          _ghostOverlays[existingIndex].visible ==\n              !_hiddenCollabTeamAutoKeys.contains(teamKey)) {\n        return _ghostOverlays[existingIndex];\n      }\n\n      if (existingIndex >= 0) {\n        _ghostOverlays.removeAt(existingIndex);\n      }\n      _collabTeamGhostOverlayNames.remove(teamKey);\n    }\n\n    final autoFile = File(p.join(_collabAutosDir(), '$savedAutoName.auto'));\n    final overlay = _buildExternalAutoOverlay(\n      autoFile,\n      displayNameOverride: savedAutoName,\n      colorOverride: _collabColorFromHex(color),\n    );\n\n    if (overlay == null) {\n      return null;\n    }\n\n    overlay.visible = !_hiddenCollabTeamAutoKeys.contains(teamKey);\n\n    _ghostOverlays.add(overlay);\n    _collabTeamGhostOverlayNames[teamKey] = overlay.name;\n    _openTimingSectionId = overlay.name;\n    _refreshPreviewDuration();\n    _publishCollabSnapshot();\n\n    return overlay;\n  }\n\n"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def backup_once(path: Path, suffix: str) -> None:
    backup = path.with_suffix(path.suffix + suffix)
    if not backup.exists():
        backup.write_text(read(path), encoding="utf-8", newline="\n")
        print(f"backup: {backup}")


def find_matching(text: str, open_index: int, open_ch: str, close_ch: str) -> int:
    depth = 0
    quote = None
    escaped = False
    line_comment = False
    block_comment = False
    i = open_index

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue

        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
                continue
            i += 1
            continue

        if quote is not None:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
            i += 1
            continue

        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue

        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue

        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue

        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i

        i += 1

    raise RuntimeError(f"Could not find matching {close_ch}")


def function_range(text: str, signature: str) -> tuple[int, int] | None:
    start = text.find(signature)
    if start < 0:
        return None

    open_idx = text.find("(", start)
    if open_idx < 0:
        return None

    close_idx = find_matching(text, open_idx, "(", ")")
    body_open = text.find("{", close_idx)
    if body_open < 0:
        return None

    body_close = find_matching(text, body_open, "{", "}")
    return start, body_close + 1


def insert_before_function(text: str, signature: str, insert: str) -> str:
    if insert.strip() in text:
        return text

    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"Could not find function insertion point: {signature}")

    return text[:start] + insert + text[start:]


def patch_split_auto_editor(repo: Path) -> None:
    path = repo / "lib" / "widgets" / "editor" / "split_auto_editor.dart"
    if not path.exists():
        raise SystemExit(f"Could not find {path}")

    old = read(path)
    text = old
    backup_once(path, ".force_host_rendered_uploaded_autos.bak")

    text = text.replace(
        "                        collabTeamAutos: _visibleCollabTeamAutos(),",
        "                        collabTeamAutos: const [],",
    )

    field_anchor = "final Map<String, int> _savedCollabAutoSignatures = {};"
    if "final Map<String, String> _collabTeamGhostOverlayNames = {};" not in text:
        if field_anchor not in text:
            raise SystemExit("Could not find _savedCollabAutoSignatures field.")
        text = text.replace(
            field_anchor,
            field_anchor
            + "\n  final Map<String, String> _collabTeamGhostOverlayNames = {};",
            1,
        )

    if "GhostAutoOverlay? _ensureCollabSavedAutoGhostOverlay({" not in text:
        text = insert_before_function(
            text,
            "  List<Map<String, dynamic>> _visibleCollabTeamAutos()",
            HOST_OVERLAY_HELPERS,
        )

    text = text.replace(
        "  GhostAutoOverlay? _buildExternalAutoOverlay(File autoFile) {",
        "  GhostAutoOverlay? _buildExternalAutoOverlay(\n"
        "    File autoFile, {\n"
        "    String? displayNameOverride,\n"
        "    Color? colorOverride,\n"
        "  }) {",
    )
    text = text.replace(
        "      final displayName = _uniqueExternalOverlayName(autoName);",
        "      final displayName = displayNameOverride ?? _uniqueExternalOverlayName(autoName);",
        1,
    )
    text = text.replace(
        "        color: _ghostColors[_ghostOverlays.length % _ghostColors.length],\n        pauseAnchors: _buildPauseAnchorsForPaths(paths),",
        "        color: colorOverride ?? _ghostColors[_ghostOverlays.length % _ghostColors.length],\n        pauseAnchors: _buildPauseAnchorsForPaths(paths),",
        1,
    )

    old_browser_block = """      team['auto'] = _renderSavedCollabAutoWithPathPlannerGui(
        teamKey: teamKey,
        visibleAutoName: autoName,
        savedAutoName: savedAutoName,
        existingPayload: auto,
      );
      _savedCollabAutoSignatures[teamKey] = signature;"""

    new_browser_block = """      final overlay = _ensureCollabSavedAutoGhostOverlay(
        teamKey: teamKey,
        savedAutoName: savedAutoName,
        color: team['color'],
      );

      if (overlay == null) {
        auto['hostGuiRenderError'] =
            'Saved auto was written, but PathPlanner could not generate a host overlay.';
      } else {
        auto['hostGhostOverlayName'] = overlay.name;
        auto['hostRenderedByGhostOverlay'] = true;
        auto.remove('samples');
        auto.remove('segments');
      }

      team['auto'] = auto;
      _savedCollabAutoSignatures[teamKey] = signature;"""

    if old_browser_block in text:
        text = text.replace(old_browser_block, new_browser_block, 1)
    elif "hostRenderedByGhostOverlay" not in text:
        raise SystemExit(
            "Could not patch _saveBrowserUploadedTeamAuto. Paste that method if this fails."
        )

    old_local_block = """      final finalAutoPayload = _renderSavedCollabAutoWithPathPlannerGui(
        teamKey: teamKey.trim(),
        visibleAutoName: importedName,
        savedAutoName: savedAutoName,
        existingPayload: autoPayload,
      );

      setState(() {"""

    new_local_block = """      final overlay = _ensureCollabSavedAutoGhostOverlay(
        teamKey: teamKey.trim(),
        savedAutoName: savedAutoName,
        color: null,
      );

      if (overlay == null) {
        autoPayload['hostGuiRenderError'] =
            'Saved auto was written, but PathPlanner could not generate a host overlay.';
      } else {
        autoPayload['hostGhostOverlayName'] = overlay.name;
        autoPayload['hostRenderedByGhostOverlay'] = true;
        autoPayload.remove('samples');
        autoPayload.remove('segments');
      }

      setState(() {"""

    if old_local_block in text:
        text = text.replace(old_local_block, new_local_block, 1)
        text = text.replace("        team['auto'] = finalAutoPayload;", "        team['auto'] = autoPayload;", 1)

    old_on_changed = """      onChanged: (value) {
        setState(() {
          if (value == true) {
            _hiddenCollabTeamAutoKeys.remove(key);
          } else {
            _hiddenCollabTeamAutoKeys.add(key);
          }
        });
        try {
          _ghostOverlayDialogSetState?.call(() {});
        } catch (_) {
          _ghostOverlayDialogSetState = null;
        }
      },"""

    new_on_changed = """      onChanged: (value) {
        _setCollabTeamAutoVisible(key, value == true);
      },"""

    if old_on_changed in text:
        text = text.replace(old_on_changed, new_on_changed, 1)

    text = text.replace(
        "      if (autoMap['hostGuiRendered'] == true) 'PathPlanner GUI rendered',",
        "      if (autoMap['hostRenderedByGhostOverlay'] == true) 'host PathPlanner overlay',\n"
        "      if (autoMap['hostGuiRendered'] == true) 'PathPlanner GUI rendered',",
    )

    if text != old:
        write(path, text)
        print(f"patched: {path}")
    else:
        print(f"unchanged: {path}")


def patch_collab_server(repo: Path) -> None:
    path = repo / "lib" / "collab" / "collab_server.dart"
    if not path.exists():
        raise SystemExit(f"Could not find {path}")

    old = read(path)
    text = old
    backup_once(path, ".force_host_rendered_uploaded_autos.bak")

    old_total_loop = """      for (const state of teamStates.values()) {
        if (state?.auto?.totalSeconds) {
          total = Math.max(total, Number(state.auto.totalSeconds || 0));
        }
      }
"""
    text = text.replace(old_total_loop, "")

    old_team_loop = """      for (const team of TEAM_LIST) {
        const state = teamStates.get(team.key);
        if (state?.auto) {
          autos.push({
            ...state.auto,
            active: true,
            role: `Team ${team.teamNumber}`,
            color: state.color || teamPrimaryColor(team.key),
          });
        }
      }

"""
    text = text.replace(old_team_loop, "")

    if text != old:
        write(path, text)
        print(f"patched: {path}")
    else:
        print(f"unchanged: {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".", help="PathPlanner repo root")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    if not (repo / "pubspec.yaml").exists() or not (repo / "lib").is_dir():
        raise SystemExit(f"{repo} does not look like a PathPlanner repo root")

    patch_split_auto_editor(repo)
    patch_collab_server(repo)

    print()
    print("Done. Now run:")
    print("  dart format lib/widgets/editor/split_auto_editor.dart lib/collab/collab_server.dart")
    print("  flutter analyze lib")
    print("  flutter run")
    print()
    print("Important test steps:")
    print("  1. Stop and restart the collaboration session.")
    print("  2. Hard refresh all browser clients.")
    print("  3. Upload an auto and all referenced path files.")
    print("  4. Browser Team Autos should say 'host PathPlanner overlay'.")
    print("  5. The field should draw the host-published ghost overlay, not raw point-to-point browser samples.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
