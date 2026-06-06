import 'package:flutter/material.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/point_towards_zone.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/util/wpimath/math_util.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/item_count.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/tree_card_node.dart';
import 'package:pathplanner/widgets/number_text_field.dart';
import 'package:pathplanner/widgets/renamable_title.dart';
import 'package:undo/undo.dart';

class PointTowardsZonesTree extends StatefulWidget {
  final PathPlannerPath path;
  final VoidCallback? onPathChanged;
  final VoidCallback? onPathChangedNoSim;
  final ValueChanged<int?>? onZoneHovered;
  final ValueChanged<int?>? onZoneSelected;
  final int? initiallySelectedZone;
  final ChangeStack undoStack;

  const PointTowardsZonesTree({
    super.key,
    required this.path,
    this.onPathChanged,
    this.onPathChangedNoSim,
    this.onZoneHovered,
    this.onZoneSelected,
    this.initiallySelectedZone,
    required this.undoStack,
  });

  @override
  State<PointTowardsZonesTree> createState() => _PointTowardsZonesTreeState();
}

class _PointTowardsZonesTreeState extends State<PointTowardsZonesTree> {
  List<PointTowardsZone> get zones => widget.path.pointTowardsZones;
  List<Waypoint> get waypoints => widget.path.waypoints;

  late List<ExpansibleController> _controllers;
  int? _selectedZone;

  double _sliderChangeStart = 0;

  @override
  void initState() {
    super.initState();

    _selectedZone = widget.initiallySelectedZone;

    _controllers =
        List.generate(zones.length, (index) => ExpansibleController());
  }

  @override
  Widget build(BuildContext context) {
    _queueRemoveStaleZones();

    return TreeCardNode(
      title: const Text('Point Towards Zones'),
      leading: const Icon(Icons.rotate_left_rounded),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            onPressed: () {
              widget.undoStack.add(Change(
                PathPlannerPath.clonePointTowardsZones(zones),
                () {
                  zones.add(PointTowardsZone());
                  widget.onPathChanged?.call();
                },
                (oldValue) {
                  _selectedZone = null;
                  widget.onZoneHovered?.call(null);
                  widget.onZoneSelected?.call(null);
                  widget.path.pointTowardsZones =
                      PathPlannerPath.clonePointTowardsZones(oldValue);
                  widget.onPathChanged?.call();
                },
              ));
            },
            tooltip: 'Add New Point Towards Zone',
          ),
          const SizedBox(width: 8),
          ItemCount(count: zones.length),
        ],
      ),
      initiallyExpanded: widget.path.pointTowardsZonesExpanded,
      onExpansionChanged: (value) {
        if (value != null) {
          widget.path.pointTowardsZonesExpanded = value;
          if (value == false) {
            _selectedZone = null;
            widget.onZoneSelected?.call(null);
          }
        }
      },
      elevation: 1.0,
      children: [
        const Center(
          child: Text('Zones at the top of the list have higher priority'),
        ),
        const SizedBox(height: 6),
        for (int i = 0; i < zones.length; i++)
          if (_zoneInRange(zones[i])) _buildZoneCard(i),
      ],
    );
  }

  bool _zoneInRange(PointTowardsZone zone) {
    final maxWaypointPos = waypoints.length - 1.0;
    return maxWaypointPos >= 0.0 &&
        zone.minWaypointRelativePos >= 0.0 &&
        zone.maxWaypointRelativePos >= 0.0 &&
        zone.minWaypointRelativePos <= maxWaypointPos &&
        zone.maxWaypointRelativePos <= maxWaypointPos &&
        zone.minWaypointRelativePos <= zone.maxWaypointRelativePos;
  }

  void _queueRemoveStaleZones() {
    if (!zones.any((zone) => !_zoneInRange(zone))) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final staleIndices = <int>[];
      for (int i = 0; i < zones.length; i++) {
        if (!_zoneInRange(zones[i])) {
          staleIndices.add(i);
        }
      }

      if (staleIndices.isEmpty) {
        return;
      }

      widget.undoStack.add(Change(
        PathPlannerPath.clonePointTowardsZones(zones),
        () {
          for (final index in staleIndices.reversed) {
            if (index >= 0 && index < zones.length) {
              zones.removeAt(index);
            }
          }
          _controllers = List.generate(
            zones.length,
            (index) => ExpansibleController(),
          );
          _selectedZone = null;
          widget.onZoneHovered?.call(null);
          widget.onZoneSelected?.call(null);
          widget.onPathChanged?.call();
        },
        (oldValue) {
          widget.path.pointTowardsZones =
              PathPlannerPath.clonePointTowardsZones(oldValue);
          _controllers = List.generate(
            zones.length,
            (index) => ExpansibleController(),
          );
          _selectedZone = null;
          widget.onZoneHovered?.call(null);
          widget.onZoneSelected?.call(null);
          widget.onPathChanged?.call();
        },
      ));
    });
  }

  Widget _buildZoneCard(int zoneIdx) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    final linkedName = zones[zoneIdx].linkedName?.trim();

    return TreeCardNode(
      controller: _controllers[zoneIdx],
      onHoverStart: () => widget.onZoneHovered?.call(zoneIdx),
      onHoverEnd: () => widget.onZoneHovered?.call(null),
      onExpansionChanged: (expanded) {
        if (expanded ?? false) {
          if (_selectedZone != null) {
            _controllers[_selectedZone!].collapse();
          }
          _selectedZone = zoneIdx;
          widget.onZoneSelected?.call(zoneIdx);
        } else {
          if (zoneIdx == _selectedZone) {
            _selectedZone = null;
            widget.onZoneSelected?.call(null);
          }
        }
      },
      title: Row(
        children: [
          RenamableTitle(
            title: zones[zoneIdx].name,
            onRename: (value) {
              widget.undoStack.add(Change(
                zones[zoneIdx].name,
                () {
                  zones[zoneIdx].name = value;
                  widget.onPathChangedNoSim?.call();
                },
                (oldValue) {
                  zones[zoneIdx].name = oldValue;
                  widget.onPathChangedNoSim?.call();
                },
              ));
            },
          ),
          if (linkedName != null && linkedName.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              'Target: $linkedName',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.primary,
                fontSize: 13,
              ),
            ),
          ],
          Expanded(child: Container()),
          Visibility(
            visible: _selectedZone == null,
            child: Tooltip(
              message: 'Move Zone Up',
              waitDuration: const Duration(seconds: 1),
              child: IconButton(
                icon: const Icon(Icons.expand_less),
                color: colorScheme.onSurface,
                onPressed: zoneIdx == 0
                    ? null
                    : () {
                        var temp = zones[zoneIdx - 1];
                        zones[zoneIdx - 1] = zones[zoneIdx];
                        zones[zoneIdx] = temp;

                        var tempController = _controllers[zoneIdx - 1];
                        _controllers[zoneIdx - 1] = _controllers[zoneIdx];
                        _controllers[zoneIdx] = tempController;

                        widget.onPathChanged?.call();
                      },
              ),
            ),
          ),
          Visibility(
            visible: _selectedZone == null,
            child: Tooltip(
              message: 'Move Zone Down',
              waitDuration: const Duration(seconds: 1),
              child: IconButton(
                icon: const Icon(Icons.expand_more),
                color: colorScheme.onSurface,
                onPressed: zoneIdx == zones.length - 1
                    ? null
                    : () {
                        var temp = zones[zoneIdx + 1];
                        zones[zoneIdx + 1] = zones[zoneIdx];
                        zones[zoneIdx] = temp;

                        var tempController = _controllers[zoneIdx + 1];
                        _controllers[zoneIdx + 1] = _controllers[zoneIdx];
                        _controllers[zoneIdx] = tempController;

                        widget.onPathChanged?.call();
                      },
              ),
            ),
          ),
          Tooltip(
            message: 'Delete Zone',
            waitDuration: const Duration(seconds: 1),
            child: IconButton(
              icon: const Icon(Icons.delete_forever),
              color: colorScheme.error,
              onPressed: () {
                widget.undoStack.add(Change(
                  PathPlannerPath.clonePointTowardsZones(zones),
                  () {
                    zones.removeAt(zoneIdx);
                    widget.onZoneSelected?.call(null);
                    widget.onZoneHovered?.call(null);
                    widget.onPathChanged?.call();
                  },
                  (oldValue) {
                    widget.path.pointTowardsZones =
                        PathPlannerPath.clonePointTowardsZones(oldValue);
                    widget.onZoneSelected?.call(null);
                    widget.onZoneHovered?.call(null);
                    widget.onPathChanged?.call();
                  },
                ));
              },
            ),
          ),
        ],
      ),
      initiallyExpanded: zoneIdx == _selectedZone,
      elevation: 4.0,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6.0),
          child: Row(
            children: [
              Expanded(
                child: NumberTextField(
                  initialValue: zones[zoneIdx].targetPosition.x,
                  label: 'Field Position X (M)',
                  onSubmitted: (value) {
                    if (value != null) {
                      _addChange(
                          zoneIdx,
                          () => _setPointTargetPosition(
                              zoneIdx,
                              Translation2d(
                                  value, zones[zoneIdx].targetPosition.y)));
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: NumberTextField(
                  initialValue: zones[zoneIdx].targetPosition.y,
                  label: 'Field Position Y (M)',
                  onSubmitted: (value) {
                    if (value != null) {
                      _addChange(
                          zoneIdx,
                          () => _setPointTargetPosition(
                              zoneIdx,
                              Translation2d(
                                  zones[zoneIdx].targetPosition.x, value)));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildLinkedTargetControls(zoneIdx),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6.0),
          child: Row(
            children: [
              Expanded(
                child: NumberTextField(
                  initialValue: zones[zoneIdx].rotationOffset.degrees,
                  label: 'Rotation Offset (Deg)',
                  onSubmitted: (value) {
                    if (value != null) {
                      _addChange(
                          zoneIdx,
                          () => zones[zoneIdx].rotationOffset =
                              Rotation2d.fromDegrees(
                                  MathUtil.inputModulus(value, -180, 180)));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: zones[zoneIdx].minWaypointRelativePos.toDouble(),
                secondaryTrackValue:
                    zones[zoneIdx].maxWaypointRelativePos.toDouble(),
                min: 0.0,
                max: waypoints.length - 1.0,
                label: zones[zoneIdx].minWaypointRelativePos.toStringAsFixed(2),
                onChangeStart: (value) {
                  _sliderChangeStart = value;
                },
                onChangeEnd: (value) {
                  widget.undoStack.add(Change(
                    _sliderChangeStart,
                    () {
                      zones[zoneIdx].minWaypointRelativePos = value;
                      widget.onPathChanged?.call();
                    },
                    (oldValue) {
                      zones[zoneIdx].minWaypointRelativePos = oldValue;
                      widget.onPathChanged?.call();
                    },
                  ));
                },
                onChanged: (value) {
                  if (value <= zones[zoneIdx].maxWaypointRelativePos) {
                    zones[zoneIdx].minWaypointRelativePos = value;
                    widget.onPathChangedNoSim?.call();
                  }
                },
              ),
            ),
            SizedBox(
              width: 75,
              child: NumberTextField(
                initialValue: zones[zoneIdx].minWaypointRelativePos,
                precision: 2,
                label: 'Start Pos',
                onSubmitted: (value) {
                  if (value != null) {
                    final maxVal = zones[zoneIdx].maxWaypointRelativePos;
                    final val = MathUtil.clamp(value, 0.0, maxVal);
                    widget.undoStack.add(Change(
                      zones[zoneIdx].minWaypointRelativePos,
                      () {
                        zones[zoneIdx].minWaypointRelativePos = val;
                        widget.onPathChanged?.call();
                      },
                      (oldValue) {
                        zones[zoneIdx].minWaypointRelativePos = oldValue;
                        widget.onPathChanged?.call();
                      },
                    ));
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: zones[zoneIdx].maxWaypointRelativePos.toDouble(),
                min: 0.0,
                max: waypoints.length - 1.0,
                label: zones[zoneIdx].maxWaypointRelativePos.toStringAsFixed(2),
                onChangeStart: (value) {
                  _sliderChangeStart = value;
                },
                onChangeEnd: (value) {
                  widget.undoStack.add(Change(
                    _sliderChangeStart,
                    () {
                      zones[zoneIdx].maxWaypointRelativePos = value;
                      widget.onPathChanged?.call();
                    },
                    (oldValue) {
                      zones[zoneIdx].maxWaypointRelativePos = oldValue;
                      widget.onPathChanged?.call();
                    },
                  ));
                },
                onChanged: (value) {
                  if (value >= zones[zoneIdx].minWaypointRelativePos) {
                    zones[zoneIdx].maxWaypointRelativePos = value;
                    widget.onPathChangedNoSim?.call();
                  }
                },
              ),
            ),
            SizedBox(
              width: 75,
              child: NumberTextField(
                initialValue: zones[zoneIdx].maxWaypointRelativePos,
                precision: 2,
                label: 'End Pos',
                onSubmitted: (value) {
                  if (value != null) {
                    final minVal = zones[zoneIdx].minWaypointRelativePos;
                    final val =
                        MathUtil.clamp(value, minVal, waypoints.length - 1.0);
                    widget.undoStack.add(Change(
                      zones[zoneIdx].maxWaypointRelativePos,
                      () {
                        zones[zoneIdx].maxWaypointRelativePos = val;
                        widget.onPathChanged?.call();
                      },
                      (oldValue) {
                        zones[zoneIdx].maxWaypointRelativePos = oldValue;
                        widget.onPathChanged?.call();
                      },
                    ));
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ],
    );
  }

  String _waypointLabel(int waypointIdx) {
    final waypoint = waypoints[waypointIdx];
    final linkedName = waypoint.linkedName?.trim();

    if (linkedName != null && linkedName.isNotEmpty) {
      if (waypoint.isStartPoint) {
        return '(Start) $linkedName';
      }

      if (waypoint.isEndPoint) {
        return '(End) $linkedName';
      }

      return linkedName;
    }

    if (waypoint.isStartPoint) {
      return 'Start Point';
    }

    if (waypoint.isEndPoint) {
      return 'End Point';
    }

    return 'Waypoint $waypointIdx';
  }

  Widget _buildLinkedTargetControls(int zoneIdx) {
    final linkedName = zones[zoneIdx].linkedName?.trim();

    return Center(
      child: Wrap(
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          IconButton(
            onPressed: () => _showLinkedTargetDialog(zoneIdx),
            icon: Icon(
              linkedName == null || linkedName.isEmpty
                  ? Icons.add_link_rounded
                  : Icons.link_rounded,
              size: 20,
            ),
          ),
          if (linkedName != null && linkedName.isNotEmpty)
            IconButton(
              onPressed: () => _unlinkPointTarget(zoneIdx),
              icon: const Icon(Icons.link_off_rounded, size: 20),
            ),
          _buildSetTargetFromWaypointButton(zoneIdx),
        ],
      ),
    );
  }

  Widget _buildSetTargetFromWaypointButton(int zoneIdx) {
    if (waypoints.isEmpty) {
      return const SizedBox.shrink();
    }

    return PopupMenuButton<int>(
      icon: const Icon(Icons.location_on_rounded, size: 20),
      onSelected: (waypointIdx) =>
          _setPointTargetFromWaypoint(zoneIdx, waypointIdx),
      itemBuilder: (context) {
        return [
          for (int i = 0; i < waypoints.length; i++)
            PopupMenuItem(
              value: i,
              child: Text('Set from ${_waypointLabel(i)}'),
            ),
        ];
      },
    );
  }

  void _syncLinkedTarget(String linkedName, Translation2d position) {
    PointTowardsZone.linkedTargets[linkedName] = position;

    for (final zone in zones) {
      if (zone.linkedName == linkedName) {
        zone.fieldPosition = position;
      }
    }
  }

  Future<void> _showLinkedTargetDialog(int zoneIdx) async {
    final controller = TextEditingController(
      text: zones[zoneIdx].linkedName?.trim().isNotEmpty == true
          ? zones[zoneIdx].linkedName!.trim()
          : zones[zoneIdx].name,
    );

    try {
      final linkedName = await showDialog<String>(
        context: context,
        builder: (context) {
          ColorScheme colorScheme = Theme.of(context).colorScheme;

          return AlertDialog(
            backgroundColor: colorScheme.surface,
            surfaceTintColor: colorScheme.surfaceTint,
            title: const Text('Link Point Towards Target'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Convert this point-towards target to a linked target. Moving one target with this name updates all point-towards zones using the same linked target.',
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'If you choose an existing linked point-towards target, this zone will snap to that target position.',
                  ),
                  const SizedBox(height: 18),
                  DropdownMenu<String>(
                    label: const Text('Linked Target Name'),
                    controller: controller,
                    enableSearch: false,
                    enableFilter: true,
                    width: 400,
                    dropdownMenuEntries: [
                      for (String name in PointTowardsZone.linkedTargets.keys)
                        DropdownMenuEntry(
                          value: name,
                          label: name,
                        ),
                    ],
                    inputDecorationTheme: InputDecorationTheme(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                      isDense: true,
                      constraints: const BoxConstraints(
                        maxHeight: 42,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: Navigator.of(context).pop,
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(controller.text.trim());
                },
                child: const Text('Confirm'),
              ),
            ],
          );
        },
      );

      if (linkedName == null || linkedName.trim().isEmpty) {
        return;
      }

      final cleanedName = linkedName.trim();
      _addZoneListChange(() {
        zones[zoneIdx].setLinkedName(cleanedName);
        _syncLinkedTarget(cleanedName, zones[zoneIdx].targetPosition);
      });
    } finally {
      controller.dispose();
    }
  }

  void _unlinkPointTarget(int zoneIdx) {
    _addZoneListChange(() {
      zones[zoneIdx].linkedName = null;
    });
  }

  void _setPointTargetFromWaypoint(int zoneIdx, int waypointIdx) {
    if (waypointIdx < 0 || waypointIdx >= waypoints.length) {
      return;
    }

    final target = waypoints[waypointIdx].anchor;

    _addZoneListChange(() {
      zones[zoneIdx].setTargetPosition(target);

      final linkedName = zones[zoneIdx].linkedName;
      if (linkedName != null && linkedName.trim().isNotEmpty) {
        _syncLinkedTarget(linkedName.trim(), target);
      }
    });
  }

  void _setPointTargetPosition(int zoneIdx, Translation2d target) {
    _addZoneListChange(() {
      zones[zoneIdx].setTargetPosition(target);

      final linkedName = zones[zoneIdx].linkedName;
      if (linkedName != null && linkedName.trim().isNotEmpty) {
        _syncLinkedTarget(linkedName.trim(), target);
      }
    });
  }

  void _addZoneListChange(VoidCallback execute) {
    widget.undoStack.add(Change(
      PathPlannerPath.clonePointTowardsZones(zones),
      () {
        execute.call();
        widget.onPathChanged?.call();
      },
      (oldValue) {
        widget.path.pointTowardsZones =
            PathPlannerPath.clonePointTowardsZones(oldValue);
        widget.onPathChanged?.call();
      },
    ));
  }

  void _addChange(int zoneIdx, VoidCallback execute) {
    widget.undoStack.add(Change(
      zones[zoneIdx].clone(),
      () {
        execute.call();
        widget.onPathChanged?.call();
      },
      (oldValue) {
        zones[zoneIdx] = oldValue.clone();
        widget.onPathChanged?.call();
      },
    ));
  }
}
