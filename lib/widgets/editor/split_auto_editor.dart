import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:path/path.dart' as p;
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/collab/collab_server.dart';
import 'package:pathplanner/collab/ghost_overlay.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/services/log.dart';
import 'package:pathplanner/trajectory/auto_simulator.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/trajectory/trajectory.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/widgets/dialogs/trajectory_render_dialog.dart';
import 'package:pathplanner/widgets/editor/path_painter.dart';
import 'package:pathplanner/widgets/editor/preview_seekbar.dart';
import 'package:pathplanner/widgets/editor/tree_widgets/auto_tree.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';

class SplitAutoEditor extends StatefulWidget {
  final SharedPreferences prefs;
  final PathPlannerAuto auto;
  final List<PathPlannerPath> autoPaths;
  final List<ChoreoPath> autoChoreoPaths;
  final List<PathPlannerPath> allPaths;
  final List<ChoreoPath> allChoreoPaths;
  final List<String> allPathNames;
  final String pathDir;
  final VoidCallback? onAutoChanged;
  final FieldImage fieldImage;
  final ChangeStack undoStack;
  final Function(String?)? onEditPathPressed;
  final VoidCallback? onImportAutoToStudio;

  const SplitAutoEditor({
    required this.prefs,
    required this.auto,
    required this.autoPaths,
    required this.autoChoreoPaths,
    required this.allPaths,
    required this.allChoreoPaths,
    required this.allPathNames,
    required this.pathDir,
    required this.fieldImage,
    required this.undoStack,
    this.onAutoChanged,
    this.onEditPathPressed,
    this.onImportAutoToStudio,
    super.key,
  });

  @override
  State<SplitAutoEditor> createState() => _SplitAutoEditorState();
}

class _SplitAutoEditorState extends State<SplitAutoEditor>
    with SingleTickerProviderStateMixin {
  static const String _hostTimingId = 'host';
  static const String _arbitraryAnchorId = '__arbitrary__';

  final MultiSplitViewController _controller = MultiSplitViewController();
  final CollabServer _collabServer = CollabServer();
  final TextEditingController _collabHostPasswordController =
      TextEditingController();
  Map<String, Map<String, dynamic>> _collabTeamStates = {};
  final Set<String> _hiddenCollabTeamAutoKeys = {};
  bool _collabLocalOnlyTeamUploads = true;
  final Map<String, int> _savedCollabAutoSignatures = {};
  final Map<String, bool> _collabTeamAutoFlipped = {};
  final Map<String, List<String>> _collabImportedFilePathsByTeam = {};
  bool _collabArchiveImportedFiles = true;
  bool _collabFlipUploadsBottomTop = false;
  final Map<String, String> _collabTeamGhostOverlayNames = {};
  List<Map<String, dynamic>> _collabBrowserMarkups = [];
  StateSetter? _ghostOverlayDialogSetState;
  List<String> _collabLanUrls = [];
  final List<GhostAutoOverlay> _ghostOverlays = [];
  final List<GhostAutoPauseBlock> _mainTimingPauses = [];

  String? _hoveredPath;
  String _openTimingSectionId = _hostTimingId;
  late bool _treeOnRight;
  PathPlannerTrajectory? _simTraj;
  bool _paused = false;
  late AnimationController _previewController;

  static const List<Color> _ghostColors = [
    Colors.pinkAccent,
    Colors.cyanAccent,
    Colors.amberAccent,
    Colors.lightGreenAccent,
    Colors.deepPurpleAccent,
    Colors.orangeAccent,
  ];

  @override
  void initState() {
    _collabServer.addTeamListener(_handleCollabTeamsChanged);
    unawaited(_loadCollabHostPassword());
    _collabServer.addMarkupListener(_handleCollabMarkupsChanged);
    super.initState();

    _previewController = AnimationController(vsync: this);
    _treeOnRight =
        widget.prefs.getBool(PrefsKeys.treeOnRight) ?? Defaults.treeOnRight;

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

    WidgetsBinding.instance.addPostFrameCallback((_) => _simulateAuto());
  }

  @override
  void didUpdateWidget(covariant SplitAutoEditor oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.auto != widget.auto ||
        oldWidget.autoPaths != widget.autoPaths ||
        oldWidget.autoChoreoPaths != widget.autoChoreoPaths) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _simulateAuto());
    }
  }

  @override
  void dispose() {
    _collabServer.removeTeamListener(_handleCollabTeamsChanged);
    _collabHostPasswordController.dispose();
    _collabServer.removeMarkupListener(_handleCollabMarkupsChanged);
    _collabServer.stop();
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
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Stack(
                children: [
                  widget.fieldImage.getWidget(),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: PathPainter(
                        colorScheme: colorScheme,
                        paths: widget.autoPaths,
                        choreoPaths: widget.autoChoreoPaths,
                        simple: true,
                        hideOtherPathsOnHover:
                            widget.prefs.getBool(PrefsKeys.hidePathsOnHover) ??
                                Defaults.hidePathsOnHover,
                        hoveredPath: _hoveredPath,
                        fieldImage: widget.fieldImage,
                        simulatedPath: _simTraj,
                        ghostOverlays: _ghostOverlays,
                        mainTimingPauses: _mainTimingPauses,
                        previewTotalTimeSeconds: _totalPreviewTimeSeconds(),
                        animation: _previewController.view,
                        prefs: widget.prefs,
                        collabMarkups: _collabBrowserMarkups,
                        collabTeamAutos: const [],
                      ),
                    ),
                  ),
                ],
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
              widget.prefs.setDouble(
                PrefsKeys.editorTreeWeight,
                newWeight ?? 0.5,
              );
            },
            children: [
              if (_treeOnRight)
                PreviewSeekbar(
                  previewController: _previewController,
                  simulatedPath: _simTraj,
                  onPauseStateChanged: (value) => _paused = value,
                  totalPathTime: _totalPreviewTimeSeconds(),
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
                  child: AutoTree(
                    auto: widget.auto,
                    autoRuntime: _simTraj?.states.last.timeSeconds,
                    allPathNames: widget.allPathNames,
                    onRenderAuto: () {
                      if (_simTraj != null) {
                        showDialog(
                          context: context,
                          builder: (context) {
                            return TrajectoryRenderDialog(
                              fieldImage: widget.fieldImage,
                              prefs: widget.prefs,
                              trajectory: _simTraj!,
                            );
                          },
                        );
                      }
                    },
                    onPathHovered: (value) {
                      setState(() {
                        _hoveredPath = value;
                      });
                    },
                    onAutoChanged: () {
                      widget.onAutoChanged?.call();

                      Future.delayed(const Duration(milliseconds: 100)).then(
                        (_) {
                          if (mounted) {
                            _simulateAuto();
                          }
                        },
                      );
                    },
                    onSideSwapped: () => setState(() {
                      _treeOnRight = !_treeOnRight;
                      widget.prefs.setBool(PrefsKeys.treeOnRight, _treeOnRight);
                      _controller.areas = _controller.areas.reversed.toList();
                    }),
                    undoStack: widget.undoStack,
                    onEditPathPressed: widget.onEditPathPressed,
                    onImportAutoToStudio: widget.onImportAutoToStudio,
                    onManageGhostOverlays: _showGhostOverlayDialog,
                    ghostOverlayCount: _ghostOverlays
                        .where((overlay) => overlay.visible)
                        .length,
                  ),
                ),
              ),
              if (!_treeOnRight)
                PreviewSeekbar(
                  previewController: _previewController,
                  simulatedPath: _simTraj,
                  onPauseStateChanged: (value) => _paused = value,
                  totalPathTime: _totalPreviewTimeSeconds(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  double _mainNativeTimeSeconds({PathPlannerTrajectory? currentTrajectory}) {
    final mainTrajectory = currentTrajectory ?? _simTraj;
    if (mainTrajectory == null || mainTrajectory.states.isEmpty) {
      return 0.0;
    }

    return mainTrajectory.states.last.timeSeconds.toDouble();
  }

  double _mainTotalTimeSeconds({PathPlannerTrajectory? currentTrajectory}) {
    double total = _mainNativeTimeSeconds(currentTrajectory: currentTrajectory);
    for (final pause in _mainTimingPauses) {
      if (pause.durationSeconds > 0.0) {
        total += pause.durationSeconds;
      }
    }
    return total;
  }

  double _totalPreviewTimeSeconds({PathPlannerTrajectory? currentTrajectory}) {
    double total = _mainTotalTimeSeconds(currentTrajectory: currentTrajectory);

    for (final ghost in _ghostOverlays) {
      if (!ghost.visible || ghost.trajectory.states.isEmpty) {
        continue;
      }

      final ghostTime = ghost.totalTimeSeconds;
      if (ghostTime > total) {
        total = ghostTime;
      }
    }

    if (!total.isFinite || total <= 0.0) {
      return 1.0;
    }

    return total;
  }

  void _setPreviewDurationForCurrentComparison({
    PathPlannerTrajectory? currentTrajectory,
    bool preserveCurrentTime = false,
  }) {
    final totalTime = _totalPreviewTimeSeconds(
      currentTrajectory: currentTrajectory,
    );

    final oldDuration = _previewController.duration;
    final oldSeconds = oldDuration == null
        ? 0.0
        : _previewController.value *
            oldDuration.inMilliseconds.toDouble() /
            1000.0;

    _previewController.duration = Duration(
      milliseconds: (totalTime * 1000).round().clamp(1, 900000),
    );

    if (preserveCurrentTime) {
      _previewController.value = (oldSeconds / totalTime).clamp(0.0, 1.0);
    }
  }

  void _refreshPreviewDuration() {
    final wasAnimating = _previewController.isAnimating;

    _setPreviewDurationForCurrentComparison(preserveCurrentTime: true);

    if (!_paused && wasAnimating) {
      _previewController.repeat();
    }

    _publishCollabSnapshot();
  }

  Widget _buildComparisonTimelineSummary() {
    final totalSeconds = _totalPreviewTimeSeconds();
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withAlpha(80),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Match Timeline',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  '${totalSeconds.toStringAsFixed(2)}s',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildTimelineRow(
              name: widget.auto.name,
              subtitle: 'Host',
              color: colorScheme.primary,
              nativeSeconds: _mainNativeTimeSeconds(),
              totalSeconds: totalSeconds,
              pauses: _mainTimingPauses,
              visible: true,
            ),
            for (final overlay in _ghostOverlays)
              _buildTimelineRow(
                name: overlay.name,
                subtitle: overlay.visible ? 'Active' : 'Bench',
                color: overlay.color,
                nativeSeconds: overlay.nativeTimeSeconds,
                totalSeconds: totalSeconds,
                pauses: overlay.pauses,
                visible: overlay.visible,
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                _buildTimelineLegendSwatch(colorScheme.primary),
                const SizedBox(width: 4),
                const Text('Driving'),
                const SizedBox(width: 12),
                _buildTimelineLegendSwatch(colorScheme.tertiary),
                const SizedBox(width: 4),
                const Text('Wait'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineLegendSwatch(Color color) {
    return Container(
      width: 14,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  Widget _buildTimelineRow({
    required String name,
    required String subtitle,
    required Color color,
    required double nativeSeconds,
    required double totalSeconds,
    required List<GhostAutoPauseBlock> pauses,
    required bool visible,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final segments = _timelineSegments(
      nativeSeconds: nativeSeconds,
      pauses: pauses,
    );

    final row = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  '$subtitle • ${_timelineTotalSeconds(nativeSeconds, pauses).toStringAsFixed(2)}s',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 22,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: colorScheme.surface.withAlpha(170),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                      ),
                      for (final segment in segments)
                        Positioned(
                          left: ((segment.startSeconds / totalSeconds) * width)
                              .clamp(0.0, width)
                              .toDouble(),
                          top: 3,
                          bottom: 3,
                          width:
                              ((segment.durationSeconds / totalSeconds) * width)
                                  .clamp(2.0, width)
                                  .toDouble(),
                          child: Tooltip(
                            message:
                                '${segment.label}: ${segment.startSeconds.toStringAsFixed(2)}s to ${(segment.startSeconds + segment.durationSeconds).toStringAsFixed(2)}s',
                            child: Container(
                              decoration: BoxDecoration(
                                color: segment.isPause
                                    ? colorScheme.tertiary
                                    : color,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );

    return visible ? row : Opacity(opacity: 0.45, child: row);
  }

  List<_TimelineSegment> _timelineSegments({
    required double nativeSeconds,
    required List<GhostAutoPauseBlock> pauses,
  }) {
    final segments = <_TimelineSegment>[];
    final sortedPauses = List<GhostAutoPauseBlock>.of(pauses)
      ..sort((a, b) => a.afterSeconds.compareTo(b.afterSeconds));

    double autoSeconds = 0.0;
    double timelineSeconds = 0.0;

    for (final pause in sortedPauses) {
      if (pause.durationSeconds <= 0.0) {
        continue;
      }

      final pauseAt = pause.afterSeconds.clamp(0.0, nativeSeconds).toDouble();

      if (pauseAt > autoSeconds) {
        final driveDuration = pauseAt - autoSeconds;
        segments.add(
          _TimelineSegment(
            startSeconds: timelineSeconds,
            durationSeconds: driveDuration,
            label: 'Driving',
            isPause: false,
          ),
        );
        timelineSeconds += driveDuration;
        autoSeconds = pauseAt;
      }

      segments.add(
        _TimelineSegment(
          startSeconds: timelineSeconds,
          durationSeconds: pause.durationSeconds,
          label: '${pause.label} (${_pauseModeLabel(pause)})',
          isPause: true,
        ),
      );
      timelineSeconds += pause.durationSeconds;
    }

    if (nativeSeconds > autoSeconds) {
      segments.add(
        _TimelineSegment(
          startSeconds: timelineSeconds,
          durationSeconds: nativeSeconds - autoSeconds,
          label: 'Driving',
          isPause: false,
        ),
      );
    }

    return segments;
  }

  double _timelineTotalSeconds(
    double nativeSeconds,
    List<GhostAutoPauseBlock> pauses,
  ) {
    return nativeSeconds +
        pauses.fold<double>(
          0.0,
          (sum, pause) => sum + pause.durationSeconds,
        );
  }

  int _activeReferenceOverlayCount() {
    return _ghostOverlays.where((overlay) => overlay.visible).length;
  }

  void _setReferenceOverlayActive(
    GhostAutoOverlay overlay,
    bool active,
    StateSetter dialogSetState,
  ) {
    if (active && !overlay.visible && _activeReferenceOverlayCount() >= 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Only two reference autos can be active with the host auto. Bench another reference first.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      overlay.visible = active;
      _publishCollabSnapshot();
    });
    _refreshPreviewDuration();
    dialogSetState(() {});
  }

  Widget _buildActiveMatchSummaryCard() {
    final colorScheme = Theme.of(context).colorScheme;
    final active = _ghostOverlays.where((overlay) => overlay.visible).toList();
    final bench = _ghostOverlays.where((overlay) => !overlay.visible).toList();

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withAlpha(80),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.groups_2_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Active Match',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  'Host + ${active.length}/2 references',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                Chip(
                  avatar: Icon(
                    Icons.home_outlined,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                  label: Text(widget.auto.name),
                ),
                for (final overlay in active)
                  Chip(
                    avatar: Icon(
                      Icons.circle,
                      size: 12,
                      color: overlay.color,
                    ),
                    label: Text(overlay.name),
                  ),
                if (active.isEmpty)
                  Text(
                    'No active reference autos yet.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (bench.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Bench: ${bench.map((overlay) => overlay.name).join(', ')}',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showAddProjectAutoOverlayDialog(
    List<String> autoNames,
    StateSetter dialogSetState,
  ) async {
    final searchController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final query = searchController.text.trim().toLowerCase();
            final filteredAutos = autoNames.where((autoName) {
              final alreadyAdded = _ghostOverlays.any(
                (overlay) => overlay.name == autoName,
              );

              if (alreadyAdded || autoName == widget.auto.name) {
                return false;
              }

              if (query.isEmpty) {
                return true;
              }

              return autoName.toLowerCase().contains(query);
            }).toList();

            return AlertDialog(
              title: const Text('Add Project Auto Reference'),
              content: SizedBox(
                width: 520,
                height: 480,
                child: Column(
                  children: [
                    TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Search project autos',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: filteredAutos.isEmpty
                          ? const Center(
                              child: Text('No matching autos available.'),
                            )
                          : ListView.builder(
                              itemCount: filteredAutos.length,
                              itemBuilder: (context, index) {
                                final autoName = filteredAutos[index];

                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    autoName,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: const Icon(Icons.add_rounded),
                                  onTap: () async {
                                    await _addGhostOverlay(
                                      autoName,
                                      dialogSetState,
                                    );

                                    if (mounted) {
                                      Navigator.of(dialogContext).pop();
                                    }
                                  },
                                );
                              },
                            ),
                    ),
                  ],
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
      },
    );

    searchController.dispose();
  }

  Future<void> _refreshCollabLanUrls() async {
    final port = _collabServer.port;
    if (port == null) {
      _collabLanUrls = [];
      return;
    }

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final urls = <String>[];
      final seen = <String>{};

      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final host = address.address;
          if (host.startsWith('127.')) {
            continue;
          }

          final url = 'http://$host:$port';
          if (seen.add(url)) {
            urls.add(url);
          }
        }
      }

      _collabLanUrls = urls;
    } catch (_) {
      _collabLanUrls = [];
    }
  }

  String? _primaryCollabLanUrl() {
    if (_collabLanUrls.isEmpty) {
      return null;
    }

    return _collabLanUrls.first;
  }

  String _collabSessionSubtitle() {
    if (!_collabServer.isRunning) {
      return 'Stopped. Start to let others view this plan in a browser.';
    }

    final localUrl = _collabUrl();
    final lanUrl = _primaryCollabLanUrl();
    final pairing = _collabServer.pairingCode;

    if (lanUrl == null) {
      return 'Pairing: $pairing\nHost team: 1591\nLocal: $localUrl\nLAN: No LAN IP found yet';
    }

    return 'Pairing: $pairing\nHost team: 1591\nLocal: $localUrl\nLAN: $lanUrl';
  }

  Future<void> _copyCollabLocalUrl() async {
    final url = _collabUrl();
    if (url == null) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: url));
  }

  Future<void> _copyCollabLanUrl() async {
    final url = _primaryCollabLanUrl();
    if (url == null) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: url));
  }

  Future<void> _publishCollabFieldImage() async {
    try {
      final filePath = widget.fieldImage.filePath;
      final assetPath = widget.fieldImage.assetPath;

      if (filePath != null && filePath.isNotEmpty) {
        final file = File(filePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          _collabServer.setFieldImage(
            bytes,
            _collabImageContentType(widget.fieldImage.extension),
          );
          return;
        }
      }

      if (assetPath != null && assetPath.isNotEmpty) {
        final data = await rootBundle.load(assetPath);
        _collabServer.setFieldImage(
          data.buffer.asUint8List(),
          _collabImageContentType(widget.fieldImage.extension),
        );
      }
    } catch (_) {
      _collabServer.setFieldImage(null, 'image/png');
    }
  }

  String _collabImageContentType(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'png':
      default:
        return 'image/png';
    }
  }

  Future<void> _loadCollabHostPassword() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('pathplanner_collab_host_password') ?? '';
      if (!mounted || _collabHostPasswordController.text.isNotEmpty) {
        return;
      }

      _collabHostPasswordController.text = value;
    } catch (_) {
      // Leave the field blank if local cache is unavailable.
    }
  }

  Future<void> _saveCollabHostPassword() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'pathplanner_collab_host_password',
        _collabHostPasswordController.text.trim(),
      );
    } catch (_) {
      // The session can still run without persistence.
    }
  }

  Future<bool> _ensureCollabHostPassword() async {
    if (_collabHostPasswordController.text.trim().isNotEmpty) {
      await _saveCollabHostPassword();
      return true;
    }

    final controller = TextEditingController(
      text: _collabHostPasswordController.text,
    );

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Set 1591 Host Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Anyone joining as team 1591 will need this password to get host privileges in the browser.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '1591 host password',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.of(context).pop(true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Start Session'),
            ),
          ],
        );
      },
    );

    if (accepted != true || controller.text.trim().isEmpty) {
      controller.dispose();
      return false;
    }

    _collabHostPasswordController.text = controller.text.trim();
    controller.dispose();
    await _saveCollabHostPassword();
    return true;
  }

  String _safeCollabFileName(Object? raw, {String fallback = 'Uploaded Auto'}) {
    final source = raw?.toString() ?? fallback;
    var cleaned = source.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.isEmpty ? fallback : cleaned;
  }

  String _collabAutosDir() {
    return p.join(p.dirname(widget.pathDir), 'autos');
  }

  String _teamPrefixedName(String teamKey, Object? rawName) {
    final safeTeam = _safeCollabFileName(teamKey, fallback: 'Team');
    final safeName = _safeCollabFileName(rawName, fallback: 'Uploaded Auto');

    if (safeName == safeTeam || safeName.startsWith('\${safeTeam}_')) {
      return safeName;
    }

    return '\${safeTeam}_$safeName';
  }

  void _rewriteUploadedAutoPathNames(
    dynamic node,
    Map<String, String> pathNameMap,
  ) {
    if (node is List) {
      for (final item in node) {
        _rewriteUploadedAutoPathNames(item, pathNameMap);
      }
      return;
    }

    if (node is! Map) {
      return;
    }

    for (final entry in List<MapEntry>.from(node.entries)) {
      final key = entry.key;
      final value = entry.value;

      if (key == 'pathName' &&
          value is String &&
          pathNameMap.containsKey(value)) {
        node[key] = pathNameMap[value];
      } else {
        _rewriteUploadedAutoPathNames(value, pathNameMap);
      }
    }
  }

  Map<String, dynamic>? _copyRawJsonMap(Object? raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }

    return null;
  }

  Map<String, Map<String, dynamic>> _copyRawPathJsons(Object? raw) {
    final result = <String, Map<String, dynamic>>{};

    if (raw is! Map) {
      return result;
    }

    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;

      if (key is String && value is Map) {
        result[key] = Map<String, dynamic>.from(value);
      }
    }

    return result;
  }

  Map<String, String>? _saveCollabUploadedAutoFiles({
    required String teamKey,
    required String autoName,
    required Map<String, dynamic> autoJson,
    required Map<String, Map<String, dynamic>> pathJsons,
  }) {
    _archiveOrDeleteCollabImportedFilesForTeam(teamKey);

    final writtenFilePaths = <String>[];
    final autosDir = Directory(_collabAutosDir());
    final pathsDir = Directory(widget.pathDir);

    autosDir.createSync(recursive: true);
    pathsDir.createSync(recursive: true);

    final pathNameMap = <String, String>{};
    const encoder = JsonEncoder.withIndent('  ');

    for (final entry in pathJsons.entries) {
      final originalPathName = entry.key;
      final savedPathName = _teamPrefixedName(teamKey, originalPathName);
      pathNameMap[originalPathName] = savedPathName;

      final pathJson = Map<String, dynamic>.from(entry.value);
      pathJson['useDefaultConstraints'] = false;
      final pathFile = File(p.join(widget.pathDir, '$savedPathName.path'));
      pathFile.writeAsStringSync('${encoder.convert(pathJson)}\n');
    }

    final savedAutoName = _teamPrefixedName(teamKey, autoName);
    final savedAutoJson = Map<String, dynamic>.from(autoJson);
    _rewriteUploadedAutoPathNames(savedAutoJson, pathNameMap);

    final autoFile = File(p.join(_collabAutosDir(), '$savedAutoName.auto'));
    autoFile.writeAsStringSync('${encoder.convert(savedAutoJson)}\n');

    return {
      'autoName': savedAutoName,
      'autoPath': autoFile.path,
      'pathCount': pathNameMap.length.toString(),
    };
  }

  List<PathPlannerPath> _loadCollabProjectPathsWithGuiModel() {
    final paths = <PathPlannerPath>[];
    final dir = Directory(widget.pathDir);

    if (!dir.existsSync()) {
      return paths;
    }

    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.path')) {
        continue;
      }

      try {
        final decoded = jsonDecode(entity.readAsStringSync());
        if (decoded is! Map) {
          continue;
        }

        final pathName = p.basenameWithoutExtension(entity.path);
        final pathJson = Map<String, dynamic>.from(decoded);
        final path = PathPlannerPath.fromJson(
          pathJson,
          pathName,
          widget.pathDir,
          widget.auto.fs,
        );
        path.lastModified = entity.lastModifiedSync().toUtc();
        paths.add(path);
      } catch (err) {
        Log.warning(
            'Failed to load collab path for GUI render: ${entity.path}: $err');
      }
    }

    return paths;
  }

  Map<String, dynamic> _renderSavedCollabAutoWithPathPlannerGui({
    required String teamKey,
    required String visibleAutoName,
    required String savedAutoName,
    required Map<String, dynamic> existingPayload,
  }) {
    final rendered = Map<String, dynamic>.from(existingPayload)
      ..['name'] = savedAutoName
      ..['sourceName'] = visibleAutoName
      ..['hostSavedAutoName'] = savedAutoName
      ..['hostGuiRendered'] = false;

    try {
      final autoFile = File(p.join(_collabAutosDir(), '$savedAutoName.auto'));
      if (!autoFile.existsSync()) {
        rendered['hostGuiRenderError'] =
            'Saved auto file does not exist: ${autoFile.path}';
        return rendered;
      }

      final decoded = jsonDecode(autoFile.readAsStringSync());
      if (decoded is! Map) {
        rendered['hostGuiRenderError'] = 'Saved auto JSON was not an object.';
        return rendered;
      }

      final auto = PathPlannerAuto.fromJson(
        Map<String, dynamic>.from(decoded),
        savedAutoName,
        _collabAutosDir(),
        widget.auto.fs,
      );

      if (auto.choreoAuto) {
        rendered['hostGuiRenderError'] =
            'Choreo autos are not supported for browser team auto overlays yet.';
        return rendered;
      }

      final allPaths = _loadCollabProjectPathsWithGuiModel();
      final pathsByName = <String, PathPlannerPath>{
        for (final path in allPaths) path.name: path,
      };

      final resolvedPaths = <PathPlannerPath>[];
      final missingPaths = <String>[];

      for (final pathName in auto.getAllPathNames()) {
        final path = pathsByName[pathName];
        if (path == null) {
          missingPaths.add(pathName);
        } else {
          resolvedPaths.add(path);
        }
      }

      rendered['missingPaths'] = missingPaths;

      if (resolvedPaths.isEmpty) {
        rendered['hostGuiRenderError'] =
            'No referenced PathPlanner paths could be loaded for $savedAutoName.';
        return rendered;
      }

      final config = RobotConfig.fromPrefs(widget.prefs);
      final trajectory = AutoSimulator.simulateAuto(resolvedPaths, config);

      if (trajectory == null) {
        rendered['hostGuiRenderError'] =
            'PathPlanner AutoSimulator returned no trajectory.';
        return rendered;
      }

      final totalSeconds = trajectory.getTotalTimeSeconds().toDouble();
      if (trajectory.states.isEmpty ||
          !totalSeconds.isFinite ||
          totalSeconds <= 0.0) {
        rendered['hostGuiRenderError'] =
            'PathPlanner generated an empty or invalid trajectory.';
        return rendered;
      }

      final samples = _samplesFromPathPlannerGuiTrajectory(trajectory);
      if (samples.length < 2) {
        rendered['hostGuiRenderError'] =
            'PathPlanner trajectory did not produce enough drawable samples.';
        return rendered;
      }

      rendered['samples'] = samples;
      rendered['nativeSeconds'] = totalSeconds;
      rendered['totalSeconds'] = totalSeconds;
      rendered['segments'] = [
        {
          'startSeconds': 0.0,
          'durationSeconds': totalSeconds,
          'label': 'PathPlanner GUI',
          'type': 'drive',
          'isPause': false,
        }
      ];
      rendered['hostGuiRendered'] = true;
      rendered.remove('hostGuiRenderError');

      return rendered;
    } catch (err, stack) {
      Log.warning(
        'Failed to render collab uploaded auto through PathPlanner GUI: $teamKey / $savedAutoName',
        err,
        stack,
      );
      rendered['hostGuiRenderError'] = err.toString();
      return rendered;
    }
  }

  List<Map<String, dynamic>> _samplesFromPathPlannerGuiTrajectory(
    PathPlannerTrajectory trajectory,
  ) {
    final totalSeconds = trajectory.getTotalTimeSeconds().toDouble();
    final samples = <Map<String, dynamic>>[];

    if (!totalSeconds.isFinite || totalSeconds <= 0.0) {
      return samples;
    }

    const sampleStepSeconds = 0.05;

    void addSample(double timeSeconds) {
      final clampedTime = timeSeconds.clamp(0.0, totalSeconds).toDouble();
      final state = trajectory.sample(clampedTime);
      final dynamic stateDynamic = state;
      final dynamic pose = stateDynamic.pose;
      final dynamic translation = pose.translation;
      final dynamic rotation = pose.rotation;

      samples.add({
        't': clampedTime,
        'x': _normalizeCollabGuiX(translation.x as num),
        'y': _normalizeCollabGuiY(translation.y as num),
        'theta': (rotation.radians as num).toDouble(),
      });
    }

    for (double t = 0.0; t < totalSeconds; t += sampleStepSeconds) {
      addSample(t);
    }

    addSample(totalSeconds);
    return samples;
  }

  double _normalizeCollabGuiX(num xMeters) {
    final widthPixels = widget.fieldImage.defaultSize.width.toDouble();
    if (widthPixels <= 0.0) {
      return 0.0;
    }

    final xPixels = (xMeters + widget.fieldImage.marginMeters) *
        widget.fieldImage.pixelsPerMeter;
    return (xPixels / widthPixels).clamp(0.0, 1.0).toDouble();
  }

  double _normalizeCollabGuiY(num yMeters) {
    final heightPixels = widget.fieldImage.defaultSize.height.toDouble();
    if (heightPixels <= 0.0) {
      return 0.0;
    }

    final yPixels = heightPixels -
        ((yMeters + widget.fieldImage.marginMeters) *
            widget.fieldImage.pixelsPerMeter);
    return (yPixels / heightPixels).clamp(0.0, 1.0).toDouble();
  }

  void _saveBrowserUploadedTeamAuto(Map<String, dynamic> team) {
    final teamKey = team['key'];
    final autoRaw = team['auto'];

    if (teamKey is! String || teamKey.isEmpty || autoRaw is! Map) {
      return;
    }

    final auto = Map<String, dynamic>.from(autoRaw);
    final sourceAutoJson = _copyRawJsonMap(auto['sourceAutoJson']);
    final sourcePathJsons = _copyRawPathJsons(auto['sourcePathJsons']);

    if (sourceAutoJson == null || sourcePathJsons.isEmpty) {
      return;
    }

    final autoName = auto['name']?.toString() ?? 'Uploaded Auto';
    final signature = jsonEncode({
      'teamKey': teamKey,
      'autoName': autoName,
      'auto': sourceAutoJson,
      'paths': sourcePathJsons.keys.toList()..sort(),
    }).hashCode;

    if (_savedCollabAutoSignatures[teamKey] == signature) {
      final savedAutoName = _teamPrefixedName(teamKey, autoName);
      final overlay = _ensureCollabSavedAutoGhostOverlay(
        teamKey: teamKey,
        savedAutoName: savedAutoName,
        color: team['color'],
      );

      if (overlay != null) {
        auto['hostSavedAutoName'] = savedAutoName;
        auto['hostGhostOverlayName'] = overlay.name;
        auto['hostRenderedByGhostOverlay'] = true;
        auto.remove('samples');
        auto.remove('segments');
        team['auto'] = auto;
      }

      return;
    }

    try {
      final saved = _saveCollabUploadedAutoFiles(
        teamKey: teamKey,
        autoName: autoName,
        autoJson: sourceAutoJson,
        pathJsons: sourcePathJsons,
      );

      if (saved == null) {
        return;
      }

      final savedAutoName =
          saved['autoName'] ?? _teamPrefixedName(teamKey, autoName);

      auto['hostSavedAutoName'] = savedAutoName;
      auto['hostSavedAutoPath'] = saved['autoPath'];
      auto['hostSavedPathCount'] = int.tryParse(saved['pathCount'] ?? '0') ?? 0;

      final overlay = _ensureCollabSavedAutoGhostOverlay(
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
      _savedCollabAutoSignatures[teamKey] = signature;
    } catch (err) {
      auto['hostSaveError'] = err.toString();
      team['auto'] = auto;
    }
  }

  Future<void> _importLocalCollabTeamAuto() async {
    final teamController = TextEditingController();

    final teamKey = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Upload Local Team Auto'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: teamController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Team number',
                hintText: 'Example: 190, 516, 5940',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                Navigator.of(context).pop(value.trim());
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(teamController.text.trim()),
              child: const Text('Choose Files'),
            ),
          ],
        );
      },
    );

    if (teamKey == null || teamKey.trim().isEmpty || !mounted) {
      return;
    }

    const typeGroup = XTypeGroup(
      label: 'PathPlanner auto and paths',
      extensions: ['auto', 'path'],
    );

    final files = await openFiles(
      acceptedTypeGroups: [typeGroup],
      initialDirectory: widget.pathDir,
    );

    if (files.isEmpty || !mounted) {
      return;
    }

    final autoFiles = files
        .where((file) => file.path.toLowerCase().endsWith('.auto'))
        .toList();
    final pathFiles = files
        .where((file) => file.path.toLowerCase().endsWith('.path'))
        .toList();

    if (autoFiles.length != 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Select exactly one .auto file plus its referenced .path files.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final autoFile = File(autoFiles.first.path);
      final autoJson = Map<String, dynamic>.from(
        jsonDecode(autoFile.readAsStringSync()) as Map,
      );

      final referencedPathNames =
          _extractUploadedAutoPathNames(autoJson).toSet();
      final pathJsons = <String, Map<String, dynamic>>{};
      for (final selectedPath in pathFiles) {
        final file = File(selectedPath.path);
        final name = p.basenameWithoutExtension(file.path);
        if (referencedPathNames.isNotEmpty &&
            !referencedPathNames.contains(name)) {
          continue;
        }
        pathJsons[name] = Map<String, dynamic>.from(
          jsonDecode(file.readAsStringSync()) as Map,
        );
      }

      final importedName = p.basenameWithoutExtension(autoFile.path);
      final saved = _saveCollabUploadedAutoFiles(
        teamKey: teamKey.trim(),
        autoName: importedName,
        autoJson: autoJson,
        pathJsons: pathJsons,
      );

      if (saved == null) {
        return;
      }

      final autoPayload = <String, dynamic>{
        'name': importedName,
        'totalSeconds': 0.0,
        'nativeSeconds': 0.0,
        'waitCount': 0,
        'samples': <Map<String, dynamic>>[],
        'segments': <Map<String, dynamic>>[],
        'localOnly': true,
        'hostSavedAutoName': saved['autoName'],
        'hostSavedAutoPath': saved['autoPath'],
        'hostSavedPathCount': int.tryParse(saved['pathCount'] ?? '0') ?? 0,
      };

      final savedAutoName =
          saved['autoName'] ?? _teamPrefixedName(teamKey.trim(), importedName);
      final overlay = _ensureCollabSavedAutoGhostOverlay(
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

      setState(() {
        final team = Map<String, dynamic>.from(
          _collabTeamStates[teamKey.trim()] ?? const <String, dynamic>{},
        );

        team['key'] = teamKey.trim();
        team['claimed'] = true;
        team['claimedBy'] = 'Host local import';
        team['color'] = team['color'] ?? '#ff4fd8';
        team['auto'] = autoPayload;
        _collabTeamStates[teamKey.trim()] = team;
      });

      try {
        _ghostOverlayDialogSetState?.call(() {});
      } catch (_) {
        _ghostOverlayDialogSetState = null;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved local team auto ${saved['autoName']}.auto with ${saved['pathCount']} path file(s).',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not import local team auto: $err'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _handleCollabTeamsChanged(Map<String, dynamic> payload) {
    final teamsRaw = payload['teams'];
    final next = <String, Map<String, dynamic>>{};

    if (teamsRaw is List) {
      for (final rawTeam in teamsRaw) {
        if (rawTeam is! Map) {
          continue;
        }

        final team = Map<String, dynamic>.from(rawTeam);
        final key = team['key'];
        if (key is String && key.isNotEmpty) {
          next[key] = team;
        }
      }
    }

    for (final team in next.values) {
      _saveBrowserUploadedTeamAuto(team);
      _syncCollabTeamOverlayFromTeam(team);
    }

    for (final key in List<String>.of(_collabImportedFilePathsByTeam.keys)) {
      final team = next[key];
      if (team == null || team['auto'] is! Map) {
        _archiveOrDeleteCollabImportedFilesForTeam(key);
      }
    }

    if (!mounted) {
      _collabTeamStates = next;
      return;
    }

    setState(() {
      _collabTeamStates = next;
      _hiddenCollabTeamAutoKeys.removeWhere(
        (key) => !next.containsKey(key),
      );
    });

    try {
      _ghostOverlayDialogSetState?.call(() {});
    } catch (_) {
      _ghostOverlayDialogSetState = null;
    }
  }

  List<String> _extractUploadedAutoPathNames(Map<String, dynamic> autoJson) {
    final names = <String>{};

    void visit(dynamic node) {
      if (node is List) {
        for (final item in node) {
          visit(item);
        }
        return;
      }

      if (node is! Map) {
        return;
      }

      final pathName = node['pathName'];
      if (pathName is String && pathName.trim().isNotEmpty) {
        names.add(pathName.trim());
      }

      for (final value in node.values) {
        visit(value);
      }
    }

    visit(autoJson);
    return names.toList()..sort();
  }

  String _collabArchiveDir() {
    final pathplannerDir = p.dirname(widget.pathDir);
    final deployDir = p.dirname(pathplannerDir);
    return p.join(deployDir, 'pathplanner_collab_archive');
  }

  String _collabArchiveStamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');

    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  void _archiveOrDeleteCollabImportedFilesForTeam(String teamKey) {
    final paths = _collabImportedFilePathsByTeam.remove(teamKey);

    final overlayName = _collabTeamGhostOverlayNames.remove(teamKey);
    if (overlayName != null) {
      _ghostOverlays.removeWhere((overlay) => overlay.name == overlayName);
    }

    if (paths == null || paths.isEmpty) {
      return;
    }

    final archiveDir = Directory(
      p.join(
        _collabArchiveDir(),
        _collabArchiveStamp(),
        _safeCollabFileName(teamKey),
      ),
    );

    for (final rawPath in paths) {
      try {
        final file = File(rawPath);
        if (!file.existsSync()) {
          continue;
        }

        if (_collabArchiveImportedFiles) {
          archiveDir.createSync(recursive: true);
          final target = File(p.join(archiveDir.path, p.basename(file.path)));

          if (target.existsSync()) {
            target.deleteSync();
          }

          file.renameSync(target.path);
        } else {
          file.deleteSync();
        }
      } catch (err) {
        Log.warning(
            'Failed to archive/delete collab imported file $rawPath: $err');
      }
    }
  }

  void _archiveOrDeleteAllCollabImportedFiles() {
    for (final key in List<String>.of(_collabImportedFilePathsByTeam.keys)) {
      _archiveOrDeleteCollabImportedFilesForTeam(key);
    }

    _savedCollabAutoSignatures.clear();
  }

  double _collabFieldHeightMeters() {
    return (widget.fieldImage.defaultSize.height.toDouble() /
            widget.fieldImage.pixelsPerMeter.toDouble()) -
        (2.0 * widget.fieldImage.marginMeters.toDouble());
  }

  void _prepareUploadedPathJsonForHost(Map<String, dynamic> pathJson) {
    pathJson['useDefaultConstraints'] = false;

    if (_collabFlipUploadsBottomTop) {
      _flipUploadedPathJsonBottomTop(pathJson);
    }
  }

  void _flipUploadedPathJsonBottomTop(Map<String, dynamic> pathJson) {
    final fieldHeightMeters = _collabFieldHeightMeters();

    void visit(dynamic node) {
      if (node is List) {
        for (final item in node) {
          visit(item);
        }
        return;
      }

      if (node is! Map) {
        return;
      }

      final x = node['x'];
      final y = node['y'];
      if (x is num && y is num) {
        node['y'] = fieldHeightMeters - y.toDouble();
      }

      for (final entry in node.entries) {
        final key = entry.key;
        final value = entry.value;

        if ((key == 'rotationDegrees' ||
                key == 'rotationOffset' ||
                key == 'heading') &&
            value is num) {
          node[key] = -value.toDouble();
        } else {
          visit(value);
        }
      }
    }

    visit(pathJson);
  }

  String? _teamKeyForCollabOverlayName(String overlayName) {
    for (final entry in _collabTeamGhostOverlayNames.entries) {
      if (entry.value == overlayName) {
        return entry.key;
      }
    }

    return null;
  }

  void _setCollabTeamAutoFlip(String teamKey, bool flipped) {
    setState(() {
      _collabTeamAutoFlipped[teamKey] = flipped;
    });

    _publishCollabSnapshot();

    try {
      _ghostOverlayDialogSetState?.call(() {});
    } catch (_) {
      _ghostOverlayDialogSetState = null;
    }
  }

  void _syncCollabTeamOverlayFromTeam(Map<String, dynamic> team) {
    final teamKey = team['key'];
    final autoRaw = team['auto'];

    if (teamKey is! String || teamKey.isEmpty || autoRaw is! Map) {
      return;
    }

    final auto = Map<String, dynamic>.from(autoRaw);
    final savedAutoName = auto['hostSavedAutoName']?.toString();

    if (savedAutoName == null || savedAutoName.isEmpty) {
      return;
    }

    final overlay = _ensureCollabSavedAutoGhostOverlay(
      teamKey: teamKey,
      savedAutoName: savedAutoName,
      color: team['color'],
    );

    if (overlay == null) {
      return;
    }

    auto['hostGhostOverlayName'] = overlay.name;
    auto['hostRenderedByGhostOverlay'] = true;
    auto['hostRuntimeSeconds'] = overlay.totalTimeSeconds;
    auto.remove('samples');
    auto.remove('segments');
    team['auto'] = auto;
  }

  void _setCollabTeamAutoVisible(String teamKey, bool visible) {
    setState(() {
      if (visible) {
        _hiddenCollabTeamAutoKeys.remove(teamKey);
      } else {
        _hiddenCollabTeamAutoKeys.add(teamKey);
      }

      final overlayName = _collabTeamGhostOverlayNames[teamKey];
      if (overlayName != null) {
        for (final overlay in _ghostOverlays) {
          if (overlay.name == overlayName) {
            overlay.visible = visible;
            break;
          }
        }
      }
    });

    _refreshPreviewDuration();
    _publishCollabSnapshot();

    try {
      _ghostOverlayDialogSetState?.call(() {});
    } catch (_) {
      _ghostOverlayDialogSetState = null;
    }
  }

  GhostAutoOverlay? _ensureCollabSavedAutoGhostOverlay({
    required String teamKey,
    required String savedAutoName,
    required Object? color,
  }) {
    final overlayColor = _collabColorFromHex(color);
    final existingOverlayName = _collabTeamGhostOverlayNames[teamKey];

    if (existingOverlayName != null) {
      final existingIndex = _ghostOverlays.indexWhere(
        (overlay) => overlay.name == existingOverlayName,
      );

      if (existingIndex >= 0 &&
          existingOverlayName == savedAutoName &&
          _ghostOverlays[existingIndex].color == overlayColor) {
        final existing = _ghostOverlays[existingIndex];
        existing.visible = !_hiddenCollabTeamAutoKeys.contains(teamKey);
        _refreshPreviewDuration();
        _publishCollabSnapshot();
        return existing;
      }

      if (existingIndex >= 0) {
        _ghostOverlays.removeAt(existingIndex);
      }

      _collabTeamGhostOverlayNames.remove(teamKey);
    }

    final autoFile = File(p.join(_collabAutosDir(), '$savedAutoName.auto'));
    final overlay = _buildExternalAutoOverlay(
      autoFile,
      displayNameOverride: savedAutoName,
      colorOverride: overlayColor,
    );

    if (overlay == null) {
      return null;
    }

    overlay.visible = !_hiddenCollabTeamAutoKeys.contains(teamKey);
    _ghostOverlays.add(overlay);
    _collabTeamGhostOverlayNames[teamKey] = overlay.name;
    _openTimingSectionId = overlay.name;

    _refreshPreviewDuration();
    _publishCollabSnapshot();

    return overlay;
  }

  List<Map<String, dynamic>> _visibleCollabTeamAutos() {
    final autos = <Map<String, dynamic>>[];

    for (final team in _collabTeamStates.values) {
      final key = team['key'];
      final auto = team['auto'];

      if (key is! String ||
          auto is! Map ||
          _hiddenCollabTeamAutoKeys.contains(key)) {
        continue;
      }

      autos.add({
        'key': key,
        'team': team,
        'auto': Map<String, dynamic>.from(auto),
        'color': team['color'],
      });
    }

    return autos;
  }

  Widget _buildBrowserTeamAutosCard() {
    final teamAutos = _collabTeamStates.values.where((team) {
      return team['auto'] is Map;
    }).toList();

    return Card(
      elevation: 0,
      child: ExpansionTile(
        dense: true,
        initiallyExpanded: teamAutos.isNotEmpty,
        title: const Text('Browser Team Autos'),
        subtitle: Text(
          teamAutos.isEmpty
              ? 'No uploaded browser autos yet.'
              : '${teamAutos.length} uploaded browser/local auto(s)',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          SwitchListTile(
            dense: true,
            value: _collabLocalOnlyTeamUploads,
            title: const Text('Local-only host imports'),
            subtitle: const Text(
              'Host file uploads are saved on this PC only and are not sent to browser clients.',
            ),
            onChanged: (value) {
              setState(() {
                _collabLocalOnlyTeamUploads = value;
              });
              try {
                _ghostOverlayDialogSetState?.call(() {});
              } catch (_) {
                _ghostOverlayDialogSetState = null;
              }
            },
          ),
          SwitchListTile(
            dense: true,
            value: _collabArchiveImportedFiles,
            title: const Text('Archive imported files on stop/change'),
            subtitle: const Text(
              'Moves temporary team auto/path files to deploy/pathplanner_collab_archive instead of leaving them in the project.',
            ),
            onChanged: (value) {
              setState(() {
                _collabArchiveImportedFiles = value;
              });
              try {
                _ghostOverlayDialogSetState?.call(() {});
              } catch (_) {
                _ghostOverlayDialogSetState = null;
              }
            },
          ),
          SwitchListTile(
            dense: true,
            value: _collabFlipUploadsBottomTop,
            title: const Text('Flip uploaded autos bottom/top before saving'),
            subtitle: const Text(
              'Mirrors uploaded path coordinates across the field Y axis before creating the host overlay.',
            ),
            onChanged: (value) {
              setState(() {
                _collabFlipUploadsBottomTop = value;
              });
              try {
                _ghostOverlayDialogSetState?.call(() {});
              } catch (_) {
                _ghostOverlayDialogSetState = null;
              }
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('Upload Local Team Auto'),
              onPressed: _collabLocalOnlyTeamUploads
                  ? _importLocalCollabTeamAuto
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          if (teamAutos.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Approved browser users can upload one auto per team. Local-only host imports can also be added above.',
                ),
              ),
            )
          else
            for (final team in teamAutos) _buildBrowserTeamAutoRow(team),
        ],
      ),
    );
  }

  Widget _buildBrowserTeamAutoRow(Map<String, dynamic> team) {
    final key = team['key'] as String? ?? 'Team';
    final auto = team['auto'];
    final autoMap = auto is Map
        ? Map<String, dynamic>.from(auto)
        : const <String, dynamic>{};
    final visible = !_hiddenCollabTeamAutoKeys.contains(key);
    final color = _collabColorFromHex(team['color']);
    final autoName = autoMap['name']?.toString() ?? 'Uploaded auto';
    final totalSeconds = (autoMap['totalSeconds'] is num)
        ? (autoMap['totalSeconds'] as num).toDouble()
        : 0.0;
    final hostSavedAutoName = autoMap['hostSavedAutoName']?.toString();
    final hostSavedPathCount = autoMap['hostSavedPathCount'];
    final hostRuntimeSeconds = autoMap['hostRuntimeSeconds'];
    final localOnly = autoMap['localOnly'] == true;
    final hostSaveError = autoMap['hostSaveError']?.toString();
    final flipped = _collabTeamAutoFlipped[key] == true;

    final subtitleParts = <String>[
      if (totalSeconds > 0.0 && hostRuntimeSeconds is! num)
        '${totalSeconds.toStringAsFixed(2)}s',
      if (localOnly) 'local only',
      '${team['claimedBy'] ?? 'browser upload'}',
      if (hostSavedAutoName != null && hostSavedAutoName.isNotEmpty)
        'saved as $hostSavedAutoName.auto',
      if (hostSavedPathCount is num)
        '${hostSavedPathCount.toInt()} path file(s)',
      if (autoMap['hostRenderedByGhostOverlay'] == true)
        'host PathPlanner overlay',
      if (hostRuntimeSeconds is num)
        'runtime ${hostRuntimeSeconds.toDouble().toStringAsFixed(2)}s',
      if (autoMap['constraintsFrozen'] == true) 'embedded constraints',
      if (flipped) 'bottom/top flipped',
      if (hostSaveError != null && hostSaveError.isNotEmpty)
        'save error: $hostSaveError',
      if (autoMap['hostGuiRenderError'] != null)
        'render error: ${autoMap['hostGuiRenderError']}',
    ];

    return Card(
      elevation: 0,
      child: Column(
        children: [
          CheckboxListTile(
            dense: true,
            value: visible,
            secondary: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            title: Text('$key - $autoName'),
            subtitle: Text(subtitleParts.join(' • ')),
            onChanged: (value) {
              _setCollabTeamAutoVisible(key, value == true);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    selected: flipped,
                    avatar: const Icon(Icons.flip_rounded, size: 18),
                    label: const Text('Flip bottom/top'),
                    onSelected: (value) {
                      _setCollabTeamAutoFlip(key, value);
                    },
                  ),
                  Chip(
                    avatar: Icon(Icons.circle, color: color, size: 14),
                    label: const Text('Overlay color'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _collabColorFromHex(Object? raw) {
    if (raw is! String || !raw.startsWith('#')) {
      return const Color(0xFFFF4FD8);
    }

    final hex = raw.substring(1);
    try {
      if (hex.length == 6) {
        return Color(0xFF000000 | int.parse(hex, radix: 16));
      }
      if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    } catch (_) {
      return const Color(0xFFFF4FD8);
    }

    return const Color(0xFFFF4FD8);
  }

  Future<void> _startCollabSession() async {
    if (!await _ensureCollabHostPassword()) {
      return;
    }

    await _publishCollabFieldImage();
    await _collabServer.start(
      hostPassword: _collabHostPasswordController.text.trim(),
      initialSnapshot: _buildCollabSnapshot(),
    );
    _publishCollabSnapshot();
    await _refreshCollabLanUrls();

    if (!mounted) {
      return;
    }

    final url = _primaryCollabLanUrl() ?? _collabUrl();
    if (url != null) {
      await Clipboard.setData(ClipboardData(text: url));
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          url == null
              ? 'Collaboration session started.'
              : 'Collaboration session started and URL copied: $url',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );

    setState(() {});
  }

  Future<void> _stopCollabSession() async {
    _archiveOrDeleteAllCollabImportedFiles();
    await _collabServer.stop();
    _collabLanUrls = [];

    if (!mounted) {
      return;
    }

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Collaboration session stopped.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _publishCollabSnapshot() {
    if (!_collabServer.isRunning) {
      return;
    }

    _collabServer.publishSnapshot(_buildCollabSnapshot());
  }

  String? _collabUrl() {
    final port = _collabServer.port;
    if (port == null) {
      return null;
    }

    return 'http://localhost:$port';
  }

  Map<String, dynamic> _buildCollabSnapshot() {
    final totalSeconds = _totalPreviewTimeSeconds();

    return {
      'hostAuto': widget.auto.name,
      'totalSeconds': totalSeconds,
      'fieldAspectRatio': widget.fieldImage.defaultSize.width /
          widget.fieldImage.defaultSize.height,
      'fieldImageVersion': _collabServer.fieldImageVersion,
      'fieldGeometry': {
        'pixelsPerMeter': widget.fieldImage.pixelsPerMeter,
        'marginMeters': widget.fieldImage.marginMeters,
        'widthPixels': widget.fieldImage.defaultSize.width,
        'heightPixels': widget.fieldImage.defaultSize.height,
      },
      'autos': [
        _buildCollabAutoSnapshot(
          name: widget.auto.name,
          role: 'Host',
          active: true,
          color: '#4f8cff',
          nativeSeconds: _mainNativeTimeSeconds(),
          totalSeconds: _mainTotalTimeSeconds(),
          pauses: _mainTimingPauses,
          trajectory: _simTraj,
        ),
        for (final overlay in _ghostOverlays)
          _buildCollabAutoSnapshot(
            name: overlay.name,
            role: 'Reference',
            active: overlay.visible,
            color:
                '#${overlay.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
            nativeSeconds: overlay.nativeTimeSeconds,
            totalSeconds: overlay.totalTimeSeconds,
            pauses: overlay.pauses,
            trajectory: overlay.trajectory,
            flipY: _collabTeamAutoFlipped[
                    _teamKeyForCollabOverlayName(overlay.name) ?? ''] ==
                true,
          ),
      ],
    };
  }

  Map<String, dynamic> _buildCollabAutoSnapshot({
    required String name,
    required String role,
    required bool active,
    required String color,
    required double nativeSeconds,
    required double totalSeconds,
    required List<GhostAutoPauseBlock> pauses,
    required PathPlannerTrajectory? trajectory,
    bool flipY = false,
  }) {
    return {
      'name': name,
      'role': role,
      'active': active,
      'color': color,
      'nativeSeconds': nativeSeconds,
      'totalSeconds': totalSeconds,
      'waitCount': pauses.length,
      'segments': _buildCollabTimelineSegments(
        nativeSeconds: nativeSeconds,
        pauses: pauses,
      ),
      'samples': _buildCollabRobotSamples(
        trajectory: trajectory,
        timelineSeconds: totalSeconds,
        nativeSeconds: nativeSeconds,
        pauses: pauses,
        flipY: flipY,
      ),
    };
  }

  List<Map<String, dynamic>> _buildCollabRobotSamples({
    required PathPlannerTrajectory? trajectory,
    required double timelineSeconds,
    required double nativeSeconds,
    required List<GhostAutoPauseBlock> pauses,
    bool flipY = false,
  }) {
    if (trajectory == null ||
        trajectory.states.isEmpty ||
        timelineSeconds <= 0.0 ||
        nativeSeconds <= 0.0) {
      return [];
    }

    final samples = <Map<String, dynamic>>[];
    const stepSeconds = 0.10;

    void addSample(double timelineTime) {
      final trajectoryTime = timelineSecondsToTrajectorySeconds(
        timelineSeconds: timelineTime,
        trajectoryDurationSeconds: nativeSeconds,
        pauses: pauses,
      );

      final state = trajectory.sample(trajectoryTime);
      final normalized = _normalizeFieldPoint(state.pose.translation);

      final normalizedY = (normalized['y'] ?? 0.0).toDouble();
      final theta = state.pose.rotation.radians.toDouble();

      samples.add({
        't': timelineTime,
        'x': normalized['x'],
        'y': flipY ? 1.0 - normalizedY : normalizedY,
        'theta': flipY ? -theta : theta,
      });
    }

    for (double t = 0.0; t <= timelineSeconds; t += stepSeconds) {
      addSample(t);
    }

    if (samples.isEmpty ||
        ((samples.last['t'] as num?)?.toDouble() ?? 0.0) < timelineSeconds) {
      addSample(timelineSeconds);
    }

    return samples;
  }

  Map<String, double> _normalizeFieldPoint(dynamic point) {
    final xMeters = (point.x as num).toDouble();
    final yMeters = (point.y as num).toDouble();
    final pixelsPerMeter = widget.fieldImage.pixelsPerMeter.toDouble();
    final width = widget.fieldImage.defaultSize.width.toDouble();
    final height = widget.fieldImage.defaultSize.height.toDouble();
    final margin = widget.fieldImage.marginMeters.toDouble();

    final xPixels = (xMeters + margin) * pixelsPerMeter;
    final yPixels = height - ((yMeters + margin) * pixelsPerMeter);

    return {
      'x': (xPixels / width).clamp(0.0, 1.0).toDouble(),
      'y': (yPixels / height).clamp(0.0, 1.0).toDouble(),
    };
  }

  List<Map<String, dynamic>> _buildCollabTimelineSegments({
    required double nativeSeconds,
    required List<GhostAutoPauseBlock> pauses,
  }) {
    final segments = <Map<String, dynamic>>[];
    final sortedPauses = List<GhostAutoPauseBlock>.of(pauses)
      ..sort((a, b) => a.afterSeconds.compareTo(b.afterSeconds));

    double autoSeconds = 0.0;
    double timelineSeconds = 0.0;

    void addSegment({
      required double startSeconds,
      required double durationSeconds,
      required String label,
      required String type,
    }) {
      if (!durationSeconds.isFinite || durationSeconds <= 0.0) {
        return;
      }

      segments.add({
        'startSeconds': startSeconds,
        'durationSeconds': durationSeconds,
        'label': label,
        'type': type,
        'isPause': type != 'drive',
      });
    }

    for (final pause in sortedPauses) {
      if (pause.durationSeconds <= 0.0) {
        continue;
      }

      if (pause.mode == GhostAutoPauseBlock.slowZoneMode) {
        final slowWindow = pause.slowWindowSeconds.clamp(
          0.05,
          nativeSeconds <= 0.0 ? 0.05 : nativeSeconds,
        );

        final center = pause.afterSeconds.clamp(0.0, nativeSeconds).toDouble();
        final nativeStart =
            (center - (slowWindow / 2.0)).clamp(0.0, nativeSeconds).toDouble();
        final nativeEnd =
            (center + (slowWindow / 2.0)).clamp(0.0, nativeSeconds).toDouble();
        final nativeDuration = nativeEnd - nativeStart;

        if (nativeStart > autoSeconds) {
          final driveDuration = nativeStart - autoSeconds;
          addSegment(
            startSeconds: timelineSeconds,
            durationSeconds: driveDuration,
            label: 'Driving',
            type: 'drive',
          );
          timelineSeconds += driveDuration;
          autoSeconds = nativeStart;
        }

        addSegment(
          startSeconds: timelineSeconds,
          durationSeconds: nativeDuration + pause.durationSeconds,
          label: pause.label,
          type: 'slow',
        );

        timelineSeconds += nativeDuration + pause.durationSeconds;
        autoSeconds = nativeEnd;
        continue;
      }

      final pauseAt = pause.afterSeconds.clamp(0.0, nativeSeconds).toDouble();

      if (pauseAt > autoSeconds) {
        final driveDuration = pauseAt - autoSeconds;
        addSegment(
          startSeconds: timelineSeconds,
          durationSeconds: driveDuration,
          label: 'Driving',
          type: 'drive',
        );
        timelineSeconds += driveDuration;
        autoSeconds = pauseAt;
      }

      addSegment(
        startSeconds: timelineSeconds,
        durationSeconds: pause.durationSeconds,
        label: pause.label,
        type: 'hold',
      );

      timelineSeconds += pause.durationSeconds;
    }

    if (nativeSeconds > autoSeconds) {
      addSegment(
        startSeconds: timelineSeconds,
        durationSeconds: nativeSeconds - autoSeconds,
        label: 'Driving',
        type: 'drive',
      );
    }

    return segments;
  }

  Widget _buildBrowserMarkupCard() {
    final colorScheme = Theme.of(context).colorScheme;
    final markups = _collabBrowserMarkups;

    return Card(
      elevation: 0,
      child: ExpansionTile(
        dense: true,
        initiallyExpanded: markups.isNotEmpty,
        title: const Text('Browser Markup'),
        subtitle: Text(
          markups.isEmpty
              ? 'No browser drawings yet.'
              : '${markups.length} browser drawing(s)',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          AspectRatio(
            aspectRatio: widget.fieldImage.defaultSize.width /
                widget.fieldImage.defaultSize.height,
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withAlpha(80),
                border: Border.all(color: colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: CustomPaint(
                painter: _CollabMarkupPainter(markups: markups),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleCollabMarkupsChanged(List<Map<String, dynamic>> markups) {
    if (!mounted) {
      return;
    }

    setState(() {
      _collabBrowserMarkups = markups;
    });

    try {
      _ghostOverlayDialogSetState?.call(() {});
    } catch (_) {
      _ghostOverlayDialogSetState = null;
    }
  }

  Future<void> _showGhostOverlayDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, dialogSetState) {
            _ghostOverlayDialogSetState = dialogSetState;
            final autoNames = _listExistingAutoNames();

            return AlertDialog(
              insetPadding: const EdgeInsets.all(12),
              title: const Text('Ghost Overlays'),
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.88,
                height: MediaQuery.of(context).size.height * 0.82,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    Text(
                      'Compare autos and add preview-only timing pauses. Host is always active. Up to two references can be active at once; extras stay benched.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    Card(
                      elevation: 0,
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          _collabServer.isRunning
                              ? Icons.wifi_tethering
                              : Icons.wifi_tethering_off,
                        ),
                        title: const Text('Collaboration Session'),
                        subtitle: Text(_collabSessionSubtitle()),
                        trailing: _collabServer.isRunning
                            ? Wrap(
                                spacing: 6,
                                children: [
                                  OutlinedButton(
                                    onPressed: _copyCollabLocalUrl,
                                    child: const Text('Copy Local'),
                                  ),
                                  if (_primaryCollabLanUrl() != null)
                                    OutlinedButton(
                                      onPressed: _copyCollabLanUrl,
                                      child: const Text('Copy LAN'),
                                    ),
                                  FilledButton(
                                    onPressed: () async {
                                      await _stopCollabSession();
                                      dialogSetState(() {});
                                    },
                                    child: const Text('Stop'),
                                  ),
                                ],
                              )
                            : FilledButton(
                                onPressed: () async {
                                  await _startCollabSession();
                                  dialogSetState(() {});
                                },
                                child: const Text('Start'),
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _showAddProjectAutoOverlayDialog(
                            autoNames,
                            dialogSetState,
                          ),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Add Project Auto'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _showAddExternalOverlayDialog(
                            dialogSetState,
                          ),
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('Add Reference File'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildBrowserMarkupCard(),
                    _buildBrowserTeamAutosCard(),
                    const SizedBox(height: 8),
                    Card(
                      elevation: 0,
                      child: ExpansionTile(
                        dense: true,
                        title: const Text('Active Match'),
                        subtitle: Text(
                          'Host + ${_activeReferenceOverlayCount()}/2 active references',
                        ),
                        initiallyExpanded: false,
                        childrenPadding: const EdgeInsets.fromLTRB(
                          8,
                          0,
                          8,
                          8,
                        ),
                        children: [
                          _buildActiveMatchSummaryCard(),
                        ],
                      ),
                    ),
                    Card(
                      elevation: 0,
                      child: ExpansionTile(
                        dense: true,
                        title: const Text('Match Timeline'),
                        subtitle: Text(
                          '${_totalPreviewTimeSeconds().toStringAsFixed(2)}s comparison timeline',
                        ),
                        initiallyExpanded: false,
                        childrenPadding: const EdgeInsets.fromLTRB(
                          8,
                          0,
                          8,
                          8,
                        ),
                        children: [
                          _buildComparisonTimelineSummary(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Timing pauses',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        Text(
                          '${_timingSectionIds().length} auto(s)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      child: ExpansionPanelList(
                        expansionCallback: (index, _) {
                          final id = _timingSectionIds()[index];
                          final isCurrentlyOpen = _openTimingSectionId == id;

                          setState(() {
                            _openTimingSectionId = isCurrentlyOpen ? '' : id;
                          });
                          dialogSetState(() {});
                        },
                        children: _buildTimingPanels(dialogSetState),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<String> _timingSectionIds() {
    return [
      _hostTimingId,
      for (final overlay in _ghostOverlays) overlay.name,
    ];
  }

  List<ExpansionPanel> _buildTimingPanels(StateSetter dialogSetState) {
    return [
      _buildTimingPanel(
        id: _hostTimingId,
        title: widget.auto.name,
        subtitle: 'Current host auto',
        color: Theme.of(context).colorScheme.primary,
        nativeSeconds: _mainNativeTimeSeconds(),
        totalSeconds: _mainTotalTimeSeconds(),
        pauses: _mainTimingPauses,
        anchors: _mainPauseAnchors(),
        dialogSetState: dialogSetState,
      ),
      for (final overlay in _ghostOverlays)
        _buildTimingPanel(
          id: overlay.name,
          title: overlay.name,
          subtitle: overlay.visible ? 'Active reference' : 'Bench reference',
          color: overlay.color,
          nativeSeconds: overlay.nativeTimeSeconds,
          totalSeconds: overlay.totalTimeSeconds,
          pauses: overlay.pauses,
          anchors: overlay.pauseAnchors,
          overlay: overlay,
          dialogSetState: dialogSetState,
        ),
    ];
  }

  ExpansionPanel _buildTimingPanel({
    required String id,
    required String title,
    required String subtitle,
    required Color color,
    required double nativeSeconds,
    required double totalSeconds,
    required List<GhostAutoPauseBlock> pauses,
    required List<GhostAutoPauseAnchor> anchors,
    required StateSetter dialogSetState,
    GhostAutoOverlay? overlay,
  }) {
    return ExpansionPanel(
      isExpanded: _openTimingSectionId == id,
      canTapOnHeader: true,
      headerBuilder: (context, isExpanded) {
        return ListTile(
          dense: true,
          leading: Icon(Icons.timer_outlined, color: color),
          title: Text(title, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '$subtitle • ${nativeSeconds.toStringAsFixed(2)}s native, '
            '${totalSeconds.toStringAsFixed(2)}s with pauses',
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          children: [
            if (overlay != null)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Active in Match'),
                value: overlay.visible,
                onChanged: (value) => _setReferenceOverlayActive(
                  overlay,
                  value,
                  dialogSetState,
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _pauseSummary(pauses),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _showPauseDialog(
                    overlay: overlay,
                    anchors: anchors,
                    dialogSetState: dialogSetState,
                  ),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add Wait'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (pauses.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'No timing waits added.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              for (final pause in pauses)
                Card(
                  elevation: 0,
                  child: ListTile(
                    dense: true,
                    title: Text(pause.label),
                    subtitle: Text(
                      '${pause.afterSeconds.toStringAsFixed(2)}s + '
                      '${pause.durationSeconds.toStringAsFixed(2)}s'
                      ' • ${_pauseModeLabel(pause)}'
                      '${pause.anchorLabel == null ? '' : ' • ${pause.anchorLabel}'}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Edit wait',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _showPauseDialog(
                            overlay: overlay,
                            anchors: anchors,
                            existingPause: pause,
                            dialogSetState: dialogSetState,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Delete wait',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() {
                              pauses.remove(pause);
                              _publishCollabSnapshot();
                            });
                            _refreshPreviewDuration();
                            dialogSetState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            if (overlay != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _ghostOverlays.remove(overlay);
                      _publishCollabSnapshot();
                      if (_openTimingSectionId == overlay.name) {
                        _openTimingSectionId = _hostTimingId;
                      }
                    });
                    _refreshPreviewDuration();
                    dialogSetState(() {});
                  },
                  icon: const Icon(Icons.layers_clear_outlined),
                  label: const Text('Remove Overlay'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPauseDialog({
    required List<GhostAutoPauseAnchor> anchors,
    GhostAutoOverlay? overlay,
    GhostAutoPauseBlock? existingPause,
    StateSetter? dialogSetState,
  }) async {
    final targetName = overlay?.name ?? widget.auto.name;
    final targetDuration =
        overlay?.nativeTimeSeconds ?? _mainNativeTimeSeconds();
    final pauses = overlay?.pauses ?? _mainTimingPauses;

    final initialAnchorId = existingPause?.anchorId ??
        (anchors.isNotEmpty ? anchors.last.id : _arbitraryAnchorId);

    final initialAnchor = anchors
        .where((anchor) => anchor.id == initialAnchorId)
        .cast<GhostAutoPauseAnchor?>()
        .firstOrNull;

    final labelController = TextEditingController(
      text: existingPause?.label ?? initialAnchor?.label ?? 'Shoot',
    );
    final afterController = TextEditingController(
      text: (existingPause?.afterSeconds ??
              initialAnchor?.seconds ??
              targetDuration)
          .toStringAsFixed(2),
    );
    final durationController = TextEditingController(
      text: (existingPause?.durationSeconds ?? 0.75).toStringAsFixed(2),
    );
    final slowWindowController = TextEditingController(
      text: (existingPause?.slowWindowSeconds ?? 1.0).toStringAsFixed(2),
    );

    String selectedMode = existingPause?.mode ?? GhostAutoPauseBlock.holdMode;
    String selectedAnchorId = initialAnchor?.id ?? _arbitraryAnchorId;

    final pause = await showDialog<GhostAutoPauseBlock>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final selectedAnchor = anchors
                .where((anchor) => anchor.id == selectedAnchorId)
                .cast<GhostAutoPauseAnchor?>()
                .firstOrNull;

            return AlertDialog(
              title: Text(
                existingPause == null
                    ? 'Add Timing Wait: $targetName'
                    : 'Edit Timing Wait: $targetName',
              ),
              content: SizedBox(
                width: 430,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Use an event marker from the auto, or choose arbitrary time and enter a specific time.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedAnchorId,
                      decoration: const InputDecoration(
                        labelText: 'Wait location',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: _arbitraryAnchorId,
                          child: Text('Arbitrary time'),
                        ),
                        for (final anchor in anchors)
                          DropdownMenuItem(
                            value: anchor.id,
                            child: Text(
                              '${anchor.label} (${anchor.seconds.toStringAsFixed(2)}s)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }

                        setDialogState(() {
                          selectedAnchorId = value;
                          final anchor = anchors
                              .where((item) => item.id == value)
                              .cast<GhostAutoPauseAnchor?>()
                              .firstOrNull;

                          if (anchor != null) {
                            afterController.text =
                                anchor.seconds.toStringAsFixed(2);
                            if (labelController.text.trim().isEmpty ||
                                labelController.text == 'Shoot' ||
                                labelController.text == 'Pause' ||
                                labelController.text ==
                                    existingPause?.anchorLabel) {
                              labelController.text = anchor.label;
                            }
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: labelController,
                      decoration: const InputDecoration(
                        labelText: 'Label',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: afterController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Wait at auto time, seconds',
                        helperText:
                            '0.00 to ${targetDuration.toStringAsFixed(2)}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: durationController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Added time, seconds',
                        helperText:
                            'Hold waits freeze. Slow zones stretch timing by this amount.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: selectedMode,
                      decoration: const InputDecoration(
                        labelText: 'Wait mode',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: GhostAutoPauseBlock.holdMode,
                          child: Text('Hold Wait'),
                        ),
                        DropdownMenuItem(
                          value: GhostAutoPauseBlock.slowZoneMode,
                          child: Text('Slow Zone'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }

                        setDialogState(() {
                          selectedMode = value;
                        });
                      },
                    ),
                    if (selectedMode == GhostAutoPauseBlock.slowZoneMode) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: slowWindowController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Slow zone window, seconds',
                          helperText:
                              'How much native auto time to stretch around the selected marker.',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (selectedAnchor != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Selected marker: ${selectedAnchor.label}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final afterSeconds = double.tryParse(afterController.text);
                    final durationSeconds =
                        double.tryParse(durationController.text);

                    if (afterSeconds == null ||
                        durationSeconds == null ||
                        durationSeconds <= 0.0) {
                      return;
                    }

                    final selectedAnchor = anchors
                        .where((anchor) => anchor.id == selectedAnchorId)
                        .cast<GhostAutoPauseAnchor?>()
                        .firstOrNull;
                    final slowWindowSeconds =
                        double.tryParse(slowWindowController.text) ?? 1.0;

                    Navigator.of(dialogContext).pop(
                      GhostAutoPauseBlock(
                        id: existingPause?.id ??
                            DateTime.now().microsecondsSinceEpoch.toString(),
                        afterSeconds:
                            afterSeconds.clamp(0.0, targetDuration).toDouble(),
                        durationSeconds: durationSeconds,
                        label: labelController.text.trim().isEmpty
                            ? 'Pause'
                            : labelController.text.trim(),
                        anchorId: selectedAnchor?.id,
                        anchorLabel: selectedAnchor?.label,
                        mode: selectedMode,
                        slowWindowSeconds: slowWindowSeconds.clamp(
                          0.05,
                          targetDuration <= 0.0 ? 0.05 : targetDuration,
                        ),
                      ),
                    );
                  },
                  child: Text(existingPause == null ? 'Add' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (pause == null || !mounted) {
      return;
    }

    setState(() {
      if (existingPause == null) {
        pauses.add(pause);
      } else {
        existingPause
          ..afterSeconds = pause.afterSeconds
          ..durationSeconds = pause.durationSeconds
          ..label = pause.label
          ..anchorId = pause.anchorId
          ..anchorLabel = pause.anchorLabel
          ..mode = pause.mode
          ..slowWindowSeconds = pause.slowWindowSeconds;
      }
    });

    _refreshPreviewDuration();
    dialogSetState?.call(() {});
  }

  List<GhostAutoPauseAnchor> _mainPauseAnchors() {
    if (widget.auto.choreoAuto && _simTraj != null) {
      return _anchorsForTrajectory(widget.auto.name, _simTraj!);
    }

    return _buildPauseAnchorsForPaths(widget.autoPaths);
  }

  List<GhostAutoPauseAnchor> _anchorsForTrajectory(
    String name,
    PathPlannerTrajectory trajectory,
  ) {
    final duration = trajectory.states.isEmpty
        ? 0.0
        : trajectory.states.last.timeSeconds.toDouble();

    return [
      GhostAutoPauseAnchor(
        id: '$name:start',
        label: '$name Start',
        seconds: 0.0,
      ),
      GhostAutoPauseAnchor(
        id: '$name:end',
        label: '$name End',
        seconds: duration,
      ),
    ];
  }

  List<GhostAutoPauseAnchor> _buildPauseAnchorsForPaths(
    List<PathPlannerPath> paths,
  ) {
    final anchors = <GhostAutoPauseAnchor>[];
    final config = RobotConfig.fromPrefs(widget.prefs);
    double timeOffset = 0.0;

    anchors.add(
      const GhostAutoPauseAnchor(
        id: 'auto:start',
        label: 'Auto Start',
        seconds: 0.0,
      ),
    );

    for (final path in paths) {
      PathPlannerTrajectory? pathTrajectory;
      try {
        pathTrajectory = PathPlannerTrajectory(
          path: path,
          robotConfig: config,
        );
      } catch (_) {
        pathTrajectory = null;
      }

      final pathDuration =
          pathTrajectory?.getTotalTimeSeconds().toDouble() ?? 0.0;

      for (final marker in path.eventMarkers) {
        final markerName = marker.name.toString().trim();
        if (markerName.isEmpty) {
          continue;
        }

        final markerTime = pathTrajectory == null
            ? 0.0
            : _timeForWaypointRelativePos(
                path: path,
                trajectory: pathTrajectory,
                waypointRelativePos: marker.waypointRelativePos.toDouble(),
              );

        anchors.add(
          GhostAutoPauseAnchor(
            id: '${path.name}:event:$markerName:${marker.waypointRelativePos}',
            label: '${path.name} / $markerName',
            seconds: timeOffset + markerTime,
          ),
        );
      }

      anchors.add(
        GhostAutoPauseAnchor(
          id: '${path.name}:end',
          label: '${path.name} End',
          seconds: timeOffset + pathDuration,
        ),
      );

      timeOffset += pathDuration;
    }

    anchors.add(
      GhostAutoPauseAnchor(
        id: 'auto:end',
        label: 'Auto End',
        seconds: timeOffset,
      ),
    );

    anchors.sort((a, b) => a.seconds.compareTo(b.seconds));
    return _dedupeAnchors(anchors);
  }

  List<GhostAutoPauseAnchor> _dedupeAnchors(
    List<GhostAutoPauseAnchor> anchors,
  ) {
    final seen = <String>{};
    final deduped = <GhostAutoPauseAnchor>[];

    for (final anchor in anchors) {
      final key = '${anchor.label}:${anchor.seconds.toStringAsFixed(2)}';
      if (seen.add(key)) {
        deduped.add(anchor);
      }
    }

    return deduped;
  }

  double _timeForWaypointRelativePos({
    required PathPlannerPath path,
    required PathPlannerTrajectory trajectory,
    required double waypointRelativePos,
  }) {
    if (path.pathPoints.isEmpty || trajectory.states.isEmpty) {
      return 0.0;
    }

    final maxIndex = path.pathPoints.length < trajectory.states.length
        ? path.pathPoints.length
        : trajectory.states.length;

    if (maxIndex <= 1) {
      return 0.0;
    }

    for (int i = 1; i < maxIndex; i++) {
      final prevPoint = path.pathPoints[i - 1];
      final point = path.pathPoints[i];

      final prevPos = prevPoint.waypointPos.toDouble();
      final pos = point.waypointPos.toDouble();

      if (waypointRelativePos <= pos) {
        final denom = pos - prevPos;
        final pct = denom.abs() < 1e-9
            ? 0.0
            : ((waypointRelativePos - prevPos) / denom).clamp(0.0, 1.0);

        final prevTime = trajectory.states[i - 1].timeSeconds.toDouble();
        final time = trajectory.states[i].timeSeconds.toDouble();

        return prevTime + ((time - prevTime) * pct);
      }
    }

    return trajectory.states.last.timeSeconds.toDouble();
  }

  Future<void> _showAddExternalOverlayDialog(
    StateSetter dialogSetState,
  ) async {
    const typeGroup = XTypeGroup(
      label: 'PathPlanner reference overlays',
      extensions: ['auto', 'path'],
    );

    final selectedFile = await openFile(
      acceptedTypeGroups: [typeGroup],
      initialDirectory: Directory.current.path,
    );

    if (selectedFile == null || !mounted) {
      return;
    }

    final overlay = _buildExternalGhostOverlay(selectedFile.path);

    if (overlay == null) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not add reference overlay. Check that the file exists and that referenced paths are available.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      if (_activeReferenceOverlayCount() >= 2) {
        overlay.visible = false;
      }
      _ghostOverlays.add(overlay);
      _publishCollabSnapshot();
      _openTimingSectionId = overlay.name;
    });
    _refreshPreviewDuration();
    dialogSetState(() {});
  }

  dynamic _decodeReferenceJson(File file) {
    final raw = file.readAsStringSync();

    try {
      return jsonDecode(raw);
    } on FormatException catch (err) {
      final repaired = _repairReferenceJson(raw);

      if (repaired == raw) {
        rethrow;
      }

      try {
        Log.warning(
          'Reference overlay JSON needed a small in-memory repair before previewing: ${file.path}',
        );
        return jsonDecode(repaired);
      } on FormatException catch (secondErr) {
        Log.warning(
          'Failed to decode reference JSON ${file.path}: $err / $secondErr',
        );
        rethrow;
      }
    }
  }

  String _repairReferenceJson(String raw) {
    var repaired = raw;

    // Some shared/generated files can contain a stray backslash at the end of a
    // line, for example "},\\". That is invalid JSON, but it is safe to ignore
    // for preview because it only acts like a bad line-continuation marker.
    //
    // Important: this must match a real newline, not the literal characters
    // "\\n", so keep the Dart regex as r'\\[ \t]*\r?\n'.
    repaired = repaired.replaceAll(RegExp(r'\\[ \t]*\r?\n'), '\n');

    return repaired;
  }

  GhostAutoOverlay? _buildExternalGhostOverlay(String rawPath) {
    final cleanedPath = rawPath.trim().replaceAll('"', '').replaceAll("'", '');

    final file = File(cleanedPath);
    if (!file.existsSync()) {
      return null;
    }

    final extension = p.extension(file.path).toLowerCase();

    if (extension == '.auto') {
      return _buildExternalAutoOverlay(file);
    }

    if (extension == '.path') {
      return _buildExternalPathOverlay(file);
    }

    Log.warning('Unsupported reference ghost overlay file: ${file.path}');
    return null;
  }

  GhostAutoOverlay? _buildExternalAutoOverlay(
    File autoFile, {
    String? displayNameOverride,
    Color? colorOverride,
  }) {
    try {
      final decoded = _decodeReferenceJson(autoFile);
      if (decoded is! Map) {
        return null;
      }

      final autoName = p.basenameWithoutExtension(autoFile.path);
      final displayName =
          displayNameOverride ?? _uniqueExternalOverlayName(autoName);
      final autoJson = Map<String, dynamic>.from(decoded);

      final auto = PathPlannerAuto.fromJson(
        autoJson,
        autoName,
        autoFile.parent.path,
        widget.auto.fs,
      );

      if (auto.choreoAuto) {
        Log.warning(
          'External Choreo autos are not supported by the host overlay MVP yet: ${autoFile.path}',
        );
        return null;
      }

      final paths = _resolveExternalPathPlannerPaths(
        auto.getAllPathNames(),
        autoFile,
      );

      if (paths.isEmpty) {
        return null;
      }

      final config = RobotConfig.fromPrefs(widget.prefs);
      final trajectory = AutoSimulator.simulateAuto(paths, config);

      if (trajectory == null) {
        return null;
      }

      if (trajectory.states.isEmpty ||
          !trajectory.getTotalTimeSeconds().isFinite) {
        return null;
      }

      return GhostAutoOverlay(
        name: displayName,
        trajectory: trajectory,
        color: colorOverride ??
            _ghostColors[_ghostOverlays.length % _ghostColors.length],
        pauseAnchors: _buildPauseAnchorsForPaths(paths),
      );
    } catch (err) {
      Log.warning(
          'Failed to add reference auto overlay ${autoFile.path}: $err');
      return null;
    }
  }

  GhostAutoOverlay? _buildExternalPathOverlay(File pathFile) {
    try {
      final decoded = _decodeReferenceJson(pathFile);
      if (decoded is! Map) {
        return null;
      }

      final pathName = p.basenameWithoutExtension(pathFile.path);
      final displayName = _uniqueExternalOverlayName(pathName);
      final pathJson = Map<String, dynamic>.from(decoded);

      final path = PathPlannerPath.fromJson(
        pathJson,
        pathName,
        pathFile.parent.path,
        widget.auto.fs,
      );
      path.lastModified = pathFile.lastModifiedSync().toUtc();

      final config = RobotConfig.fromPrefs(widget.prefs);
      final trajectory = AutoSimulator.simulateAuto([path], config);

      if (trajectory == null) {
        return null;
      }

      if (trajectory.states.isEmpty ||
          !trajectory.getTotalTimeSeconds().isFinite) {
        return null;
      }

      return GhostAutoOverlay(
        name: displayName,
        trajectory: trajectory,
        color: _ghostColors[_ghostOverlays.length % _ghostColors.length],
        pauseAnchors: _buildPauseAnchorsForPaths([path]),
      );
    } catch (err) {
      Log.warning(
          'Failed to add reference path overlay ${pathFile.path}: $err');
      return null;
    }
  }

  List<PathPlannerPath> _resolveExternalPathPlannerPaths(
    List pathNames,
    File autoFile,
  ) {
    final paths = <PathPlannerPath>[];

    for (final rawName in pathNames) {
      final pathName = rawName.toString();

      final externalPath = _findExternalPath(pathName, autoFile);
      if (externalPath != null) {
        paths.add(externalPath);
        continue;
      }

      final projectPath = _findPath(pathName);
      if (projectPath != null) {
        paths.add(projectPath);
      }
    }

    return paths;
  }

  PathPlannerPath? _findExternalPath(String pathName, File autoFile) {
    final autoDir = autoFile.parent;
    final pathplannerDir = autoDir.parent;

    final candidateDirs = <Directory>[
      Directory(p.join(pathplannerDir.path, 'paths')),
      Directory(p.normalize(p.join(autoDir.path, '..', 'paths'))),
      autoDir,
    ];

    final checkedDirs = <String>{};

    for (final dir in candidateDirs) {
      final normalizedDir = p.normalize(dir.path);
      if (!checkedDirs.add(normalizedDir)) {
        continue;
      }

      final file = File(p.join(normalizedDir, '$pathName.path'));
      if (!file.existsSync()) {
        continue;
      }

      try {
        final decoded = _decodeReferenceJson(file);
        if (decoded is! Map) {
          continue;
        }

        final pathJson = Map<String, dynamic>.from(decoded);
        final path = PathPlannerPath.fromJson(
          pathJson,
          pathName,
          normalizedDir,
          widget.auto.fs,
        );
        path.lastModified = file.lastModifiedSync().toUtc();
        return path;
      } catch (err) {
        Log.warning('Failed to load reference path ${file.path}: $err');
      }
    }

    return null;
  }

  String _uniqueExternalOverlayName(String baseName) {
    final existing = _ghostOverlays.map((overlay) => overlay.name).toSet();
    final cleanedBase = '$baseName (Reference)';

    if (!existing.contains(cleanedBase) && cleanedBase != widget.auto.name) {
      return cleanedBase;
    }

    int copyIndex = 2;
    while (existing.contains('$cleanedBase $copyIndex') ||
        '$cleanedBase $copyIndex' == widget.auto.name) {
      copyIndex++;
    }

    return '$cleanedBase $copyIndex';
  }

  Future<void> _addGhostOverlay(
    String autoName,
    StateSetter dialogSetState,
  ) async {
    final overlay = _buildGhostOverlay(autoName);

    if (overlay == null) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not generate ghost overlay for "$autoName"'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      if (_activeReferenceOverlayCount() >= 2) {
        overlay.visible = false;
      }
      _ghostOverlays.add(overlay);
      _publishCollabSnapshot();
      _openTimingSectionId = overlay.name;
    });
    dialogSetState(() {});
  }

  GhostAutoOverlay? _buildGhostOverlay(String autoName) {
    try {
      final autoFile = widget.auto.fs.file(
        p.join(widget.auto.autoDir, '$autoName.auto'),
      );

      if (!autoFile.existsSync()) {
        return null;
      }

      final decoded = _decodeReferenceJson(autoFile);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final auto = PathPlannerAuto.fromJson(
        decoded,
        autoName,
        widget.auto.autoDir,
        widget.auto.fs,
      );

      PathPlannerTrajectory? trajectory;
      List<GhostAutoPauseAnchor> anchors = [];

      if (auto.choreoAuto) {
        trajectory = _buildChoreoGhostTrajectory(auto);
        if (trajectory != null) {
          anchors = _anchorsForTrajectory(autoName, trajectory);
        }
      } else {
        final paths = _resolvePathPlannerPaths(auto.getAllPathNames());
        if (paths.isEmpty) {
          return null;
        }

        final config = RobotConfig.fromPrefs(widget.prefs);
        trajectory = AutoSimulator.simulateAuto(paths, config);
        anchors = _buildPauseAnchorsForPaths(paths);
      }

      if (trajectory == null) {
        return null;
      }

      final totalTimeSeconds = trajectory.getTotalTimeSeconds();
      if (trajectory.states.isEmpty || !totalTimeSeconds.isFinite) {
        return null;
      }

      final color = _ghostColors[_ghostOverlays.length % _ghostColors.length];

      return GhostAutoOverlay(
        name: autoName,
        trajectory: trajectory,
        color: color,
        pauseAnchors: anchors,
      );
    } catch (err) {
      Log.warning('Failed to build ghost overlay for $autoName: $err');
      return null;
    }
  }

  String _pauseModeLabel(GhostAutoPauseBlock pause) {
    if (pause.mode == GhostAutoPauseBlock.slowZoneMode) {
      return 'Slow Zone';
    }

    return 'Hold Wait';
  }

  String _pauseSummary(List<GhostAutoPauseBlock> pauses) {
    if (pauses.isEmpty) {
      return 'No timing waits';
    }

    final totalPauseSeconds = pauses.fold<double>(
      0.0,
      (sum, pause) => sum + pause.durationSeconds,
    );

    return '${pauses.length} wait(s), +${totalPauseSeconds.toStringAsFixed(2)}s';
  }

  PathPlannerTrajectory? _buildChoreoGhostTrajectory(PathPlannerAuto auto) {
    final states = <TrajectoryState>[];
    num timeOffset = 0.0;

    for (final pathName in auto.getAllPathNames()) {
      final choreoPath = _findChoreoPath(pathName.toString());
      if (choreoPath == null) {
        continue;
      }

      for (final state in choreoPath.trajectory.states) {
        states.add(state.copyWithTime(state.timeSeconds + timeOffset));
      }

      if (states.isNotEmpty) {
        timeOffset = states.last.timeSeconds;
      }
    }

    if (states.isEmpty) {
      return null;
    }

    return PathPlannerTrajectory.fromStates(states);
  }

  List<PathPlannerPath> _resolvePathPlannerPaths(List pathNames) {
    final paths = <PathPlannerPath>[];

    for (final rawName in pathNames) {
      final pathName = rawName.toString();
      final path = _findPath(pathName);
      if (path != null) {
        paths.add(path);
      }
    }

    return paths;
  }

  PathPlannerPath? _findPath(String pathName) {
    for (final path in widget.allPaths) {
      if (path.name == pathName) {
        return path;
      }
    }

    try {
      final file =
          widget.auto.fs.file(p.join(widget.pathDir, '$pathName.path'));
      if (!file.existsSync()) {
        return null;
      }

      final decoded = _decodeReferenceJson(file);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final path = PathPlannerPath.fromJson(
        decoded,
        pathName,
        widget.pathDir,
        widget.auto.fs,
      );
      path.lastModified = file.lastModifiedSync().toUtc();
      return path;
    } catch (_) {
      return null;
    }
  }

  ChoreoPath? _findChoreoPath(String pathName) {
    for (final path in widget.allChoreoPaths) {
      if (path.name == pathName) {
        return path;
      }
    }

    return null;
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

  void _simulateAuto() async {
    if (widget.autoPaths.isEmpty && widget.autoChoreoPaths.isEmpty) {
      setState(() {
        _simTraj = null;
      });
      _previewController.stop();
      _previewController.reset();
      return;
    }

    PathPlannerTrajectory? simPath;
    if (widget.auto.choreoAuto) {
      List<TrajectoryState> allStates = [];
      num timeOffset = 0.0;

      for (ChoreoPath p in widget.autoChoreoPaths) {
        for (TrajectoryState s in p.trajectory.states) {
          allStates.add(s.copyWithTime(s.timeSeconds + timeOffset));
        }

        if (allStates.isNotEmpty) {
          timeOffset = allStates.last.timeSeconds;
        }
      }

      if (allStates.isNotEmpty) {
        simPath = PathPlannerTrajectory.fromStates(allStates);
      }
    } else {
      RobotConfig config = RobotConfig.fromPrefs(widget.prefs);

      try {
        simPath = AutoSimulator.simulateAuto(
          widget.autoPaths.cast<PathPlannerPath>(),
          config,
        );

        if (!(simPath?.getTotalTimeSeconds().isFinite ?? false)) {
          simPath = null;
        }
      } catch (err) {
        Log.error('Failed to simulate auto', err);
      }
    }

    if (!mounted) {
      return;
    }

    if (simPath != null &&
        simPath.states.isNotEmpty &&
        simPath.states.last.timeSeconds.isFinite &&
        !simPath.states.last.timeSeconds.isNaN) {
      setState(() {
        _simTraj = simPath;
      });
      _publishCollabSnapshot();

      try {
        _setPreviewDurationForCurrentComparison(currentTrajectory: simPath);

        if (!_paused) {
          _previewController.stop();
          _previewController.reset();
          _previewController.repeat();
        } else {
          _previewController.stop();
        }
      } catch (_) {
        _showGenerationFailedError();
      }
    } else {
      _showGenerationFailedError();
    }
  }

  void _showGenerationFailedError() {
    Log.warning('Failed to generate trajectory for auto: ${widget.auto.name}');

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Failed to generate trajectory for ${widget.auto.name}. This is likely due to bad control point placement. Please adjust your control points to avoid kinks in the path.',
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
}

class _TimelineSegment {
  final double startSeconds;
  final double durationSeconds;
  final String label;
  final bool isPause;

  const _TimelineSegment({
    required this.startSeconds,
    required this.durationSeconds,
    required this.label,
    required this.isPause,
  });
}

class _CollabMarkupPainter extends CustomPainter {
  final List<Map<String, dynamic>> markups;

  const _CollabMarkupPainter({
    required this.markups,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 1.0;

    for (double x = 0; x <= size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    for (double y = 0; y <= size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    for (final entity in markups) {
      final pointsRaw = entity['points'];
      if (pointsRaw is! List || pointsRaw.length < 2) {
        continue;
      }

      final path = Path();
      var started = false;

      for (final pointRaw in pointsRaw) {
        if (pointRaw is! Map) {
          continue;
        }

        final xRaw = pointRaw['x'];
        final yRaw = pointRaw['y'];

        if (xRaw is! num || yRaw is! num) {
          continue;
        }

        final offset = Offset(
          xRaw.toDouble().clamp(0.0, 1.0) * size.width,
          yRaw.toDouble().clamp(0.0, 1.0) * size.height,
        );

        if (!started) {
          path.moveTo(offset.dx, offset.dy);
          started = true;
        } else {
          path.lineTo(offset.dx, offset.dy);
        }
      }

      if (!started) {
        continue;
      }

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = _readWidth(entity)
        ..color = _readColor(entity).withAlpha(220);

      canvas.drawPath(path, paint);
    }
  }

  static double _readWidth(Map<String, dynamic> entity) {
    final width = entity['width'];
    if (width is num) {
      return width.toDouble().clamp(1.0, 16.0);
    }

    return 5.0;
  }

  static Color _readColor(Map<String, dynamic> entity) {
    final raw = entity['color'];
    if (raw is! String || !raw.startsWith('#')) {
      return const Color(0xFFFF4FD8);
    }

    final hex = raw.substring(1);
    try {
      if (hex.length == 6) {
        return Color(0xFF000000 | int.parse(hex, radix: 16));
      }

      if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    } catch (_) {
      return const Color(0xFFFF4FD8);
    }

    return const Color(0xFFFF4FD8);
  }

  @override
  bool shouldRepaint(covariant _CollabMarkupPainter oldDelegate) {
    return oldDelegate.markups != markups;
  }
}

extension _FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull {
    if (isEmpty) {
      return null;
    }

    return first;
  }
}
