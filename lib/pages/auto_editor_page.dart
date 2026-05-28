import 'package:flutter/material.dart';
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/services/pplib_telemetry.dart';
import 'package:pathplanner/pages/project/auto_studio_page.dart';
import 'package:pathplanner/widgets/conditional_widget.dart';
import 'package:pathplanner/widgets/custom_appbar.dart';
import 'package:pathplanner/widgets/editor/split_auto_editor.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/keyboard_shortcuts.dart';
import 'package:pathplanner/widgets/renamable_title.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class AutoEditorPage extends StatefulWidget {
  final SharedPreferences prefs;
  final PathPlannerAuto auto;
  final List<PathPlannerPath> allPaths;
  final List<ChoreoPath> allChoreoPaths;
  final List<String> allPathNames;
  final String pathDir;
  final FieldImage fieldImage;
  final ValueChanged<String> onRenamed;
  final VoidCallback? onAutoSaved;
  final VoidCallback? onPathsChanged;
  final ChangeStack undoStack;
  final bool shortcuts;
  final PPLibTelemetry? telemetry;
  final bool hotReload;

  const AutoEditorPage({
    super.key,
    required this.prefs,
    required this.auto,
    required this.allPaths,
    required this.allChoreoPaths,
    required this.allPathNames,
    required this.pathDir,
    required this.fieldImage,
    required this.onRenamed,
    required this.undoStack,
    this.onAutoSaved,
    this.onPathsChanged,
    this.shortcuts = true,
    this.telemetry,
    this.hotReload = false,
  });

  @override
  State<AutoEditorPage> createState() => _AutoEditorPageState();
}

class _AutoEditorPageState extends State<AutoEditorPage> {
  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    List<String> autoPathNames = widget.auto.getAllPathNames();
    List<PathPlannerPath> autoPaths = widget.auto.choreoAuto
        ? []
        : autoPathNames
            .map((name) =>
                widget.allPaths.firstWhere((path) => path.name == name))
            .toList();
    List<ChoreoPath> autoChoreoPaths = widget.auto.choreoAuto
        ? autoPathNames
            .map((name) =>
                widget.allChoreoPaths.firstWhere((path) => path.name == name))
            .toList()
        : [];

    final editorWidget = SplitAutoEditor(
      prefs: widget.prefs,
      auto: widget.auto,
      autoPaths: autoPaths,
      autoChoreoPaths: autoChoreoPaths,
      allPathNames: widget.allPathNames,
      fieldImage: widget.fieldImage,
      undoStack: widget.undoStack,
      onAutoChanged: () {
        setState(() {
          widget.auto.saveFile();
        });
        widget.onAutoSaved?.call();

        if (widget.hotReload) {
          widget.telemetry?.hotReloadAuto(widget.auto);
        }
      },
      onEditPathPressed: (pathName) {
        widget.undoStack.clearHistory();
        Navigator.of(context).pop(pathName);
      },
      onImportAutoToStudio: () async {
        widget.undoStack.clearHistory();
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => AutoStudioPage(
              prefs: widget.prefs,
              auto: widget.auto,
              allPaths: widget.allPaths,
              allChoreoPaths: widget.allChoreoPaths,
              allPathNames: widget.allPathNames,
              pathDir: widget.pathDir,
              fieldImage: widget.fieldImage,
              onRenamed: widget.onRenamed,
              onAutoSaved: widget.onAutoSaved,
              onPathsChanged: widget.onPathsChanged,
              undoStack: widget.undoStack,
              shortcuts: widget.shortcuts,
              telemetry: widget.telemetry,
              hotReload: widget.hotReload,
            ),
          ),
        );
        if (mounted) {
          setState(() {});
        }
      },
    );

    return Scaffold(
      appBar: CustomAppBar(
        titleWidget: RenamableTitle(
          title: widget.auto.name,
          textStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurface,
          ),
          onRename: (value) {
            widget.onRenamed.call(value);
            setState(() {});
          },
        ),
        leading: BackButton(
          onPressed: () {
            widget.undoStack.clearHistory();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: ConditionalWidget(
        condition: widget.shortcuts,
        trueChild: KeyBoardShortcuts(
          keysToPress: shortCut(BasicShortCuts.undo),
          onKeysPressed: widget.undoStack.undo,
          child: KeyBoardShortcuts(
            keysToPress: shortCut(BasicShortCuts.redo),
            onKeysPressed: widget.undoStack.redo,
            child: editorWidget,
          ),
        ),
        falseChild: editorWidget,
      ),
    );
  }
}
