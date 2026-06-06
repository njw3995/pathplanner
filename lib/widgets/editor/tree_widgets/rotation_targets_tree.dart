import 'package:flutter/material.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/rotation_target.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/util/wpimath/math_util.dart';
import 'package:pathplanner/widgets/editor/info_card.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/item_count.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/tree_card_node.dart';
import 'package:pathplanner/widgets/number_text_field.dart';
import 'package:pathplanner/widgets/renamable_title.dart';
import 'package:undo/undo.dart';

class RotationTargetsTree extends StatefulWidget {
  final PathPlannerPath path;
  final VoidCallback? onPathChanged;
  final VoidCallback? onPathChangedNoSim;
  final ValueChanged<int?>? onTargetHovered;
  final ValueChanged<int?>? onTargetSelected;
  final int? initiallySelectedTarget;
  final ChangeStack undoStack;

  const RotationTargetsTree({
    super.key,
    required this.path,
    this.onPathChanged,
    this.onPathChangedNoSim,
    this.onTargetHovered,
    this.onTargetSelected,
    this.initiallySelectedTarget,
    required this.undoStack,
  });

  @override
  State createState() => _RotationTargetsTreeState();
}

class _RotationTargetsTreeState extends State<RotationTargetsTree> {
  List<RotationTarget> get rotations => widget.path.rotationTargets;
  List<Waypoint> get waypoints => widget.path.waypoints;

  List<ExpansibleController> _controllers = [];
  int? _selectedTarget;
  double _sliderChangeStart = 0;

  @override
  void initState() {
    super.initState();
    _selectedTarget = widget.initiallySelectedTarget;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _sortTargets();
    });
    _syncControllers();
  }

  @override
  Widget build(BuildContext context) {
    _syncControllers();

    return TreeCardNode(
      title: const Text('Rotation Targets'),
      leading: const Icon(Icons.rotate_90_degrees_cw_rounded),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            onPressed: () {
              widget.undoStack.add(Change(
                PathPlannerPath.cloneRotationTargets(rotations),
                () {
                  final target = RotationTarget(
                    0.5,
                    const Rotation2d(),
                    true,
                    _nextDefaultName(),
                  );
                  rotations.add(target);
                  _sortTargets(selectedTarget: target);
                  widget.onPathChanged?.call();
                },
                (oldValue) {
                  _selectedTarget = null;
                  widget.onTargetHovered?.call(null);
                  widget.onTargetSelected?.call(null);
                  widget.path.rotationTargets =
                      PathPlannerPath.cloneRotationTargets(oldValue);
                  _sortTargets();
                  widget.onPathChanged?.call();
                },
              ));
            },
          ),
          const SizedBox(width: 8),
          ItemCount(count: widget.path.rotationTargets.length),
        ],
      ),
      initiallyExpanded: widget.path.rotationTargetsExpanded,
      onExpansionChanged: (value) {
        if (value != null) {
          widget.path.rotationTargetsExpanded = value;
          if (value == false) {
            _selectedTarget = null;
            widget.onTargetSelected?.call(null);
          }
        }
      },
      elevation: 1.0,
      children: [
        for (int i = 0; i < rotations.length; i++) _buildRotationCard(i),
      ],
    );
  }

  void _syncControllers() {
    if (_controllers.length == rotations.length) {
      return;
    }

    _controllers = List.generate(
      rotations.length,
      (index) => ExpansibleController(),
    );

    if (_selectedTarget != null &&
        (_selectedTarget! < 0 || _selectedTarget! >= rotations.length)) {
      _selectedTarget = null;
    }
  }

  void _sortTargets({RotationTarget? selectedTarget}) {
    final selected = selectedTarget ??
        (_selectedTarget != null &&
                _selectedTarget! >= 0 &&
                _selectedTarget! < rotations.length
            ? rotations[_selectedTarget!] as RotationTarget
            : null);

    rotations.sort((a, b) {
      final posCompare = a.waypointRelativePos.compareTo(b.waypointRelativePos);
      if (posCompare != 0) {
        return posCompare;
      }

      return _targetName(a).compareTo(_targetName(b));
    });

    _syncControllers();

    if (selected != null) {
      final selectedIndex = rotations.indexOf(selected);
      _selectedTarget = selectedIndex >= 0 ? selectedIndex : null;
      widget.onTargetSelected?.call(_selectedTarget);
    }
  }

  String _targetName(RotationTarget target) {
    final name = target.name?.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }

    return 'Rotation Target ${rotations.indexOf(target) + 1}';
  }

  String _nextDefaultName() {
    var index = rotations.length + 1;
    while (rotations
        .any((target) => target.name?.trim() == 'Rotation Target $index')) {
      index++;
    }

    return 'Rotation Target $index';
  }

  void _renameTarget(int targetIdx, String newName) {
    if (targetIdx < 0 || targetIdx >= rotations.length) {
      return;
    }

    final target = rotations[targetIdx];
    final oldTarget = target.clone();
    final trimmedName = newName.trim();
    final nextName = trimmedName.isEmpty ? null : trimmedName;

    if (target.name == nextName) {
      return;
    }

    widget.undoStack.add(Change(
      oldTarget,
      () {
        target.name = nextName;
        _sortTargets(selectedTarget: target);
        widget.onPathChanged?.call();
      },
      (oldValue) {
        target.name = oldValue.name;
        _sortTargets(selectedTarget: target);
        widget.onPathChanged?.call();
      },
    ));
  }

  Widget _buildRotationCard(int targetIdx) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    final target = rotations[targetIdx];

    return TreeCardNode(
      leading: const Icon(Icons.rotate_right_rounded),
      controller: _controllers[targetIdx],
      onHoverStart: () => widget.onTargetHovered?.call(targetIdx),
      onHoverEnd: () => widget.onTargetHovered?.call(null),
      onExpansionChanged: (expanded) {
        if (expanded ?? false) {
          if (_selectedTarget != null &&
              _selectedTarget! >= 0 &&
              _selectedTarget! < _controllers.length) {
            _controllers[_selectedTarget!].collapse();
          }
          _selectedTarget = targetIdx;
          widget.onTargetSelected?.call(targetIdx);
        } else {
          if (targetIdx == _selectedTarget) {
            _selectedTarget = null;
            widget.onTargetSelected?.call(null);
          }
        }
      },
      title: Row(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: RenamableTitle(
                title: _targetName(target),
                textStyle: const TextStyle(fontSize: 16),
                onRename: (newName) => _renameTarget(targetIdx, newName),
              ),
            ),
          ),
          const SizedBox(width: 8),
          InfoCard(
            value:
                '${target.rotation.degrees.toStringAsFixed(2)}° at ${target.waypointRelativePos.toStringAsFixed(2)}',
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            color: colorScheme.error,
            onPressed: () {
              widget.undoStack.add(Change(
                PathPlannerPath.cloneRotationTargets(
                    widget.path.rotationTargets),
                () {
                  rotations.removeAt(targetIdx);
                  _sortTargets();
                  widget.onTargetSelected?.call(null);
                  widget.onTargetHovered?.call(null);
                  widget.onPathChanged?.call();
                },
                (oldValue) {
                  widget.path.rotationTargets =
                      PathPlannerPath.cloneRotationTargets(oldValue);
                  _sortTargets();
                  widget.onTargetSelected?.call(null);
                  widget.onTargetHovered?.call(null);
                  widget.onPathChanged?.call();
                },
              ));
            },
          ),
        ],
      ),
      initiallyExpanded: targetIdx == _selectedTarget,
      elevation: 4.0,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6.0),
          child: Row(
            children: [
              Expanded(
                child: NumberTextField(
                  initialValue: target.rotation.degrees,
                  label: 'Rotation (Deg)',
                  arrowKeyIncrement: 45,
                  onSubmitted: (value) {
                    if (value != null) {
                      final oldTarget = target.clone();
                      widget.undoStack.add(Change(
                        oldTarget,
                        () {
                          target.rotation = Rotation2d.fromDegrees(
                            MathUtil.inputModulus(value, -180, 180),
                          );
                          widget.onPathChanged?.call();
                        },
                        (oldValue) {
                          target.rotation = oldValue.rotation;
                          widget.onPathChanged?.call();
                        },
                      ));
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: NumberTextField(
                  initialValue: target.waypointRelativePos,
                  label: 'Position',
                  arrowKeyIncrement: 0.1,
                  minValue: 0.0,
                  maxValue: (waypoints.length - 1.0),
                  precision: 2,
                  onSubmitted: (value) {
                    if (value != null) {
                      final oldTarget = target.clone();
                      widget.undoStack.add(Change(
                        oldTarget,
                        () {
                          setState(() {
                            target.waypointRelativePos = value;
                            _sortTargets(selectedTarget: target);
                            widget.onPathChanged?.call();
                          });
                        },
                        (oldValue) {
                          setState(() {
                            target.waypointRelativePos =
                                oldValue.waypointRelativePos;
                            _sortTargets(selectedTarget: target);
                            widget.onPathChanged?.call();
                          });
                        },
                      ));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Slider(
          value: target.waypointRelativePos.toDouble(),
          min: 0.0,
          max: waypoints.length - 1.0,
          label: target.waypointRelativePos.toStringAsFixed(2),
          onChangeStart: (value) {
            _sliderChangeStart = value;
          },
          onChangeEnd: (value) {
            widget.undoStack.add(Change(
              _sliderChangeStart,
              () {
                setState(() {
                  target.waypointRelativePos = value;
                  _sortTargets(selectedTarget: target);
                  widget.onPathChanged?.call();
                });
              },
              (oldValue) {
                setState(() {
                  target.waypointRelativePos = oldValue;
                  _sortTargets(selectedTarget: target);
                  widget.onPathChanged?.call();
                });
              },
            ));
          },
          onChanged: (value) {
            setState(() {
              target.waypointRelativePos = value;
              widget.onPathChangedNoSim?.call();
            });
          },
        ),
      ],
    );
  }
}
