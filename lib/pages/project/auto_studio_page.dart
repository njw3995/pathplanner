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

const String _riskyTooltip =
    'Risky goes further over the center line and takes more from your opponents.';
const String _greedyTooltip =
    'Greedy goes further over the middle of the field and takes more from your alliance partners.';
const String _hubSweepTooltip =
    'Hub Sweep intakes next to the hub for the close sweep.';
const String _localizeTooltip =
    'Localize Return slows the robot down before going over the bump so it can relocalize itself using AprilTags on the hub.';
const String _routeTooltip =
    'Sweep order:\n'
    'Far -> Close: center field, then alliance side.\n'
    'Close -> Far: alliance side, then center field.';
const String _addPassTooltip = 'Add another sweeping pass to the auto.';
const String _startTooltip =
    'Rush: normal center-line rush.\n'
    'Sneaky: hide in trench, wait using Auto Start Delay.';
class AutoStudioPage extends StatefulWidget {
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

  const AutoStudioPage({
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
  State<AutoStudioPage> createState() => _AutoStudioPageState();
}

class _AutoStudioPageState extends State<AutoStudioPage> {
  BattlecryAutoSpec _spec = BattlecryAutoSpec(
    passes: [BattlecryPassSpec()],
    finalSpec: BattlecryFinalSpec(type: 'dot', dot: 'center'),
  );

  late List<PathPlannerPath> _allPaths;
  late List<String> _allPathNames;

  BattlecryAutoGenerationResult? _result;
  final Map<String, String> _pathCopyMap = {};
  List<String> _importWarnings = [];
  int _editorVersion = 0;

  @override
  void initState() {
    super.initState();

    _allPaths = List<PathPlannerPath>.of(widget.allPaths);
    _allPathNames = widget.allPathNames.toSet().toList()..sort();

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
              namedCommandNames: BattlecryAutoGenerator.collectNamedCommandNames(
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
      allPathNames: _allPathNames,
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
            'Battlecry Auto Studio',
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
                  message: 'Save this auto as a new editable copy with copied paths.',
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
                tooltip: 'Remove pass',
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
            tooltip: _startTooltip,
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
          tooltip: _riskyTooltip,
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
          tooltip: _greedyTooltip,
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
          tooltip: _hubSweepTooltip,
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
            tooltip: _localizeTooltip,
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
            tooltip: _routeTooltip,
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

  Widget _buildFinalCard() {
    final finalSpec = _spec.finalSpec;
    return _sectionCard(
      title: 'Final',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: 'Choose whether the auto ends with no extra action, a dot path, or a final non-returning sweep.',
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'none', label: Text('None')),
                ButtonSegment(value: 'dot', label: Text('Dot')),
                ButtonSegment(value: 'sweep', label: Text('Sweep')),
              ],
              selected: {finalSpec?.type ?? 'none'},
              onSelectionChanged: (selected) {
                final value = selected.first;
                setState(() {
                  _spec.finalSpec = value == 'none'
                      ? null
                      : BattlecryFinalSpec(type: value);
                  _importWarnings = [];
                });
                _applyBuilderChanges();
              },
            ),
          ),
          if (finalSpec != null) ...[
            const SizedBox(height: 12),
            if (finalSpec.type == 'dot')
              _dropdown(
                label: 'Dot',
                value: finalSpec.dot,
                values: const ['center', 'close'],
                tooltip: 'Choose which Battlecry dot path the auto ends at.',
                onChanged: (value) {
                  setState(() {
                    finalSpec.dot = value;
                    _importWarnings = [];
                  });
                  _applyBuilderChanges();
                },
              )
            else ...[
              _switchRow(
                label: 'Risky',
                value: finalSpec.risky,
                tooltip: _riskyTooltip,
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
                tooltip: _greedyTooltip,
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
                tooltip: _hubSweepTooltip,
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
                tooltip: _routeTooltip,
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
    required String tooltip,
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
    required String tooltip,
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
    setState(() {
      widget.auto.name = safeName;
      _pathCopyMap.clear();
      _importWarnings = [];
    });

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

  void _applyBuilderChanges({bool save = true}) {
    BattlecryAutoGenerationResult generated;
    try {
      generated = BattlecryAutoGenerator.generate(_spec.copy());
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
      widget.auto.sequence = generated.sequence;
      widget.auto.resetOdom = true;
      widget.auto.choreoAuto = false;
      _editorVersion++;
    });

    _ensureFolderPref(PrefsKeys.autoFolders, widget.auto.folder);

    if (save) {
      widget.auto.saveFile();
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

    final folder = _safeFileName(widget.auto.name);
    final waypointPrefix = '${_safeFileName(widget.auto.name)}_';

    _ensureFolderPref(PrefsKeys.pathFolders, folder);

    for (final sourceName in sourcePathNames) {
      if (_pathCopyMap.containsKey(sourceName)) {
        reusedNames.add(_pathCopyMap[sourceName]!);
        continue;
      }

      final src = widget.auto.fs.file(p.join(widget.pathDir, '$sourceName.path'));
      if (!src.existsSync()) {
        missingNames.add(sourceName);
        continue;
      }

      final copiedName = _safeFileName('${widget.auto.name} - $sourceName');
      final dst = widget.auto.fs.file(p.join(widget.pathDir, '$copiedName.path'));

      if (!dst.existsSync()) {
        final raw = src.readAsStringSync();
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          missingNames.add(sourceName);
          continue;
        }

        decoded['folder'] = folder;
        _prefixLinkedWaypoints(decoded, waypointPrefix);

        const encoder = JsonEncoder.withIndent('  ');
        dst.writeAsStringSync('${encoder.convert(decoded)}\n');

        final copiedPath = PathPlannerPath.fromJson(
          decoded,
          copiedName,
          widget.pathDir,
          widget.auto.fs,
        );
        copiedPath.lastModified = dst.lastModifiedSync().toUtc();
        _addLocalPath(copiedPath);
        copiedNames.add(copiedName);
      } else {
        final raw = dst.readAsStringSync();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final copiedPath = PathPlannerPath.fromJson(
            decoded,
            copiedName,
            widget.pathDir,
            widget.auto.fs,
          );
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
    final existingIndex = _allPaths.indexWhere((item) => item.name == path.name);
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

  String _folderForAuto(String name) {
    final cleaned = _safeFileName(name);
    return cleaned.isEmpty ? 'Generated Auto' : cleaned;
  }

  String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return cleaned.replaceAll(RegExp(r'\s+'), ' ');
  }
}
