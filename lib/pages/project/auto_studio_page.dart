import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/auto_builder/auto_generator.dart';
import 'package:pathplanner/auto_builder/auto_spec.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/path_command.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/services/pplib_telemetry.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/widgets/conditional_widget.dart';
import 'package:pathplanner/widgets/custom_appbar.dart';
import 'package:pathplanner/widgets/editor/split_auto_editor.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/keyboard_shortcuts.dart';
import 'package:pathplanner/widgets/renamable_title.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

Future<void> safeRenameOrDeleteSourceIfTargetExists(
  dynamic sourceFile,
  String targetPath,
) async {
  if (sourceFile.path == targetPath) {
    return;
  }

  dynamic targetFile;
  try {
    targetFile = sourceFile.fileSystem.file(targetPath);
  } catch (_) {
    targetFile = null;
  }

  if (targetFile != null && await targetFile.exists()) {
    if (await sourceFile.exists()) {
      await sourceFile.delete();
    }
    return;
  }

  try {
    if (await sourceFile.exists()) {
      await sourceFile.rename(targetPath);
    }
  } catch (_) {
    if (targetFile != null && await targetFile.exists()) {
      if (await sourceFile.exists()) {
        await sourceFile.delete();
      }
      return;
    }
    rethrow;
  }
}

void safeRenameOrDeleteSourceIfTargetExistsSync(
  dynamic sourceFile,
  String targetPath,
) {
  if (sourceFile.path == targetPath) {
    return;
  }

  dynamic targetFile;
  try {
    targetFile = sourceFile.fileSystem.file(targetPath);
  } catch (_) {
    targetFile = null;
  }

  if (targetFile != null && targetFile.existsSync()) {
    if (sourceFile.existsSync()) {
      sourceFile.deleteSync();
    }
    return;
  }

  try {
    if (sourceFile.existsSync()) {
      sourceFile.renameSync(targetPath);
    }
  } catch (_) {
    if (targetFile != null && targetFile.existsSync()) {
      if (sourceFile.existsSync()) {
        sourceFile.deleteSync();
      }
      return;
    }
    rethrow;
  }
}

const String _riskyTooltip =
    'Risky goes further over the center line and takes more from your opponents.';
const String _greedyTooltip =
    'Greedy goes further over the middle of the field and takes more from your alliance partners.';
const String _hubSweepTooltip =
    'Hub Sweep intakes next to the hub for the close sweep.';
const String _localizeTooltip =
    'Localize Return slows the robot down before going over the bump so it can relocalize itself using AprilTags on the hub.';
const String _routeTooltip = 'Sweep order:\n'
    'Far -> Close: center field, then alliance side.\n'
    'Close -> Far: alliance side, then center field.';
const String _addPassTooltip = 'Add another sweeping pass to the auto.';
const String _startTooltip = 'Rush: normal center-line rush.\n'
    'Sneaky: hide in trench, wait using Auto Start Delay.';

class AutoStudioPage extends StatefulWidget {
  final SharedPreferences prefs;
  final PathPlannerAuto auto;
  final List<PathPlannerPath> allPaths;
  final List<ChoreoPath> allChoreoPaths;
  final List<String> allPathNames;
  final String pathDir;
  final String? initialAutoFolder;
  final FieldImage fieldImage;
  final ValueChanged<String> onRenamed;
  final VoidCallback? onAutoSaved;
  final VoidCallback? onPathsChanged;
  final ChangeStack undoStack;
  final bool shortcuts;
  final PPLibTelemetry? telemetry;
  final bool hotReload;

  const AutoStudioPage({
    super.key,
    required this.prefs,
    required this.auto,
    required this.allPaths,
    required this.allChoreoPaths,
    required this.allPathNames,
    required this.pathDir,
    this.initialAutoFolder,
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
  State<AutoStudioPage> createState() => _AutoStudioPageState();
}

class _AutoStudioPageState extends State<AutoStudioPage> {
  BattlecryAutoSpec _spec = BattlecryAutoSpec(
    passes: [BattlecryPassSpec()],
    finalSpec: null,
  );

  late List<PathPlannerPath> _allPaths;
  late List<String> _allPathNames;

  BattlecryAutoGenerationResult? _result;
  final Map<String, String> _pathCopyMap = {};
  List<String> _importWarnings = [];
  int _editorVersion = 0;
  late final String? _autoStudioFolder;
  late final String _autoStudioOriginalAutoName;
  late final bool _autoStudioOriginalAutoWasTemporary;

  @override
  void initState() {
    super.initState();

    _allPaths = List<PathPlannerPath>.of(widget.allPaths);
    _allPathNames = widget.allPathNames.toSet().toList()..sort();
    _autoStudioFolder = widget.initialAutoFolder ?? widget.auto.folder;
    _autoStudioOriginalAutoName = widget.auto.name;
    _autoStudioOriginalAutoWasTemporary =
        _isTemporaryAutoStudioName(widget.auto.name);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      if (widget.auto.sequence.commands.isNotEmpty) {
        final imported = _importCurrentAuto(
          showSuccess: false,
          saveAfterImport: false,
        );

        if (!imported) {
          setState(() {
            _result = BattlecryAutoGenerationResult(
              sequence: widget.auto.sequence,
              warnings: [
                'This auto is not builder-compatible yet. Use Import Current Auto after removing manual/custom commands, or edit it in the normal auto editor.',
              ],
              pathNames: BattlecryAutoGenerator.collectPathNames(
                widget.auto.sequence,
              ),
              namedCommandNames:
                  BattlecryAutoGenerator.collectNamedCommandNames(
                widget.auto.sequence,
              ),
            );
          });
        }
      } else {
        _applyBuilderChanges();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final editorWidget = _buildEditor();

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
            _applyBuilderChanges(save: true);
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
      body: Row(
        children: [
          SizedBox(
            width: 390,
            child: _buildBuilderPanel(),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: colorScheme.outlineVariant,
          ),
          Expanded(
            child: ConditionalWidget(
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
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    final autoPathNames = widget.auto.getAllPathNames();
    final autoPaths = <PathPlannerPath>[];
    final autoChoreoPaths = <ChoreoPath>[];

    if (widget.auto.choreoAuto) {
      for (final name in autoPathNames) {
        for (final path in widget.allChoreoPaths) {
          if (path.name == name) {
            autoChoreoPaths.add(path);
            break;
          }
        }
      }
    } else {
      for (final name in autoPathNames) {
        for (final path in _allPaths) {
          if (path.name == name) {
            autoPaths.add(path);
            break;
          }
        }
      }
    }

    return SplitAutoEditor(
      key: ValueKey(_editorVersion),
      prefs: widget.prefs,
      auto: widget.auto,
      autoPaths: autoPaths,
      autoChoreoPaths: autoChoreoPaths,
      allPaths: _allPaths,
      allChoreoPaths: widget.allChoreoPaths,
      pathDir: widget.pathDir,
      allPathNames: _allPathNames,
      fieldImage: widget.fieldImage,
      undoStack: widget.undoStack,
      onAutoChanged: () {
        setState(() {
          widget.auto.saveFile();
          _queueAutoStudioGeneratedPathFolderRepair();
          _deleteTemporaryAutoStudioSourceIfNeeded();
          _deleteTemporaryAutoStudioSourceIfNeeded();
          _repairAutoStudioGeneratedPathFoldersNow();
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
    );
  }

  Widget _buildBuilderPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    final missingPaths = _missingPaths();

    return Material(
      color: colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            'Frenzy Auto Studio',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Builder controls generate the real .auto file. The editor on the right is the normal PathPlanner auto editor.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message:
                      'Save this auto as a new editable copy with copied paths.',
                  waitDuration: const Duration(milliseconds: 500),
                  child: OutlinedButton.icon(
                    onPressed: _saveAsEditableCopy,
                    icon: const Icon(Icons.save_as_rounded),
                    label: const Text('Save As'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loadExistingAutoDialog,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Load Auto'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildPassesCard(),
          const SizedBox(height: 12),
          _buildFinalCard(),
          const SizedBox(height: 12),
          _buildSequenceCard(missingPaths),
        ],
      ),
    );
  }

  Widget _buildPassesCard() {
    return _sectionCard(
      title: 'Passes',
      trailing: Tooltip(
        message: _addPassTooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: FilledButton.icon(
          onPressed: () {
            setState(() {
              _spec.passes.add(BattlecryPassSpec());
              _importWarnings = [];
            });
            _applyBuilderChanges();
          },
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add'),
        ),
      ),
      child: Column(
        children: [
          if (_spec.passes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'No passes. Use a final dot for a zero-pass auto, or add a pass.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (int i = 0; i < _spec.passes.length; i++) ...[
            _buildPassCard(i, _spec.passes[i]),
            if (i != _spec.passes.length - 1) const Divider(height: 22),
          ],
        ],
      ),
    );
  }

  Widget _buildPassCard(int index, BattlecryPassSpec pass) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFirstPass = index == 0;
    final usesSecondPassPaths = !isFirstPass || pass.start == 'sneaky';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Pass ${index + 1}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (!isFirstPass)
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () {
                  setState(() {
                    _spec.passes.removeAt(index);
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              ),
          ],
        ),
        if (isFirstPass) ...[
          _dropdown(
            label: 'Start',
            value: pass.start,
            values: const ['rush', 'sneaky'],
            onChanged: (value) {
              setState(() {
                pass.start = value;
                _importWarnings = [];
              });
              _applyBuilderChanges();
            },
          ),
          const SizedBox(height: 8),
          Text(
            pass.start == 'sneaky'
                ? 'Sneaky start never uses first-pass paths. Add another pass or choose a final sweep/dot to move. Sneaky + None generates an empty auto.'
                : 'Pass 1 uses the fixed first-pass path family, so route is not selectable.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
        _switchRow(
          label: 'Risky',
          value: pass.risky,
          onChanged: (value) {
            setState(() {
              pass.risky = value;
              _importWarnings = [];
            });
            _applyBuilderChanges();
          },
        ),
        _switchRow(
          label: 'Greedy',
          value: pass.greedy,
          onChanged: (value) {
            setState(() {
              pass.greedy = value;
              _importWarnings = [];
            });
            _applyBuilderChanges();
          },
        ),
        _switchRow(
          label: 'Hub Sweep',
          value: pass.hub,
          onChanged: (value) {
            setState(() {
              pass.hub = value;
              _importWarnings = [];
            });
            _applyBuilderChanges();
          },
        ),
        if (usesSecondPassPaths)
          _switchRow(
            label: 'Localize Return',
            value: pass.localize,
            onChanged: (value) {
              setState(() {
                pass.localize = value;
                _importWarnings = [];
              });
              _applyBuilderChanges();
            },
          ),
        if (usesSecondPassPaths)
          _dropdown(
            label: 'Route',
            value: pass.route,
            values: const ['Far -> Close', 'Close -> Far'],
            onChanged: (value) {
              setState(() {
                pass.route = value;
                _importWarnings = [];
              });
              _applyBuilderChanges();
            },
          ),
      ],
    );
  }

  bool _frenzyDotsEnabled() {
    return widget.prefs.getBool(PrefsKeys.hasFrenzyDot) ??
        Defaults.hasFrenzyDot;
  }

  Widget _buildFinalCard() {
    final finalSpec = _spec.finalSpec;
    final hasFrenzyDot = _frenzyDotsEnabled();
    final selectedFinalType = !hasFrenzyDot && finalSpec?.type == 'dot'
        ? 'none'
        : (finalSpec?.type ?? 'none');
    return _sectionCard(
      title: 'Final',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message:
                'Choose whether the auto ends with no extra action, a dot path, or a final non-returning sweep.',
            child: SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'none', label: Text('None')),
                if (hasFrenzyDot)
                  const ButtonSegment(value: 'dot', label: Text('Dot')),
                const ButtonSegment(value: 'sweep', label: Text('Sweep')),
              ],
              selected: {selectedFinalType},
              onSelectionChanged: (selected) {
                final value = selected.first;
                setState(() {
                  _spec.finalSpec =
                      value == 'none' ? null : BattlecryFinalSpec(type: value);
                  _importWarnings = [];
                });
                _applyBuilderChanges();
              },
            ),
          ),
          if (finalSpec != null) ...[
            const SizedBox(height: 12),
            if (finalSpec.type == 'dot' && hasFrenzyDot) ...[
              _dropdown(
                label: 'Dot',
                value: finalSpec.dot,
                values: const ['center', 'close'],
                onChanged: (value) {
                  setState(() {
                    finalSpec.dot = value;
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              ),
              _switchRow(
                label: 'Sweep Before Dot',
                value: finalSpec.sweepBeforeDot,
                onChanged: (value) {
                  setState(() {
                    finalSpec.sweepBeforeDot = value;
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              ),
              if (finalSpec.sweepBeforeDot) ...[
                _switchRow(
                  label: 'Full Sweep',
                  value: finalSpec.fullSweepBeforeDot,
                  onChanged: (value) {
                    setState(() {
                      finalSpec.fullSweepBeforeDot = value;
                      _importWarnings = [];
                    });
                    _applyBuilderChanges();
                  },
                ),
                if (finalSpec.fullSweepBeforeDot)
                  _dropdown(
                    label: 'Route',
                    value: finalSpec.route,
                    values: const ['Far -> Close', 'Close -> Far'],
                    onChanged: (value) {
                      setState(() {
                        finalSpec.route = value;
                        _importWarnings = [];
                      });
                      _applyBuilderChanges();
                    },
                  )
                else
                  _dropdown(
                    label: 'Half Sweep',
                    value: finalSpec.halfSweep,
                    values: const ['close', 'far'],
                    onChanged: (value) {
                      setState(() {
                        finalSpec.halfSweep = value;
                        _importWarnings = [];
                      });
                      _applyBuilderChanges();
                    },
                  ),
                _switchRow(
                  label: 'Risky',
                  value: finalSpec.risky,
                  onChanged: (value) {
                    setState(() {
                      finalSpec.risky = value;
                      _importWarnings = [];
                    });
                    _applyBuilderChanges();
                  },
                ),
                if (finalSpec.fullSweepBeforeDot)
                  _switchRow(
                    label: 'Greedy',
                    value: finalSpec.greedy,
                    onChanged: (value) {
                      setState(() {
                        finalSpec.greedy = value;
                        _importWarnings = [];
                      });
                      _applyBuilderChanges();
                    },
                  ),
                _switchRow(
                  label: 'Hub Sweep',
                  value: finalSpec.hub,
                  onChanged: (value) {
                    setState(() {
                      finalSpec.hub = value;
                      _importWarnings = [];
                    });
                    _applyBuilderChanges();
                  },
                ),
                Tooltip(
                  message:
                      'When enabled, dot sweeps include the pass-start/pass-dot behavior. When disabled, the sweep drives directly to the dot.',
                  child: _switchRow(
                    label: 'Pass Option',
                    value: finalSpec.passOption,
                    onChanged: (value) {
                      setState(() {
                        finalSpec.passOption = value;
                        _importWarnings = [];
                      });
                      _applyBuilderChanges();
                    },
                  ),
                ),
              ],
            ] else ...[
              _switchRow(
                label: 'Risky',
                value: finalSpec.risky,
                onChanged: (value) {
                  setState(() {
                    finalSpec.risky = value;
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              ),
              _switchRow(
                label: 'Greedy',
                value: finalSpec.greedy,
                onChanged: (value) {
                  setState(() {
                    finalSpec.greedy = value;
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              ),
              _switchRow(
                label: 'Hub Sweep',
                value: finalSpec.hub,
                onChanged: (value) {
                  setState(() {
                    finalSpec.hub = value;
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              ),
              _dropdown(
                label: 'Route',
                value: finalSpec.route,
                values: const ['Far -> Close', 'Close -> Far'],
                onChanged: (value) {
                  setState(() {
                    finalSpec.route = value;
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSequenceCard(List<String> missingPaths) {
    final colorScheme = Theme.of(context).colorScheme;
    final result = _result;

    return _sectionCard(
      title: 'Generated Output',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Use Save As to make an editable auto copy with copied paths.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const Divider(height: 24),
          if (result == null)
            const Text('No output yet.')
          else ...[
            Text(
              '${result.pathNames.length} path(s), ${result.namedCommandNames.length} named command(s)',
            ),
            if (result.warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final warning in result.warnings)
                Text(
                  '⚠ $warning',
                  style: TextStyle(color: colorScheme.error),
                ),
            ],
            if (missingPaths.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Missing path files:',
                style: TextStyle(
                  color: colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final missing in missingPaths.take(8))
                Text('• $missing', style: TextStyle(color: colorScheme.error)),
              if (missingPaths.length > 8)
                Text(
                  '• +${missingPaths.length - 8} more',
                  style: TextStyle(color: colorScheme.error),
                ),
            ],
            const SizedBox(height: 8),
            for (int i = 0; i < result.pathNames.length; i++)
              Text('${i + 1}. ${result.pathNames[i]}'),
          ],
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    String tooltip = '',
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required List<String> values,
    required ValueChanged<String> onChanged,
    String tooltip = '',
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final item in values)
              DropdownMenuItem(
                value: item,
                child: Text(
                  item,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              onChanged(value);
            }
          },
        ),
      ),
    );
  }

  bool _importCurrentAuto({
    bool showSuccess = true,
    bool saveAfterImport = false,
  }) {
    try {
      final imported = BattlecryAutoGenerator.parseExistingAuto(
        widget.auto.sequence,
      );

      setState(() {
        _spec = imported.spec.copy();
        _pathCopyMap
          ..clear()
          ..addAll(imported.pathCopyMap);
        _importWarnings = List<String>.of(imported.warnings);
      });

      _applyBuilderChanges(save: saveAfterImport);

      if (showSuccess && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported "${widget.auto.name}" into Auto Studio'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      return true;
    } catch (err) {
      if (showSuccess && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not import this auto: $err'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }
  }

  Future<void> _saveAsEditableCopy() async {
    final controller = TextEditingController(text: '${widget.auto.name} Copy');

    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Save As Editable Copy'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'New auto name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                Navigator.of(dialogContext).pop(value);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(controller.text);
              },
              child: const Text('Save As'),
            ),
          ],
        );
      },
    );

    if (!mounted || newName == null || newName.trim().isEmpty) {
      return;
    }

    final safeName = _safeFileName(newName);
    final targetAutoFolder = _autoStudioFolder;
    setState(() {
      widget.auto.name = safeName;
      widget.auto.folder = targetAutoFolder;
      _pathCopyMap.clear();
      _importWarnings = [];
    });

    _ensureFolderPref(PrefsKeys.autoFolders, targetAutoFolder);
    _applyBuilderChanges(save: true);
    await _copyGeneratedPathsForThisAuto();

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "$safeName" with copied editable paths'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    _queueAutoStudioGeneratedPathFolderRepair();
  }

  Future<void> _loadExistingAutoDialog() async {
    final autos = _listExistingAutoNames();
    if (autos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No .auto files were found in this project.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Load Existing Auto'),
          content: SizedBox(
            width: 420,
            height: 420,
            child: ListView.builder(
              itemCount: autos.length,
              itemBuilder: (context, index) {
                final autoName = autos[index];
                return ListTile(
                  title: Text(autoName, overflow: TextOverflow.ellipsis),
                  selected: autoName == widget.auto.name,
                  onTap: () => Navigator.of(dialogContext).pop(autoName),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );

    if (!mounted || selected == null) {
      return;
    }

    _loadAutoByName(selected);
  }

  List<String> _listExistingAutoNames() {
    final autosDir = widget.auto.fs.directory(widget.auto.autoDir);
    if (!autosDir.existsSync()) {
      return [];
    }

    final names = <String>[];
    for (final entity in autosDir.listSync()) {
      if (entity.path.endsWith('.auto')) {
        names.add(p.basenameWithoutExtension(entity.path));
      }
    }

    names.sort();
    return names;
  }

  void _loadAutoByName(String autoName) {
    try {
      final file = widget.auto.fs.file(
        p.join(widget.auto.autoDir, '$autoName.auto'),
      );
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);

      if (decoded is! Map<String, dynamic>) {
        throw StateError('auto file root is not a JSON object');
      }

      final loaded = PathPlannerAuto.fromJson(
        decoded,
        autoName,
        widget.auto.autoDir,
        widget.auto.fs,
      );

      widget.undoStack.clearHistory();

      setState(() {
        widget.auto.name = loaded.name;
        widget.auto.sequence = loaded.sequence;
        widget.auto.resetOdom = loaded.resetOdom;
        widget.auto.folder = loaded.folder;
        widget.auto.choreoAuto = loaded.choreoAuto;
        widget.auto.lastModified = file.lastModifiedSync().toUtc();
        _editorVersion++;
      });

      final imported = _importCurrentAuto(
        showSuccess: false,
        saveAfterImport: false,
      );

      if (imported) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded and imported "$autoName"'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        setState(() {
          _result = BattlecryAutoGenerationResult(
            sequence: widget.auto.sequence,
            warnings: [
              'Loaded "$autoName", but it could not be represented by Auto Studio builder controls.',
            ],
            pathNames: BattlecryAutoGenerator.collectPathNames(
              widget.auto.sequence,
            ),
            namedCommandNames: BattlecryAutoGenerator.collectNamedCommandNames(
              widget.auto.sequence,
            ),
          );
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Loaded "$autoName", but it is not builder-compatible.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      widget.onAutoSaved?.call();
    } catch (err) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load "$autoName": $err'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _safeRenameOrRemoveOldAutoFile(
    File sourceFile,
    File targetFile,
  ) async {
    if (sourceFile.path == targetFile.path) {
      return;
    }

    try {
      if (await targetFile.exists()) {
        if (await sourceFile.exists()) {
          await sourceFile.delete();
        }
        return;
      }

      if (await sourceFile.exists()) {
        await _safeRenameOrRemoveOldAutoFile(sourceFile, File(targetFile.path));
      }
    } on FileSystemException {
      // Windows throws "Access is denied" when trying to rename over an
      // existing file. In Save As, the destination may already have been saved,
      // so never overwrite it here.
      if (await targetFile.exists()) {
        if (await sourceFile.exists()) {
          await sourceFile.delete();
        }
        return;
      }

      if (await sourceFile.exists()) {
        try {
          await sourceFile.copy(targetFile.path);
          await sourceFile.delete();
          return;
        } on FileSystemException {
          rethrow;
        }
      }

      rethrow;
    }
  }

  void _safeRenameOrRemoveOldAutoFileSync(
    File sourceFile,
    File targetFile,
  ) {
    if (sourceFile.path == targetFile.path) {
      return;
    }

    try {
      if (targetFile.existsSync()) {
        if (sourceFile.existsSync()) {
          sourceFile.deleteSync();
        }
        return;
      }

      if (sourceFile.existsSync()) {
        _safeRenameOrRemoveOldAutoFileSync(sourceFile, File(targetFile.path));
      }
    } on FileSystemException {
      // Windows throws "Access is denied" when trying to rename over an
      // existing file. In Save As, the destination may already have been saved,
      // so never overwrite it here.
      if (targetFile.existsSync()) {
        if (sourceFile.existsSync()) {
          sourceFile.deleteSync();
        }
        return;
      }

      if (sourceFile.existsSync()) {
        try {
          sourceFile.copySync(targetFile.path);
          sourceFile.deleteSync();
          return;
        } on FileSystemException {
          rethrow;
        }
      }

      rethrow;
    }
  }

  void _applyBuilderChanges({bool save = true, bool updateAuto = true}) {
    BattlecryAutoGenerationResult generated;
    try {
      final generationSpec = _spec.copy();
      if (!_frenzyDotsEnabled() && generationSpec.finalSpec?.type == 'dot') {
        generationSpec.finalSpec = null;
      }
      generated = BattlecryAutoGenerator.generate(generationSpec);
      if (_pathCopyMap.isNotEmpty) {
        _rewriteCopiedPathNames(generated.sequence);
      }

      generated = BattlecryAutoGenerationResult(
        sequence: generated.sequence,
        warnings: [
          ..._importWarnings,
          ...generated.warnings,
        ],
        pathNames: BattlecryAutoGenerator.collectPathNames(generated.sequence),
        namedCommandNames: BattlecryAutoGenerator.collectNamedCommandNames(
          generated.sequence,
        ),
      );
    } catch (err) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not generate auto: $err'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _result = generated;

      if (updateAuto) {
        widget.auto.sequence = generated.sequence;
        widget.auto.resetOdom = true;
        widget.auto.choreoAuto = false;
        widget.auto.folder = _autoStudioFolder;
        _editorVersion++;
      }
    });

    if (!updateAuto) {
      return;
    }

    _ensureFolderPref(PrefsKeys.autoFolders, _autoStudioFolder);

    _ensureFolderPref(PrefsKeys.autoFolders, widget.auto.folder);

    if (save) {
      widget.auto.saveFile();
      _queueAutoStudioGeneratedPathFolderRepair();
      _deleteTemporaryAutoStudioSourceIfNeeded();
      _deleteTemporaryAutoStudioSourceIfNeeded();
      _repairAutoStudioGeneratedPathFoldersNow();
      widget.onAutoSaved?.call();
      if (widget.hotReload) {
        widget.telemetry?.hotReloadAuto(widget.auto);
      }
    }
  }

  Future<void> _copyGeneratedPathsForThisAuto() async {
    final originalGenerated = BattlecryAutoGenerator.generate(_spec.copy());
    final sourcePathNames = originalGenerated.pathNames.toSet().toList();
    final copiedNames = <String>[];
    final reusedNames = <String>[];
    final missingNames = <String>[];

    final folder = _autoStudioGeneratedPathFolderName();
    final waypointPrefix = '${_safeFileName(widget.auto.name)}_';

    _ensureFolderPref(
        PrefsKeys.pathFolders, _autoStudioGeneratedPathFolderName());

    for (final sourceName in sourcePathNames) {
      if (_pathCopyMap.containsKey(sourceName)) {
        reusedNames.add(_pathCopyMap[sourceName]!);
        continue;
      }

      final src =
          widget.auto.fs.file(p.join(widget.pathDir, '$sourceName.path'));
      if (!src.existsSync()) {
        missingNames.add(sourceName);
        continue;
      }

      final copiedName = _safeFileName('${widget.auto.name} - $sourceName');
      final dst =
          widget.auto.fs.file(p.join(widget.pathDir, '$copiedName.path'));

      if (!dst.existsSync()) {
        final raw = src.readAsStringSync();
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          missingNames.add(sourceName);
          continue;
        }

        decoded['folder'] = _autoStudioGeneratedPathFolderName();
        _prefixLinkedWaypoints(decoded, waypointPrefix);

        const encoder = JsonEncoder.withIndent('  ');
        dst.writeAsStringSync('${encoder.convert(decoded)}\n');

        final copiedPath = PathPlannerPath.fromJson(
          decoded,
          copiedName,
          widget.pathDir,
          widget.auto.fs,
        );
        copiedPath.folder = _autoStudioGeneratedPathFolderName();
        copiedPath.lastModified = dst.lastModifiedSync().toUtc();
        _addLocalPath(copiedPath);
        copiedNames.add(copiedName);
      } else {
        final raw = dst.readAsStringSync();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          decoded['folder'] = _autoStudioGeneratedPathFolderName();
          const encoder = JsonEncoder.withIndent('  ');
          dst.writeAsStringSync('${encoder.convert(decoded)}\n');

          final copiedPath = PathPlannerPath.fromJson(
            decoded,
            copiedName,
            widget.pathDir,
            widget.auto.fs,
          );
          copiedPath.folder = _autoStudioGeneratedPathFolderName();
          copiedPath.lastModified = dst.lastModifiedSync().toUtc();
          _addLocalPath(copiedPath);
        }
        reusedNames.add(copiedName);
      }

      _pathCopyMap[sourceName] = copiedName;
    }

    _applyBuilderChanges();
    widget.onPathsChanged?.call();

    if (!mounted) {
      return;
    }

    final message = [
      if (copiedNames.isNotEmpty) 'Copied ${copiedNames.length} path(s)',
      if (reusedNames.isNotEmpty) 'reused ${reusedNames.length}',
      if (missingNames.isNotEmpty) 'missing ${missingNames.length}',
    ].join(', ');

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message.isEmpty ? 'No paths copied' : message),
        behavior: SnackBarBehavior.floating,
      ),
    );
    _repairAutoStudioGeneratedPathFoldersNow();
    _queueAutoStudioGeneratedPathFolderRepair();
  }

  void _rewriteCopiedPathNames(Command command) {
    void walk(Command cmd) {
      if (cmd is PathCommand && cmd.pathName != null) {
        cmd.pathName = _pathCopyMap[cmd.pathName] ?? cmd.pathName;
      } else if (cmd is CommandGroup) {
        for (final child in cmd.commands) {
          walk(child);
        }
      }
    }

    walk(command);
  }

  void _prefixLinkedWaypoints(Map<String, dynamic> pathJson, String prefix) {
    final waypoints = pathJson['waypoints'];
    if (waypoints is! List) {
      return;
    }

    for (final waypoint in waypoints) {
      if (waypoint is Map) {
        final linkedName = waypoint['linkedName'];
        if (linkedName is String &&
            linkedName.isNotEmpty &&
            !linkedName.startsWith(prefix)) {
          waypoint['linkedName'] = '$prefix$linkedName';
        }
      }
    }
  }

  void _addLocalPath(PathPlannerPath path) {
    final existingIndex =
        _allPaths.indexWhere((item) => item.name == path.name);
    setState(() {
      if (existingIndex >= 0) {
        _allPaths[existingIndex] = path;
      } else {
        _allPaths.add(path);
      }

      if (!_allPathNames.contains(path.name)) {
        _allPathNames.add(path.name);
        _allPathNames.sort();
      }
    });
  }

  void _ensureFolderPref(String key, String? folder) {
    if (folder == null || folder.trim().isEmpty) {
      return;
    }

    final folders = widget.prefs.getStringList(key) ?? <String>[];
    if (!folders.contains(folder)) {
      folders.add(folder);
      folders.sort();
      widget.prefs.setStringList(key, folders);
    }

    _ensureFolderInSettingsFile(key, folder);
  }

  void _ensureFolderInSettingsFile(String key, String folder) {
    try {
      final pathplannerDir = p.dirname(widget.pathDir);
      final settingsFile = widget.auto.fs.file(
        p.join(pathplannerDir, 'settings.json'),
      );

      Map<String, dynamic> decoded = {};
      if (settingsFile.existsSync()) {
        final raw = settingsFile.readAsStringSync();
        final parsed = jsonDecode(raw);
        if (parsed is Map<String, dynamic>) {
          decoded = Map<String, dynamic>.from(parsed);
        }
      }

      final folders =
          (decoded[key] as List<dynamic>?)?.whereType<String>().toList() ??
              <String>[];

      if (!folders.contains(folder)) {
        folders.add(folder);
        folders.sort();
        decoded[key] = folders;
        const encoder = JsonEncoder.withIndent('  ');
        settingsFile.writeAsStringSync('${encoder.convert(decoded)}\n');
      }
    } catch (err) {
      debugPrint(
          'Failed to update PathPlanner settings folder $key/$folder: $err');
    }
  }

  List<String> _missingPaths() {
    final result = _result;
    if (result == null) {
      return [];
    }

    return [
      for (final pathName in result.pathNames)
        if (!_allPathNames.contains(pathName)) pathName,
    ];
  }

  String _autoStudioGeneratedPathFolderName() {
    final name = widget.auto.name.trim();
    return name.isEmpty ? 'Auto Studio' : name;
  }

  bool _isAutoStudioKnownSourceSpacedDashPath(String pathName) {
    return pathName == 'Shoot - Close' ||
        pathName == 'Shoot - Center' ||
        pathName == 'Close - Center' ||
        pathName == 'Close - Close' ||
        pathName == 'Sneaky - Center' ||
        pathName == 'Sneaky - Close';
  }

  bool _looksLikeAutoStudioGeneratedPathName(String pathName) {
    final trimmed = pathName.trim();
    if (trimmed.isEmpty) {
      return false;
    }

    if (trimmed.startsWith('${_autoStudioGeneratedPathFolderName()} - ')) {
      return true;
    }

    return trimmed.contains(' - ') &&
        !_isAutoStudioKnownSourceSpacedDashPath(trimmed);
  }

  Set<String> _autoStudioGeneratedPathNamesForFolderFix() {
    final folder = _autoStudioGeneratedPathFolderName();
    final prefix = '$folder - ';
    final names = <String>{};

    void addIfGenerated(String? pathName) {
      if (pathName == null) {
        return;
      }

      final trimmed = pathName.trim();
      if (_looksLikeAutoStudioGeneratedPathName(trimmed)) {
        names.add(trimmed);
      }
    }

    try {
      for (final pathName in widget.auto.getAllPathNames()) {
        addIfGenerated(pathName);
      }
    } catch (_) {
      // Ignore incomplete intermediate auto states.
    }

    final result = _result;
    if (result != null) {
      for (final pathName in result.pathNames) {
        addIfGenerated(pathName);
      }
    }

    try {
      final pathsDir = widget.auto.fs.directory(widget.pathDir);
      if (pathsDir.existsSync()) {
        for (final entity in pathsDir.listSync()) {
          final entityPath = entity.path.toString();
          if (!entityPath.toLowerCase().endsWith('.path')) {
            continue;
          }

          final pathName = p.basenameWithoutExtension(entityPath);
          if (pathName.startsWith(prefix)) {
            names.add(pathName);
          }
        }
      }
    } catch (_) {
      // Best effort. The direct save/copy calls also queue later repairs.
    }

    return names;
  }

  void _repairAutoStudioGeneratedPathFoldersNow() {
    final folder = _autoStudioGeneratedPathFolderName();
    final pathNames = _autoStudioGeneratedPathNamesForFolderFix();

    if (pathNames.isEmpty) {
      return;
    }

    _ensureFolderPref(PrefsKeys.pathFolders, folder);
    const encoder = JsonEncoder.withIndent('  ');

    for (final pathName in pathNames) {
      final pathFile = widget.auto.fs.file(
        p.join(widget.pathDir, '$pathName.path'),
      );

      if (!pathFile.existsSync()) {
        continue;
      }

      try {
        final decoded = jsonDecode(pathFile.readAsStringSync());
        if (decoded is! Map<String, dynamic>) {
          continue;
        }

        if (decoded['folder'] != folder) {
          decoded['folder'] = folder;
          pathFile.writeAsStringSync('${encoder.convert(decoded)}\n');
        }
      } catch (err) {
        debugPrint(
            'Failed to repair generated path folder for $pathName: $err');
      }
    }

    for (final path in _allPaths) {
      if (pathNames.contains(path.name)) {
        path.folder = folder;
      }
    }

    widget.onPathsChanged?.call();
  }

  void _queueAutoStudioGeneratedPathFolderRepair() {
    _repairAutoStudioGeneratedPathFoldersNow();

    for (final delayMs in const [100, 500, 1500, 3000]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted) {
          return;
        }

        _repairAutoStudioGeneratedPathFoldersNow();
      });
    }
  }

  bool _isTemporaryAutoStudioName(String name) {
    final trimmed = name.trim();
    return trimmed == 'New Frenzy Auto' ||
        trimmed == 'New Frenzy Auto' ||
        RegExp(r'^New Frenzy Auto [0-9]+\$').hasMatch(trimmed) ||
        RegExp(r'^New Frenzy Auto [0-9]+\$').hasMatch(trimmed);
  }

  void _deleteTemporaryAutoStudioSourceIfNeeded() {
    final originalName = _autoStudioOriginalAutoName;
    if (!_autoStudioOriginalAutoWasTemporary ||
        originalName == widget.auto.name) {
      return;
    }

    try {
      final pathplannerDir = p.dirname(widget.pathDir);
      final autosDir = p.join(pathplannerDir, 'autos');
      final oldAuto =
          widget.auto.fs.file(p.join(autosDir, '$originalName.auto'));
      final newAuto = widget.auto.fs.file(
        p.join(autosDir, '${widget.auto.name}.auto'),
      );

      if (oldAuto.existsSync() && newAuto.existsSync()) {
        oldAuto.deleteSync();
        widget.onAutoSaved?.call();
      }
    } catch (err) {
      debugPrint('Failed to delete temporary Auto Studio source auto: $err');
    }
  }

  String _folderForAuto(String name) {
    final cleaned = _safeFileName(name);
    return cleaned.isEmpty ? 'Generated Auto' : cleaned;
  }

  String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return cleaned.replaceAll(RegExp(r'\s+'), ' ');
  }
}
