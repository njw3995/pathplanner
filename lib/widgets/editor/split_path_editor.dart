import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:pathplanner/pages/project/project_page.dart';
import 'package:pathplanner/commands/wait_command.dart';
import 'package:pathplanner/commands/path_command.dart';
import 'package:pathplanner/commands/named_command.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/path/ideal_starting_state.dart';
import 'package:pathplanner/path/goal_end_state.dart';
import 'package:path/path.dart' as p;
import 'package:pathplanner/path/constraints_zone.dart';
import 'package:pathplanner/path/event_marker.dart';
import 'package:pathplanner/path/path_constraints.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/point_towards_zone.dart';
import 'package:pathplanner/path/rotation_target.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/services/log.dart';
import 'package:pathplanner/services/pplib_telemetry.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/trajectory/trajectory.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/widgets/dialogs/trajectory_render_dialog.dart';
import 'package:pathplanner/widgets/editor/path_painter.dart';
import 'package:pathplanner/widgets/editor/preview_seekbar.dart';
import 'package:pathplanner/widgets/editor/runtime_display.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/path_tree.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/waypoints_tree.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/util/path_painter_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class SplitPathEditor extends StatefulWidget {
  final SharedPreferences prefs;
  final PathPlannerPath path;
  final FieldImage fieldImage;
  final ChangeStack undoStack;
  final PPLibTelemetry? telemetry;
  final bool hotReload;
  final bool simulate;
  final VoidCallback? onPathChanged;

  const SplitPathEditor({
    required this.prefs,
    required this.path,
    required this.fieldImage,
    required this.undoStack,
    this.telemetry,
    this.hotReload = false,
    this.simulate = false,
    this.onPathChanged,
    super.key,
  });

  @override
  State<SplitPathEditor> createState() => _SplitPathEditorState();
}

class _SplitPathEditorState extends State<SplitPathEditor>
    with SingleTickerProviderStateMixin {
  final MultiSplitViewController _controller = MultiSplitViewController();
  final WaypointsTreeController _waypointsTreeController =
      WaypointsTreeController();
  int? _hoveredWaypoint;
  int? _selectedWaypoint;
  int? _hoveredZone;
  int? _selectedZone;
  int? _hoveredRotTarget;
  int? _selectedRotTarget;
  int? _hoveredPointZone;
  int? _selectedPointZone;
  int? _hoveredMarker;
  int? _selectedMarker;
  late bool _treeOnRight;
  Waypoint? _draggedPoint;
  Waypoint? _dragOldValue;
  int? _draggedRotationIdx;
  Translation2d? _draggedRotationPos;
  Rotation2d? _dragRotationOldValue;
  int? _draggedPointTargetZoneIdx;
  Translation2d? _dragPointTargetOldValue;
  PathPlannerTrajectory? _simTraj;
  bool _paused = false;
  late bool _holonomicMode;

  PathPlannerPath? _optimizedPath;

  late Size _robotSize;
  late Translation2d _bumperOffset;
  late AnimationController _previewController;

  List<Waypoint> get waypoints => widget.path.waypoints;

  RuntimeDisplay? _runtimeDisplay;

  @override
  void initState() {
    super.initState();

    _previewController = AnimationController(vsync: this);

    _holonomicMode =
        widget.prefs.getBool(PrefsKeys.holonomicMode) ?? Defaults.holonomicMode;

    _treeOnRight =
        widget.prefs.getBool(PrefsKeys.treeOnRight) ?? Defaults.treeOnRight;

    var width =
        widget.prefs.getDouble(PrefsKeys.robotWidth) ?? Defaults.robotWidth;
    var length =
        widget.prefs.getDouble(PrefsKeys.robotLength) ?? Defaults.robotLength;
    _robotSize = Size(width, length);
    _bumperOffset = Translation2d(
        widget.prefs.getDouble(PrefsKeys.bumperOffsetX) ??
            Defaults.bumperOffsetX,
        widget.prefs.getDouble(PrefsKeys.bumperOffsetY) ??
            Defaults.bumperOffsetY);

    double treeWeight = widget.prefs.getDouble(PrefsKeys.editorTreeWeight) ??
        Defaults.editorTreeWeight;
    _controller.areas = [
      Area(
        weight: _treeOnRight ? (1.0 - treeWeight) : treeWeight,
        minimalWeight: 0.4,
      ),
      Area(
        weight: _treeOnRight ? treeWeight : (1.0 - treeWeight),
        minimalWeight: 0.4,
      ),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) => _simulatePath());
  }

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Center(
          child: InteractiveViewer(
            maxScale: 10.0,
            child: GestureDetector(
              onTapDown: (details) {
                FocusScopeNode currentScope = FocusScope.of(context);
                if (!currentScope.hasPrimaryFocus && currentScope.hasFocus) {
                  FocusManager.instance.primaryFocus!.unfocus();
                }
                for (int i = waypoints.length - 1; i >= 0; i--) {
                  Waypoint w = waypoints[i];
                  if (w.isPointInAnchor(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy),
                          _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                              25, PathPainter.scale, widget.fieldImage))) ||
                      w.isPointInNextControl(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy),
                          _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                              20, PathPainter.scale, widget.fieldImage))) ||
                      w.isPointInPrevControl(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy),
                          _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                              20, PathPainter.scale, widget.fieldImage)))) {
                    _setSelectedWaypoint(i);
                    return;
                  }
                }
                _setSelectedWaypoint(null);
              },
              onDoubleTapDown: (details) {
                widget.undoStack.add(Change(
                  PathPlannerPath.cloneWaypoints(waypoints),
                  () {
                    setState(() {
                      widget.path.addWaypoint(Translation2d(
                          _xPixelsToMeters(details.localPosition.dx),
                          _yPixelsToMeters(details.localPosition.dy)));
                      widget.path.generateAndSavePath();
                    });
                    _simulatePath();
                  },
                  (oldValue) {
                    setState(() {
                      widget.path.waypoints =
                          PathPlannerPath.cloneWaypoints(oldValue);
                      _setSelectedWaypoint(null);
                      widget.path.generateAndSavePath();
                      _simulatePath();
                    });
                  },
                ));
              },
              onPanStart: (details) {
                double xPos = _xPixelsToMeters(details.localPosition.dx);
                double yPos = _yPixelsToMeters(details.localPosition.dy);

                for (int i = waypoints.length - 1; i >= 0; i--) {
                  Waypoint w = waypoints[i];
                  if (w.startDragging(
                      xPos,
                      yPos,
                      _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                          25, PathPainter.scale, widget.fieldImage)),
                      _pixelsToMeters(PathPainterUtil.uiPointSizeToPixels(
                          20, PathPainter.scale, widget.fieldImage)))) {
                    _draggedPoint = w;
                    _dragOldValue = w.clone();
                    break;
                  }
                }

                // Not dragging any waypoints, check point-towards targets
                num pointTargetRadius = _pixelsToMeters(
                    PathPainterUtil.uiPointSizeToPixels(
                        18, PathPainter.scale, widget.fieldImage));

                for (int i = widget.path.pointTowardsZones.length - 1;
                    i >= 0;
                    i--) {
                  final zone = widget.path.pointTowardsZones[i];
                  final target = zone.targetPosition;

                  if (pow(xPos - target.x, 2) + pow(yPos - target.y, 2) <
                      pow(pointTargetRadius, 2)) {
                    _draggedPointTargetZoneIdx = i;
                    _dragPointTargetOldValue = target;
                    _setSelectedWaypoint(null);
                    _selectedPointZone = i;
                    return;
                  }
                }

                // Not dragging any waypoints, check rotations
                num dotRadius = _pixelsToMeters(
                    PathPainterUtil.uiPointSizeToPixels(
                        15, PathPainter.scale, widget.fieldImage));
                for (int i = 0; i < widget.path.pathPoints.length; i++) {
                  Rotation2d rotation;
                  Translation2d pos;
                  if (i == 0) {
                    rotation = widget.path.idealStartingState.rotation;
                    pos = widget.path.pathPoints.first.position;
                  } else if (i == widget.path.pathPoints.length - 1) {
                    rotation = widget.path.goalEndState.rotation;
                    pos = widget.path.pathPoints.last.position;
                  } else if (widget.path.pathPoints[i].rotationTarget != null) {
                    rotation =
                        widget.path.pathPoints[i].rotationTarget!.rotation;
                    pos = widget.path.pathPoints[i].position;
                  } else {
                    continue;
                  }

                  num dotX = pos.x +
                      (((_robotSize.height / 2) + _bumperOffset.x) *
                          rotation.cosine);
                  num dotY = pos.y +
                      (((_robotSize.height / 2) + _bumperOffset.x) *
                          rotation.sine);
                  if (pow(xPos - dotX, 2) + pow(yPos - dotY, 2) <
                      pow(dotRadius, 2)) {
                    if (i == 0) {
                      _draggedRotationIdx = -2;
                    } else if (i == widget.path.pathPoints.length - 2) {
                      _draggedRotationIdx = -1;
                    } else {
                      _draggedRotationIdx = widget.path.rotationTargets
                          .indexOf(widget.path.pathPoints[i].rotationTarget!);
                    }
                    _draggedRotationPos = pos;
                    _dragRotationOldValue = rotation;
                    return;
                  }
                }
              },
              onPanUpdate: (details) {
                if (_draggedPoint != null) {
                  num targetX = _xPixelsToMeters(min(
                      88 +
                          (widget.fieldImage.defaultSize.width *
                              PathPainter.scale),
                      max(8, details.localPosition.dx)));
                  num targetY = _yPixelsToMeters(min(
                      88 +
                          (widget.fieldImage.defaultSize.height *
                              PathPainter.scale),
                      max(8, details.localPosition.dy)));

                  bool snapSetting =
                      widget.prefs.getBool(PrefsKeys.snapToGuidelines) ??
                          Defaults.snapToGuidelines;
                  bool ctrlHeld = HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.controlLeft) ||
                      HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.controlRight);

                  bool shouldSnap = snapSetting ^ ctrlHeld;

                  if (shouldSnap && _draggedPoint!.isAnchorDragging) {
                    num? closestX;
                    num? closestY;

                    for (Waypoint w in waypoints) {
                      if (w != _draggedPoint) {
                        if (closestX == null ||
                            (targetX - w.anchor.x).abs() <
                                (targetX - closestX).abs()) {
                          closestX = w.anchor.x;
                        }

                        if (closestY == null ||
                            (targetY - w.anchor.y).abs() <
                                (targetY - closestY).abs()) {
                          closestY = w.anchor.y;
                        }
                      }
                    }

                    if (closestX != null && (targetX - closestX).abs() < 0.1) {
                      targetX = closestX;
                    }
                    if (closestY != null && (targetY - closestY).abs() < 0.1) {
                      targetY = closestY;
                    }
                  }

                  setState(() {
                    _draggedPoint!.dragUpdate(targetX, targetY);
                    widget.path.generatePathPoints();
                  });
                } else if (_draggedPointTargetZoneIdx != null) {
                  final zone = widget
                      .path.pointTowardsZones[_draggedPointTargetZoneIdx!];

                  final targetPosition = Translation2d(
                    _xPixelsToMeters(details.localPosition.dx),
                    _yPixelsToMeters(details.localPosition.dy),
                  );

                  setState(() {
                    zone.setTargetPosition(targetPosition);

                    final linkedName = zone.linkedName;
                    if (linkedName != null && linkedName.trim().isNotEmpty) {
                      _syncCurrentPathPointTargetLink(
                        linkedName.trim(),
                        targetPosition,
                      );
                    }

                    widget.path.generatePathPoints();
                  });
                } else if (_draggedRotationIdx != null) {
                  Translation2d pos;
                  if (_draggedRotationIdx == -2) {
                    pos = widget.path.waypoints.first.anchor;
                  } else if (_draggedRotationIdx == -1) {
                    pos = widget.path.waypoints.last.anchor;
                  } else {
                    pos = _draggedRotationPos!;
                  }

                  double x = _xPixelsToMeters(details.localPosition.dx);
                  double y = _yPixelsToMeters(details.localPosition.dy);

                  setState(() {
                    if (_draggedRotationIdx == -2) {
                      widget.path.idealStartingState.rotation =
                          Rotation2d.fromComponents(x - pos.x, y - pos.y);
                    } else if (_draggedRotationIdx == -1) {
                      widget.path.goalEndState.rotation =
                          Rotation2d.fromComponents(x - pos.x, y - pos.y);
                    } else {
                      widget.path.rotationTargets[_draggedRotationIdx!]
                              .rotation =
                          Rotation2d.fromComponents(x - pos.x, y - pos.y);
                    }
                  });
                }
              },
              onPanEnd: (details) {
                if (_draggedPoint != null) {
                  _draggedPoint!.stopDragging();
                  int index = waypoints.indexOf(_draggedPoint!);
                  Waypoint dragEnd = _draggedPoint!.clone();
                  widget.undoStack.add(Change(
                    _dragOldValue,
                    () {
                      setState(() {
                        if (waypoints[index] != _draggedPoint) {
                          waypoints[index] = dragEnd.clone();
                        }
                        widget.path.generateAndSavePath();
                        _simulatePath();
                        widget.onPathChanged?.call();
                      });
                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }
                    },
                    (oldValue) {
                      setState(() {
                        waypoints[index] = oldValue!.clone();
                        widget.path.generateAndSavePath();
                        _simulatePath();
                        widget.onPathChanged?.call();
                      });
                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }
                    },
                  ));
                  _draggedPoint = null;
                } else if (_draggedPointTargetZoneIdx != null) {
                  final zoneIdx = _draggedPointTargetZoneIdx!;
                  final endPosition =
                      widget.path.pointTowardsZones[zoneIdx].targetPosition;

                  widget.undoStack.add(Change(
                    _dragPointTargetOldValue,
                    () {
                      setState(() {
                        final zone = widget.path.pointTowardsZones[zoneIdx];
                        zone.setTargetPosition(endPosition);

                        final linkedName = zone.linkedName;
                        if (linkedName != null &&
                            linkedName.trim().isNotEmpty) {
                          _syncCurrentPathPointTargetLink(
                            linkedName.trim(),
                            endPosition,
                          );
                        }

                        widget.path.generateAndSavePath();
                        _simulatePath();
                        widget.onPathChanged?.call();
                      });

                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }
                    },
                    (oldValue) {
                      setState(() {
                        final zone = widget.path.pointTowardsZones[zoneIdx];
                        zone.setTargetPosition(oldValue!);

                        final linkedName = zone.linkedName;
                        if (linkedName != null &&
                            linkedName.trim().isNotEmpty) {
                          _syncCurrentPathPointTargetLink(
                            linkedName.trim(),
                            oldValue,
                          );
                        }

                        widget.path.generateAndSavePath();
                        _simulatePath();
                        widget.onPathChanged?.call();
                      });

                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }
                    },
                  ));

                  _draggedPointTargetZoneIdx = null;
                  _dragPointTargetOldValue = null;
                } else if (_draggedRotationIdx != null) {
                  if (_draggedRotationIdx == -2) {
                    final endRotation = widget.path.idealStartingState.rotation;
                    widget.undoStack.add(Change(
                      _dragRotationOldValue,
                      () {
                        setState(() {
                          widget.path.idealStartingState.rotation = endRotation;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                      (oldValue) {
                        setState(() {
                          widget.path.idealStartingState.rotation = oldValue!;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                    ));
                  } else if (_draggedRotationIdx == -1) {
                    final endRotation = widget.path.goalEndState.rotation;
                    widget.undoStack.add(Change(
                      _dragRotationOldValue,
                      () {
                        setState(() {
                          widget.path.goalEndState.rotation = endRotation;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                      (oldValue) {
                        setState(() {
                          widget.path.goalEndState.rotation = oldValue!;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                    ));
                  } else {
                    int rotationIdx = _draggedRotationIdx!;
                    final endRotation =
                        widget.path.rotationTargets[rotationIdx].rotation;
                    widget.undoStack.add(Change(
                      _dragRotationOldValue,
                      () {
                        setState(() {
                          widget.path.rotationTargets[rotationIdx].rotation =
                              endRotation;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                      (oldValue) {
                        setState(() {
                          widget.path.rotationTargets[rotationIdx].rotation =
                              oldValue!;
                          widget.path.generateAndSavePath();
                          _simulatePath();
                          widget.onPathChanged?.call();
                        });
                      },
                    ));
                  }
                  _draggedRotationIdx = null;
                  _draggedRotationPos = null;
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Stack(
                  children: [
                    widget.fieldImage.getWidget(),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: PathPainter(
                          colorScheme: colorScheme,
                          paths: [widget.path],
                          simple: false,
                          fieldImage: widget.fieldImage,
                          hoveredWaypoint: _hoveredWaypoint,
                          selectedWaypoint: _selectedWaypoint,
                          hoveredZone: _hoveredZone,
                          selectedZone: _selectedZone,
                          hoveredPointZone: _hoveredPointZone,
                          selectedPointZone: _selectedPointZone,
                          hoveredRotTarget: _hoveredRotTarget,
                          selectedRotTarget: _selectedRotTarget,
                          hoveredMarker: _hoveredMarker,
                          selectedMarker: _selectedMarker,
                          simulatedPath: _simTraj,
                          animation: _previewController.view,
                          prefs: widget.prefs,
                          optimizedPath: _optimizedPath,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        MultiSplitViewTheme(
          data: MultiSplitViewThemeData(
            dividerPainter: DividerPainters.grooved1(
              color: colorScheme.surfaceContainerHighest,
              highlightedColor: colorScheme.primary,
            ),
          ),
          child: MultiSplitView(
            axis: Axis.horizontal,
            controller: _controller,
            onWeightChange: () {
              double? newWeight = _treeOnRight
                  ? _controller.areas[1].weight
                  : _controller.areas[0].weight;
              widget.prefs
                  .setDouble(PrefsKeys.editorTreeWeight, newWeight ?? 0.5);
            },
            children: [
              if (_treeOnRight)
                PreviewSeekbar(
                  previewController: _previewController,
                  onPauseStateChanged: (value) => _paused = value,
                  totalPathTime: _simTraj?.states.last.timeSeconds ?? 1.0,
                  simulatedPath: _simTraj,
                ),
              Card(
                margin: const EdgeInsets.all(0),
                elevation: 4.0,
                color: colorScheme.surface,
                surfaceTintColor: colorScheme.surfaceTint,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.only(
                    topLeft:
                        _treeOnRight ? const Radius.circular(12) : Radius.zero,
                    topRight:
                        _treeOnRight ? Radius.zero : const Radius.circular(12),
                    bottomLeft:
                        _treeOnRight ? const Radius.circular(12) : Radius.zero,
                    bottomRight:
                        _treeOnRight ? Radius.zero : const Radius.circular(12),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: PathTree(
                    path: widget.path,
                    pathRuntime: _simTraj?.getTotalTimeSeconds(),
                    runtimeDisplay: _runtimeDisplay,
                    initiallySelectedWaypoint: _selectedWaypoint,
                    initiallySelectedZone: _selectedZone,
                    initiallySelectedRotTarget: _selectedRotTarget,
                    initiallySelectedPointZone: _selectedPointZone,
                    initiallySelectedMarker: _selectedMarker,
                    waypointsTreeController: _waypointsTreeController,
                    undoStack: widget.undoStack,
                    holonomicMode: _holonomicMode,
                    defaultConstraints: _getDefaultConstraints(),
                    prefs: widget.prefs,
                    fieldSizeMeters: widget.fieldImage.getFieldSizeMeters(),
                    onRenderPath: () {
                      if (_simTraj != null) {
                        showDialog(
                            context: context,
                            builder: (context) {
                              return TrajectoryRenderDialog(
                                fieldImage: widget.fieldImage,
                                prefs: widget.prefs,
                                trajectory: _simTraj!,
                              );
                            });
                      }
                    },
                    onPathChanged: () {
                      setState(() {
                        widget.path.generateAndSavePath();
                        _simulatePath();
                      });

                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }

                      widget.onPathChanged?.call();
                    },
                    onPathChangedNoSim: () {
                      setState(() {
                        widget.path.generateAndSavePath();
                      });

                      if (widget.hotReload) {
                        widget.telemetry?.hotReloadPath(widget.path);
                      }

                      widget.onPathChanged?.call();
                    },
                    onWaypointDeleted: (waypointIdx) {
                      widget.undoStack.add(Change(
                        [
                          PathPlannerPath.cloneWaypoints(widget.path.waypoints),
                          PathPlannerPath.cloneConstraintZones(
                              widget.path.constraintZones),
                          PathPlannerPath.cloneEventMarkers(
                              widget.path.eventMarkers),
                          PathPlannerPath.cloneRotationTargets(
                              widget.path.rotationTargets),
                          PathPlannerPath.clonePointTowardsZones(
                              widget.path.pointTowardsZones),
                        ],
                        () {
                          setState(() {
                            _selectedWaypoint = null;
                            _hoveredWaypoint = null;
                            _waypointsTreeController.setSelectedWaypoint(null);

                            Waypoint w =
                                widget.path.waypoints.removeAt(waypointIdx);

                            if (w.isEndPoint) {
                              waypoints[widget.path.waypoints.length - 1]
                                  .nextControl = null;
                            } else if (w.isStartPoint) {
                              waypoints[0].prevControl = null;
                            }

                            for (ConstraintsZone zone
                                in widget.path.constraintZones) {
                              zone.minWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.minWaypointRelativePos, waypointIdx);
                              zone.maxWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.maxWaypointRelativePos, waypointIdx);
                            }

                            for (PointTowardsZone zone
                                in widget.path.pointTowardsZones) {
                              zone.minWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.minWaypointRelativePos, waypointIdx);
                              zone.maxWaypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      zone.maxWaypointRelativePos, waypointIdx);
                            }

                            for (EventMarker m in widget.path.eventMarkers) {
                              m.waypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      m.waypointRelativePos, waypointIdx);
                            }

                            for (RotationTarget t
                                in widget.path.rotationTargets) {
                              t.waypointRelativePos =
                                  _adjustDeletedWaypointRelativePos(
                                      t.waypointRelativePos, waypointIdx);
                            }

                            widget.path.generateAndSavePath();
                            _simulatePath();
                          });
                        },
                        (oldValue) {
                          setState(() {
                            _selectedWaypoint = null;
                            _hoveredWaypoint = null;
                            _waypointsTreeController.setSelectedWaypoint(null);

                            widget.path.waypoints =
                                PathPlannerPath.cloneWaypoints(
                                    oldValue[0] as List<Waypoint>);
                            widget.path.constraintZones =
                                PathPlannerPath.cloneConstraintZones(
                                    oldValue[1] as List<ConstraintsZone>);
                            widget.path.eventMarkers =
                                PathPlannerPath.cloneEventMarkers(
                                    oldValue[2] as List<EventMarker>);
                            widget.path.rotationTargets =
                                PathPlannerPath.cloneRotationTargets(
                                    oldValue[3] as List<RotationTarget>);
                            widget.path.pointTowardsZones =
                                PathPlannerPath.clonePointTowardsZones(
                                    oldValue[4] as List<PointTowardsZone>);
                            widget.path.generateAndSavePath();
                            _simulatePath();
                          });
                        },
                      ));
                    },
                    onSideSwapped: () => setState(() {
                      _treeOnRight = !_treeOnRight;
                      widget.prefs.setBool(PrefsKeys.treeOnRight, _treeOnRight);
                      _controller.areas = _controller.areas.reversed.toList();
                    }),
                    onWaypointHovered: (value) {
                      setState(() {
                        _hoveredWaypoint = value;
                      });
                    },
                    onWaypointSelected: (value) {
                      setState(() {
                        _selectedWaypoint = value;
                      });
                    },
                    onZoneHovered: (value) {
                      setState(() {
                        _hoveredZone = value;
                      });
                    },
                    onZoneSelected: (value) {
                      setState(() {
                        _selectedZone = value;
                      });
                    },
                    onPointZoneHovered: (value) {
                      setState(() {
                        _hoveredPointZone = value;
                      });
                    },
                    onPointZoneSelected: (value) {
                      setState(() {
                        _selectedPointZone = value;
                      });
                    },
                    onRotTargetHovered: (value) {
                      setState(() {
                        _hoveredRotTarget = value;
                      });
                    },
                    onRotTargetSelected: (value) {
                      setState(() {
                        _selectedRotTarget = value;
                      });
                    },
                    onMarkerHovered: (value) {
                      setState(() {
                        _hoveredMarker = value;
                      });
                    },
                    onMarkerSelected: (value) {
                      setState(() {
                        _selectedMarker = value;
                      });
                    },
                    onMarkerSplit: _splitPathAtMarker,
                    onOptimizationUpdate: (result) => setState(() {
                      _optimizedPath = result;
                    }),
                  ),
                ),
              ),
              if (!_treeOnRight)
                PreviewSeekbar(
                  previewController: _previewController,
                  onPauseStateChanged: (value) => _paused = value,
                  totalPathTime: _simTraj?.states.last.timeSeconds ?? 1.0,
                  simulatedPath: _simTraj,
                ),
            ],
          ),
        ),
        Positioned(
          right: 24,
          bottom: 140,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.speed),
                label: const Text('Optimize End'),
                onPressed: _optimizeEndVelocity,
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.sync_alt),
                label: const Text('Sync Vel'),
                onPressed: _syncLinkedVelocities,
              ),
            ],
          ),
        ),
        Positioned(
          right: 24,
          bottom: 84,
          child: FilledButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Sync linked headings'),
            onPressed: _syncLinkedHandoffHeadings,
          ),
        ),
      ],
    );
  }

  void _showSplitPathError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _uniqueSplitPathName(String preferredName,
      {String? allowedExistingName}) {
    var candidate = preferredName.trim();
    if (candidate.isEmpty) {
      candidate = '${widget.path.name} Part 2';
    }

    final baseName = candidate;
    var copyIndex = 2;

    bool existsAndNotAllowed(String name) {
      if (allowedExistingName != null && name == allowedExistingName) {
        return false;
      }

      return widget.path.fs
          .file(p.join(widget.path.pathDir, '$name.path'))
          .existsSync();
    }

    while (existsAndNotAllowed(candidate)) {
      candidate = '$baseName $copyIndex';
      copyIndex++;
    }

    return candidate;
  }

  String _autoDirForCurrentPath() {
    return p.join(p.dirname(widget.path.pathDir), 'autos');
  }

  Translation2d _lerpTranslation(
    Translation2d a,
    Translation2d b,
    num t,
  ) {
    return a + ((b - a) * t);
  }

  num _clampWaypointPos(num value, num maxValue) {
    return min(max(value, 0), maxValue);
  }

  Rotation2d _rotationAtWaypointRelativePos(num waypointRelativePos) {
    if (waypointRelativePos <= 0) {
      return widget.path.idealStartingState.rotation;
    }

    if (waypointRelativePos >= widget.path.waypoints.length - 1) {
      return widget.path.goalEndState.rotation;
    }

    var rotation = widget.path.idealStartingState.rotation;
    final sortedTargets = List<RotationTarget>.from(widget.path.rotationTargets)
      ..sort(
        (a, b) => a.waypointRelativePos.compareTo(b.waypointRelativePos),
      );

    for (final target in sortedTargets) {
      if (target.waypointRelativePos <= waypointRelativePos) {
        rotation = target.rotation;
      } else {
        break;
      }
    }

    return rotation;
  }

  String _commandPreviewName(Command command) {
    if (command is NamedCommand) {
      return command.name == null || command.name!.trim().isEmpty
          ? 'Named Command'
          : 'Named Command: ${command.name}';
    }

    if (command is WaitCommand) {
      return 'Wait: ${command.waitTime}s';
    }

    if (command is PathCommand) {
      return 'Path: ${command.pathName ?? ''}';
    }

    return command.type;
  }

  Future<String?> _promptOptionalSplitNamedCommandName() async {
    final controller = TextEditingController();

    try {
      return showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Stationary Command'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'This marker does not have a command or event name. Add an optional named command to insert between the split paths.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Named command',
                      hintText: 'Leave blank to split without a command',
                    ),
                    autofocus: true,
                    onSubmitted: (value) {
                      Navigator.of(context).pop(value.trim());
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(''),
                child: const Text('No Command'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(controller.text.trim()),
                child: const Text('Use Named Command'),
              ),
            ],
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Future<bool> _confirmSplitPath({
    required String originalName,
    required String part1Name,
    required String part2Name,
    required Command? stationaryCommand,
    required List<String> updatedAutoNames,
  }) async {
    final commandText = stationaryCommand == null
        ? 'No stationary command will be inserted.'
        : 'Stationary command: ${_commandPreviewName(stationaryCommand)}';

    final autoText = updatedAutoNames.isEmpty
        ? 'No autos currently reference "$originalName".'
        : updatedAutoNames.map((name) => '• $name').join('\n');

    final replacementText = stationaryCommand == null
        ? '$originalName\n  -> $part1Name\n  -> $part2Name'
        : '$originalName\n  -> $part1Name\n  -> ${_commandPreviewName(stationaryCommand)}\n  -> $part2Name';

    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Split Path at Event Marker'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: SelectableText(
                    'This will rename and split the current path:\n\n'
                    '$originalName\n'
                    '  -> $part1Name.path\n'
                    '  -> $part2Name.path\n\n'
                    '$commandText\n\n'
                    'Auto replacement:\n'
                    '$replacementText\n\n'
                    'Autos updated:\n'
                    '$autoText',
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Split Path'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<List<PathPlannerAuto>> _loadAutosForSplit() async {
    final autoDir = _autoDirForCurrentPath();
    final autoDirectory = widget.path.fs.directory(autoDir);

    if (!autoDirectory.existsSync()) {
      return [];
    }

    return PathPlannerAuto.loadAllAutosInDir(autoDir, widget.path.fs);
  }

  int _countPathCommandUsages(List<Command> commands, String pathName) {
    var count = 0;

    for (final command in commands) {
      if (command is PathCommand && command.pathName == pathName) {
        count++;
      } else if (command is CommandGroup) {
        count += _countPathCommandUsages(command.commands, pathName);
      }
    }

    return count;
  }

  int _replacePathCommandUsages({
    required List<Command> commands,
    required String oldPathName,
    required String part1Name,
    required String part2Name,
    required Command? stationaryCommand,
  }) {
    var replacements = 0;

    for (var i = 0; i < commands.length; i++) {
      final command = commands[i];

      if (command is PathCommand && command.pathName == oldPathName) {
        final replacement = <Command>[
          PathCommand(pathName: part1Name),
          if (stationaryCommand != null) stationaryCommand.clone(),
          PathCommand(pathName: part2Name),
        ];

        commands.replaceRange(i, i + 1, replacement);
        replacements++;
        i += replacement.length - 1;
      } else if (command is CommandGroup) {
        replacements += _replacePathCommandUsages(
          commands: command.commands,
          oldPathName: oldPathName,
          part1Name: part1Name,
          part2Name: part2Name,
          stationaryCommand: stationaryCommand,
        );
      }
    }

    return replacements;
  }

  Future<void> _splitPathAtMarker(int markerIdx) async {
    if (markerIdx < 0 || markerIdx >= widget.path.eventMarkers.length) {
      _showSplitPathError('Select a valid event marker first.');
      return;
    }

    final splitMarker = widget.path.eventMarkers[markerIdx];

    if (splitMarker.isZoned) {
      _showSplitPathError(
        'Split Path Here currently supports point event markers, not zoned event markers.',
      );
      return;
    }

    final splitPos = splitMarker.waypointRelativePos;
    final maxOriginalPos = widget.path.waypoints.length - 1;

    if (widget.path.waypoints.length < 2 ||
        splitPos <= 0.0 ||
        splitPos >= maxOriginalPos) {
      _showSplitPathError(
        'The marker must be between the first and last waypoint.',
      );
      return;
    }

    Command? stationaryCommand = splitMarker.command?.clone();

    if (stationaryCommand == null && splitMarker.name.trim().isNotEmpty) {
      stationaryCommand = NamedCommand(name: splitMarker.name.trim());
    }

    if (stationaryCommand == null && splitMarker.name.trim().isEmpty) {
      final commandName = await _promptOptionalSplitNamedCommandName();

      if (commandName == null) {
        return;
      }

      if (commandName.trim().isNotEmpty) {
        stationaryCommand = NamedCommand(name: commandName.trim());
        ProjectPage.events.add(commandName.trim());
      }
    }

    final originalName = widget.path.name;
    final part1Name = _uniqueSplitPathName(
      '$originalName Part 1',
      allowedExistingName: originalName,
    );
    final part2Name = _uniqueSplitPathName('$originalName Part 2');

    final autos = await _loadAutosForSplit();
    final updatedAutoNames = <String>[];

    for (final auto in autos) {
      if (_countPathCommandUsages(auto.sequence.commands, originalName) > 0) {
        updatedAutoNames.add(auto.name);
      }
    }

    final confirmed = await _confirmSplitPath(
      originalName: originalName,
      part1Name: part1Name,
      part2Name: part2Name,
      stationaryCommand: stationaryCommand,
      updatedAutoNames: updatedAutoNames,
    );

    if (!confirmed || !mounted) {
      return;
    }

    const splitEpsilon = 1E-6;
    final originalWaypoints =
        PathPlannerPath.cloneWaypoints(widget.path.waypoints);
    final originalGoalEndState = widget.path.goalEndState.clone();

    final splitSegment = splitPos.floor();
    final splitT = splitPos - splitSegment;

    final List<Waypoint> firstWaypoints;
    final List<Waypoint> secondWaypoints;
    int? existingSplitWaypointIdx;

    if (splitT.abs() < splitEpsilon) {
      existingSplitWaypointIdx = splitSegment;
    } else if ((1.0 - splitT).abs() < splitEpsilon) {
      existingSplitWaypointIdx = splitSegment + 1;
    }

    if (existingSplitWaypointIdx != null) {
      if (existingSplitWaypointIdx <= 0 ||
          existingSplitWaypointIdx >= originalWaypoints.length - 1) {
        _showSplitPathError(
          'The marker must be between the first and last waypoint.',
        );
        return;
      }

      firstWaypoints = [
        for (int i = 0; i <= existingSplitWaypointIdx; i++)
          originalWaypoints[i].clone(),
      ];
      firstWaypoints.last.nextControl = null;

      secondWaypoints = [
        for (int i = existingSplitWaypointIdx;
            i < originalWaypoints.length;
            i++)
          originalWaypoints[i].clone(),
      ];
      secondWaypoints.first.prevControl = null;
    } else {
      final before = originalWaypoints[splitSegment];
      final after = originalWaypoints[splitSegment + 1];

      if (before.nextControl == null || after.prevControl == null) {
        _showSplitPathError(
          'Could not split this path because the split segment is missing control points.',
        );
        return;
      }

      final p0 = before.anchor;
      final p1 = before.nextControl!;
      final p2 = after.prevControl!;
      final p3 = after.anchor;

      final p01 = _lerpTranslation(p0, p1, splitT);
      final p12 = _lerpTranslation(p1, p2, splitT);
      final p23 = _lerpTranslation(p2, p3, splitT);
      final p012 = _lerpTranslation(p01, p12, splitT);
      final p123 = _lerpTranslation(p12, p23, splitT);
      final splitAnchor = _lerpTranslation(p012, p123, splitT);

      firstWaypoints = [
        for (int i = 0; i <= splitSegment; i++) originalWaypoints[i].clone(),
        Waypoint(
          anchor: splitAnchor,
          prevControl: p012,
        ),
      ];
      firstWaypoints[firstWaypoints.length - 2].nextControl = p01;

      secondWaypoints = [
        Waypoint(
          anchor: splitAnchor,
          nextControl: p123,
        ),
        for (int i = splitSegment + 1; i < originalWaypoints.length; i++)
          originalWaypoints[i].clone(),
      ];
      secondWaypoints[1].prevControl = p23;
    }

    final firstMaxPos = firstWaypoints.length - 1;
    final secondMaxPos = secondWaypoints.length - 1;

    num mapFirstPos(num pos) {
      if (existingSplitWaypointIdx != null) {
        return _clampWaypointPos(pos, firstMaxPos);
      }

      if (pos <= splitSegment) {
        return _clampWaypointPos(pos, firstMaxPos);
      }

      final remapped =
          splitSegment + ((pos - splitSegment) / max(splitT, splitEpsilon));
      return _clampWaypointPos(remapped, firstMaxPos);
    }

    num mapSecondPos(num pos) {
      if (existingSplitWaypointIdx != null) {
        return _clampWaypointPos(pos - existingSplitWaypointIdx, secondMaxPos);
      }

      if (pos < splitSegment + 1) {
        final remapped = (pos - splitPos) / max(1.0 - splitT, splitEpsilon);
        return _clampWaypointPos(remapped, secondMaxPos);
      }

      return _clampWaypointPos(pos - splitSegment, secondMaxPos);
    }

    final firstRotationTargets = <RotationTarget>[];
    final secondRotationTargets = <RotationTarget>[];

    for (final target in widget.path.rotationTargets) {
      final cloned = target.clone();

      if (target.waypointRelativePos <= splitPos + splitEpsilon) {
        cloned.waypointRelativePos = mapFirstPos(target.waypointRelativePos);
        firstRotationTargets.add(cloned);
      } else {
        cloned.waypointRelativePos = mapSecondPos(target.waypointRelativePos);
        secondRotationTargets.add(cloned);
      }
    }

    final firstEventMarkers = <EventMarker>[];
    final secondEventMarkers = <EventMarker>[];

    for (int i = 0; i < widget.path.eventMarkers.length; i++) {
      if (i == markerIdx) {
        continue;
      }

      final marker = widget.path.eventMarkers[i];

      if (!marker.isZoned) {
        final cloned = marker.clone();

        if (marker.waypointRelativePos <= splitPos + splitEpsilon) {
          cloned.waypointRelativePos = mapFirstPos(marker.waypointRelativePos);
          firstEventMarkers.add(cloned);
        } else {
          cloned.waypointRelativePos = mapSecondPos(marker.waypointRelativePos);
          secondEventMarkers.add(cloned);
        }

        continue;
      }

      final start = marker.waypointRelativePos;
      final end = marker.endWaypointRelativePos!;

      if (end <= splitPos + splitEpsilon) {
        final cloned = marker.clone();
        cloned.waypointRelativePos = mapFirstPos(start);
        cloned.endWaypointRelativePos = mapFirstPos(end);
        firstEventMarkers.add(cloned);
      } else if (start >= splitPos - splitEpsilon) {
        final cloned = marker.clone();
        cloned.waypointRelativePos = mapSecondPos(start);
        cloned.endWaypointRelativePos = mapSecondPos(end);
        secondEventMarkers.add(cloned);
      } else {
        final firstClone = marker.clone();
        firstClone.waypointRelativePos = mapFirstPos(start);
        firstClone.endWaypointRelativePos = firstMaxPos;
        firstEventMarkers.add(firstClone);

        final secondClone = marker.clone();
        secondClone.waypointRelativePos = 0.0;
        secondClone.endWaypointRelativePos = mapSecondPos(end);
        secondEventMarkers.add(secondClone);
      }
    }

    final firstConstraintZones = <ConstraintsZone>[];
    final secondConstraintZones = <ConstraintsZone>[];

    for (final zone in widget.path.constraintZones) {
      final start = zone.minWaypointRelativePos;
      final end = zone.maxWaypointRelativePos;

      if (end <= splitPos + splitEpsilon) {
        final cloned = zone.clone();
        cloned.minWaypointRelativePos = mapFirstPos(start);
        cloned.maxWaypointRelativePos = mapFirstPos(end);
        firstConstraintZones.add(cloned);
      } else if (start >= splitPos - splitEpsilon) {
        final cloned = zone.clone();
        cloned.minWaypointRelativePos = mapSecondPos(start);
        cloned.maxWaypointRelativePos = mapSecondPos(end);
        secondConstraintZones.add(cloned);
      } else {
        final firstClone = zone.clone();
        firstClone.minWaypointRelativePos = mapFirstPos(start);
        firstClone.maxWaypointRelativePos = firstMaxPos;
        firstConstraintZones.add(firstClone);

        final secondClone = zone.clone();
        secondClone.minWaypointRelativePos = 0.0;
        secondClone.maxWaypointRelativePos = mapSecondPos(end);
        secondConstraintZones.add(secondClone);
      }
    }

    final firstPointZones = <PointTowardsZone>[];
    final secondPointZones = <PointTowardsZone>[];

    for (final zone in widget.path.pointTowardsZones) {
      final start = zone.minWaypointRelativePos;
      final end = zone.maxWaypointRelativePos;

      if (end <= splitPos + splitEpsilon) {
        final cloned = zone.clone();
        cloned.minWaypointRelativePos = mapFirstPos(start);
        cloned.maxWaypointRelativePos = mapFirstPos(end);
        firstPointZones.add(cloned);
      } else if (start >= splitPos - splitEpsilon) {
        final cloned = zone.clone();
        cloned.minWaypointRelativePos = mapSecondPos(start);
        cloned.maxWaypointRelativePos = mapSecondPos(end);
        secondPointZones.add(cloned);
      } else {
        final firstClone = zone.clone();
        firstClone.minWaypointRelativePos = mapFirstPos(start);
        firstClone.maxWaypointRelativePos = firstMaxPos;
        firstPointZones.add(firstClone);

        final secondClone = zone.clone();
        secondClone.minWaypointRelativePos = 0.0;
        secondClone.maxWaypointRelativePos = mapSecondPos(end);
        secondPointZones.add(secondClone);
      }
    }

    final splitRotation = _rotationAtWaypointRelativePos(splitPos);

    final secondPath = PathPlannerPath(
      name: part2Name,
      waypoints: secondWaypoints,
      globalConstraints: widget.path.globalConstraints.clone(),
      goalEndState: originalGoalEndState,
      constraintZones: secondConstraintZones,
      pointTowardsZones: secondPointZones,
      rotationTargets: secondRotationTargets,
      eventMarkers: secondEventMarkers,
      pathDir: widget.path.pathDir,
      fs: widget.path.fs,
      reversed: widget.path.reversed,
      folder: widget.path.folder,
      idealStartingState: IdealStartingState(0, splitRotation),
      useDefaultConstraints: widget.path.useDefaultConstraints,
    );

    setState(() {
      widget.path.renamePath(part1Name);
      widget.path.waypoints = firstWaypoints;
      widget.path.goalEndState = GoalEndState(0, splitRotation);
      widget.path.constraintZones = firstConstraintZones;
      widget.path.pointTowardsZones = firstPointZones;
      widget.path.rotationTargets = firstRotationTargets;
      widget.path.eventMarkers = firstEventMarkers;

      _selectedWaypoint = null;
      _hoveredWaypoint = null;
      _selectedMarker = null;
      _hoveredMarker = null;
      _selectedRotTarget = null;
      _hoveredRotTarget = null;
      _selectedZone = null;
      _hoveredZone = null;
      _selectedPointZone = null;
      _hoveredPointZone = null;

      widget.path.generateAndSavePath();
      secondPath.generateAndSavePath();
      _simulatePath();
    });

    final savedAutos = <String>[];

    for (final auto in autos) {
      final replacements = _replacePathCommandUsages(
        commands: auto.sequence.commands,
        oldPathName: originalName,
        part1Name: part1Name,
        part2Name: part2Name,
        stationaryCommand: stationaryCommand,
      );

      if (replacements > 0) {
        auto.saveFile();
        savedAutos.add(auto.name);
      }
    }

    if (widget.hotReload) {
      widget.telemetry?.hotReloadPath(widget.path);
      widget.telemetry?.hotReloadPath(secondPath);
    }

    widget.onPathChanged?.call();

    final autoMessage = savedAutos.isEmpty
        ? 'No autos referenced "$originalName".'
        : 'Updated autos: ${savedAutos.join(', ')}';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Split "$originalName" into "$part1Name.path" and "$part2Name.path". $autoMessage',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _syncCurrentPathPointTargetLink(
      String linkedName, Translation2d position) {
    PointTowardsZone.linkedTargets[linkedName] = position;

    for (final zone in widget.path.pointTowardsZones) {
      if (zone.linkedName == linkedName) {
        zone.fieldPosition = position;
      }
    }
  }

  Future<void> _syncLinkedHandoffHeadings() async {
    const double maxHeadingSpreadDeg = 12.0;
    const double minHandleLength = 1E-6;

    try {
      final allPaths = await PathPlannerPath.loadAllPathsInDir(
        widget.path.pathDir,
        widget.path.fs,
      );

      final startsByLink = <String, List<List<double>>>{};
      final endPathsByLink = <String, List<PathPlannerPath>>{};

      for (final path in allPaths) {
        if (path.waypoints.length < 2) {
          continue;
        }

        final first = path.waypoints.first;
        if (first.linkedName != null && first.nextControl != null) {
          final dx = first.nextControl!.x - first.anchor.x;
          final dy = first.nextControl!.y - first.anchor.y;
          final length = sqrt((dx * dx) + (dy * dy));

          if (length > minHandleLength) {
            startsByLink.putIfAbsent(first.linkedName!, () => []).add([
              dx / length,
              dy / length,
            ]);
          }
        }

        final last = path.waypoints.last;
        if (last.linkedName != null && last.prevControl != null) {
          endPathsByLink.putIfAbsent(last.linkedName!, () => []).add(path);
        }
      }

      int changedPaths = 0;
      final skipped = <String>[];
      final changedNames = <String>[];

      for (final entry in endPathsByLink.entries) {
        final linkedName = entry.key;
        final starts = startsByLink[linkedName];

        if (starts == null || starts.isEmpty) {
          skipped.add('$linkedName: no outgoing start handle');
          continue;
        }

        double sumX = 0.0;
        double sumY = 0.0;
        for (final direction in starts) {
          sumX += direction[0];
          sumY += direction[1];
        }

        final averageLength = sqrt((sumX * sumX) + (sumY * sumY));
        if (averageLength <= minHandleLength) {
          skipped.add('$linkedName: ambiguous opposing start headings');
          continue;
        }

        final targetX = sumX / averageLength;
        final targetY = sumY / averageLength;
        final minDot = cos(maxHeadingSpreadDeg * pi / 180.0);
        bool ambiguous = false;

        for (final direction in starts) {
          final dot = (targetX * direction[0]) + (targetY * direction[1]);
          if (dot < minDot) {
            ambiguous = true;
            break;
          }
        }

        if (ambiguous) {
          skipped.add('$linkedName: multiple outgoing headings');
          continue;
        }

        for (final path in entry.value) {
          final last = path.waypoints.last;
          final prevControl = last.prevControl;
          if (prevControl == null) {
            continue;
          }

          final handleDx = last.anchor.x - prevControl.x;
          final handleDy = last.anchor.y - prevControl.y;
          final handleLength =
              sqrt((handleDx * handleDx) + (handleDy * handleDy));

          if (handleLength <= minHandleLength) {
            skipped.add('${path.name}: end handle too short at $linkedName');
            continue;
          }

          final newPrevControl = Translation2d(
            last.anchor.x - (targetX * handleLength),
            last.anchor.y - (targetY * handleLength),
          );

          final deltaX = prevControl.x - newPrevControl.x;
          final deltaY = prevControl.y - newPrevControl.y;
          final delta = sqrt((deltaX * deltaX) + (deltaY * deltaY));
          if (delta <= 1E-5) {
            continue;
          }

          last.prevControl = newPrevControl;
          path.generateAndSavePath();
          changedPaths++;
          changedNames.add(path.name);

          if (path.name == widget.path.name) {
            setState(() {
              widget.path.waypoints =
                  PathPlannerPath.cloneWaypoints(path.waypoints);
              widget.path.generatePathPoints();
              _simulatePath();
            });
          }
        }
      }

      if (!mounted) {
        return;
      }

      final changedPreview = changedNames.take(12).join('\n');
      final skippedPreview = skipped.take(12).join('\n');
      final changedExtra = changedNames.length > 12
          ? '\n...and ${changedNames.length - 12} more'
          : '';
      final skippedExtra =
          skipped.length > 12 ? '\n...and ${skipped.length - 12} more' : '';

      await showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Linked heading sync complete'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Text(
                  'Changed paths: $changedPaths\n\n'
                  '${changedNames.isEmpty ? 'No path handles needed changes.' : 'Updated:\n$changedPreview$changedExtra'}\n\n'
                  '${skipped.isEmpty ? 'No linked waypoints were skipped.' : 'Skipped:\n$skippedPreview$skippedExtra'}',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } catch (ex, stack) {
      Log.error('Failed to sync linked handoff headings', ex, stack);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to sync linked headings: $ex'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _optimizeEndVelocity() {
    final oldEndVelocity = widget.path.goalEndState.velocityMPS;
    final startVelocity = widget.path.idealStartingState.velocityMPS;
    final constraints = widget.path.useDefaultConstraints
        ? _getDefaultConstraints()
        : widget.path.globalConstraints;
    final maxVelocity = constraints.maxVelocityMPS.isFinite
        ? constraints.maxVelocityMPS.toDouble()
        : _getDefaultConstraints().maxVelocityMPS.toDouble();

    double bestEndVelocity = oldEndVelocity.toDouble();
    double bestScore = double.negativeInfinity;
    double bestNearEndVelocity = 0.0;

    for (double endVelocity = 0.0;
        endVelocity <= maxVelocity + 1e-9;
        endVelocity += 0.25) {
      widget.path.goalEndState.velocityMPS = endVelocity;

      PathPlannerTrajectory trajectory;
      try {
        trajectory = PathPlannerTrajectory(
          path: widget.path,
          robotConfig: RobotConfig.fromPrefs(widget.prefs),
        );
      } catch (_) {
        continue;
      }

      final totalTime = trajectory.getTotalTimeSeconds().toDouble();
      if (!totalTime.isFinite || totalTime <= 0.0) {
        continue;
      }

      final nearEndTime = max(0.0, totalTime - 0.05);
      final nearEndVelocity =
          trajectory.sample(nearEndTime).fieldSpeeds.linearVel.toDouble();
      final velocityError = (endVelocity - nearEndVelocity).abs();

      double score = endVelocity * 4.0;
      score -= velocityError * 6.0;
      score -= totalTime * 0.10;

      if (velocityError > 0.50) {
        score -= (velocityError - 0.50) * 18.0;
      }

      if (score > bestScore) {
        bestScore = score;
        bestEndVelocity = endVelocity;
        bestNearEndVelocity = nearEndVelocity;
      }
    }

    widget.path.goalEndState.velocityMPS = oldEndVelocity;

    if (!bestScore.isFinite) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not optimize end velocity')),
      );
      return;
    }

    widget.undoStack.add(Change(
      oldEndVelocity,
      () {
        _setEndVelocity(bestEndVelocity);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Optimized end velocity: ${bestEndVelocity.toStringAsFixed(2)} m/s '
              '(near end ${bestNearEndVelocity.toStringAsFixed(2)} m/s, '
              'start kept ${startVelocity.toStringAsFixed(2)} m/s)',
            ),
          ),
        );
      },
      (oldValue) => _setEndVelocity(oldValue as num),
    ));
  }

  void _setEndVelocity(num endVelocity) {
    setState(() {
      widget.path.goalEndState.velocityMPS = endVelocity;
      widget.path.generateAndSavePath();
      _simulatePath();
      widget.onPathChanged?.call();
    });

    if (widget.hotReload) {
      widget.telemetry?.hotReloadPath(widget.path);
    }
  }

  Future<void> _syncLinkedVelocities() async {
    final paths = await PathPlannerPath.loadAllPathsInDir(
      widget.path.pathDir,
      widget.path.fs,
    );

    final currentStartLink = widget.path.waypoints.first.linkedName;
    final currentEndLink = widget.path.waypoints.last.linkedName;
    final oldValues = <PathPlannerPath, List<num>>{};
    final changes = <String>[];
    final skipped = <String>[];

    PathPlannerPath currentPathObject(PathPlannerPath path) {
      return path.name == widget.path.name ? widget.path : path;
    }

    void remember(PathPlannerPath path) {
      final actual = currentPathObject(path);
      oldValues.putIfAbsent(
        actual,
        () => [
          actual.idealStartingState.velocityMPS,
          actual.goalEndState.velocityMPS,
        ],
      );
    }

    if (currentStartLink != null) {
      final incoming = paths
          .where((p) =>
              p.name != widget.path.name &&
              p.waypoints.isNotEmpty &&
              p.waypoints.last.linkedName == currentStartLink)
          .toList();
      final incomingValues = incoming
          .map((p) => p.goalEndState.velocityMPS.toDouble())
          .map((v) => (v * 1000).round() / 1000.0)
          .toSet();

      if (incomingValues.length == 1) {
        final target = incomingValues.first;
        if ((widget.path.idealStartingState.velocityMPS - target).abs() >
            1e-6) {
          remember(widget.path);
          widget.path.idealStartingState.velocityMPS = target;
          changes.add(
              'Start velocity <- ${target.toStringAsFixed(2)} m/s from $currentStartLink');
        }
      } else if (incomingValues.length > 1) {
        skipped.add(
            'Start $currentStartLink has multiple incoming velocities: ${incomingValues.join(', ')}');
      }
    }

    if (currentEndLink != null) {
      final target = widget.path.goalEndState.velocityMPS;
      final outgoing = paths
          .where((p) =>
              p.name != widget.path.name &&
              p.waypoints.isNotEmpty &&
              p.waypoints.first.linkedName == currentEndLink)
          .toList();

      for (final path in outgoing) {
        final actual = currentPathObject(path);
        if ((actual.idealStartingState.velocityMPS - target).abs() > 1e-6) {
          remember(actual);
          actual.idealStartingState.velocityMPS = target;
          changes.add(
              '${actual.name} start <- ${target.toStringAsFixed(2)} m/s from ${widget.path.name} end');
        }
      }
    }

    if (oldValues.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(skipped.isEmpty
              ? 'No linked velocity changes found'
              : 'No changes. Skipped: ${skipped.join('; ')}'),
        ),
      );
      return;
    }

    widget.undoStack.add(Change(
      oldValues.map((path, values) => MapEntry(path, List<num>.from(values))),
      () => _setLinkedVelocityChanges(oldValues.keys.toList()),
      (oldValue) {
        final values = oldValue as Map<PathPlannerPath, List<num>>;
        for (final entry in values.entries) {
          entry.key.idealStartingState.velocityMPS = entry.value[0];
          entry.key.goalEndState.velocityMPS = entry.value[1];
        }
        _setLinkedVelocityChanges(values.keys.toList());
      },
    ));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Synced ${changes.length} velocity value(s)'
          '${skipped.isEmpty ? '' : '. Skipped ${skipped.length} ambiguous link(s).'}',
        ),
      ),
    );
  }

  void _setLinkedVelocityChanges(List<PathPlannerPath> changedPaths) {
    setState(() {
      for (final path in changedPaths) {
        path.generateAndSavePath();
      }
      _simulatePath();
      widget.onPathChanged?.call();
    });

    if (widget.hotReload) {
      widget.telemetry?.hotReloadPath(widget.path);
    }
  }

  void _simulatePath() async {
    if (widget.simulate) {
      setState(() {
        _simTraj = PathPlannerTrajectory(
          path: widget.path,
          robotConfig: RobotConfig.fromPrefs(widget.prefs),
        );
        if (!(_simTraj?.getTotalTimeSeconds().isFinite ?? false)) {
          _simTraj = null;
        }

        // Update the RuntimeDisplay widget
        _runtimeDisplay = RuntimeDisplay(
          currentRuntime: _simTraj?.states.last.timeSeconds,
          previousRuntime: _runtimeDisplay?.currentRuntime,
        );
      });

      if (!_paused) {
        _previewController.stop();
        _previewController.reset();
      }

      if (_simTraj != null) {
        try {
          if (!_paused) {
            _previewController.stop();
            _previewController.reset();
            _previewController.duration = Duration(
                milliseconds:
                    (_simTraj!.states.last.timeSeconds * 1000).toInt());
            _previewController.repeat();
          } else if (_previewController.duration != null) {
            double prevTime = _previewController.value *
                (_previewController.duration!.inMilliseconds / 1000.0);
            _previewController.duration = Duration(
                milliseconds:
                    (_simTraj!.states.last.timeSeconds * 1000).toInt());
            double newPos = prevTime / _simTraj!.states.last.timeSeconds;
            _previewController.forward(from: newPos);
            _previewController.stop();
          }
        } catch (_) {
          _showGenerationFailedError();
        }
      } else {
        // Trajectory failed to generate. Notify the user
        _showGenerationFailedError();
      }
    }
  }

  void _showGenerationFailedError() {
    Log.warning('Failed to generate trajectory for path: ${widget.path.name}');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Failed to generate trajectory. This is likely due to bad control point placement. Please adjust your control points to avoid kinks in the path.',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
        ),
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Theme.of(context).colorScheme.onErrorContainer,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  num _adjustDeletedWaypointRelativePos(num pos, int deletedWaypointIdx) {
    if (pos >= deletedWaypointIdx + 1) {
      return pos - 1.0;
    } else if (pos >= deletedWaypointIdx) {
      int segment = pos.floor();
      double segmentPct = pos % 1.0;

      return max(
          (((segment - 0.5) + (segmentPct / 2.0)) * 20).round() / 20.0, 0.0);
    } else if (pos > deletedWaypointIdx - 1) {
      int segment = pos.floor();
      double segmentPct = pos % 1.0;

      return min(widget.path.waypoints.length - 1,
          ((segment + (0.5 * segmentPct)) * 20).round() / 20.0);
    }

    return pos;
  }

  void _setSelectedWaypoint(int? waypointIdx) {
    setState(() {
      _selectedWaypoint = waypointIdx;
    });

    _waypointsTreeController.setSelectedWaypoint(waypointIdx);
  }

  double _xPixelsToMeters(double pixels) {
    return (((pixels - 48) / PathPainter.scale) /
            widget.fieldImage.pixelsPerMeter) -
        widget.fieldImage.marginMeters;
  }

  double _yPixelsToMeters(double pixels) {
    return ((widget.fieldImage.defaultSize.height -
                ((pixels - 48) / PathPainter.scale)) /
            widget.fieldImage.pixelsPerMeter) -
        widget.fieldImage.marginMeters;
  }

  double _pixelsToMeters(double pixels) {
    return (pixels / PathPainter.scale) / widget.fieldImage.pixelsPerMeter;
  }

  PathConstraints _getDefaultConstraints() {
    return PathConstraints(
      maxVelocityMPS: widget.prefs.getDouble(PrefsKeys.defaultMaxVel) ??
          Defaults.defaultMaxVel,
      maxAccelerationMPSSq: widget.prefs.getDouble(PrefsKeys.defaultMaxAccel) ??
          Defaults.defaultMaxAccel,
      maxAngularVelocityDeg:
          widget.prefs.getDouble(PrefsKeys.defaultMaxAngVel) ??
              Defaults.defaultMaxAngVel,
      maxAngularAccelerationDeg:
          widget.prefs.getDouble(PrefsKeys.defaultMaxAngAccel) ??
              Defaults.defaultMaxAngAccel,
    );
  }
}
