import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:file/file.dart';
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:path/path.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/named_command.dart';
import 'package:pathplanner/pages/auto_editor_page.dart';
import 'package:pathplanner/pages/choreo_path_editor_page.dart';
import 'package:pathplanner/pages/path_editor_page.dart';
import 'package:pathplanner/pages/project/project_item_card.dart';
import 'package:pathplanner/pages/project/auto_studio_page.dart';
import 'package:pathplanner/auto/pathplanner_auto.dart';
import 'package:pathplanner/path/choreo_path.dart';
import 'package:pathplanner/path/event_marker.dart';
import 'package:pathplanner/path/path_constraints.dart';
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/path/waypoint.dart';
import 'package:pathplanner/services/pplib_telemetry.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/util/wpimath/geometry.dart';
import 'package:pathplanner/widgets/conditional_widget.dart';
import 'package:pathplanner/widgets/dialogs/batch_path_export_dialog.dart';
import 'package:pathplanner/widgets/dialogs/management_dialog.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/renamable_title.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:undo/undo.dart';
import 'package:watcher/watcher.dart';
import 'package:pathplanner/commands/path_command.dart';

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

class ProjectPage extends StatefulWidget {
  static Set<String> events = {};

  final SharedPreferences prefs;
  final FieldImage fieldImage;
  final Directory pathplannerDirectory;
  final Directory choreoDirectory;
  final FileSystem fs;
  final ChangeStack undoStack;
  final bool shortcuts;
  final PPLibTelemetry? telemetry;
  final bool hotReload;
  final VoidCallback? onFoldersChanged;
  final bool simulatePath;
  final bool watchChorDir;

  // Stupid workaround to get when settings are updated
  static bool settingsUpdated = false;

  const ProjectPage({
    super.key,
    required this.prefs,
    required this.fieldImage,
    required this.pathplannerDirectory,
    required this.choreoDirectory,
    required this.fs,
    required this.undoStack,
    this.shortcuts = true,
    this.telemetry,
    this.hotReload = false,
    this.onFoldersChanged,
    this.simulatePath = false,
    this.watchChorDir = false,
  });

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  final MultiSplitViewController _controller = MultiSplitViewController();
  List<PathPlannerPath> _paths = [];
  List<String> _pathFolders = [];
  List<PathPlannerAuto> _autos = [];
  List<String> _autoFolders = [];
  List<ChoreoPath> _choreoPaths = [];
  late Directory _pathsDirectory;
  late Directory _autosDirectory;
  late Directory _choreoDirectory;
  late String _pathSortValue;
  late String _autoSortValue;
  late bool _pathsCompact;
  late bool _autosCompact;
  late int _pathGridCount;
  late int _autosGridCount;
  DirectoryWatcher? _chorWatcher;
  DirectoryWatcher? _pathsWatcher;
  DirectoryWatcher? _autosWatcher;
  StreamSubscription<WatchEvent>? _chorWatcherSub;
  StreamSubscription<WatchEvent>? _pathsWatcherSub;
  StreamSubscription<WatchEvent>? _autosWatcherSub;
  Timer? _pathplannerReloadTimer;
  bool _checkingPathplannerFiles = false;

  bool _bulkSelectPaths = false;
  bool _bulkSelectAutos = false;
  final Set<String> _selectedBulkPathNames = {};
  final Set<String> _selectedBulkAutoNames = {};
  final Set<String> _selectedBulkPathFolders = {};
  final Set<String> _selectedBulkAutoFolders = {};

  String _pathSearchQuery = '';
  String _autoSearchQuery = '';

  late TextEditingController _pathSearchController;
  late TextEditingController _autoSearchController;

  bool _loading = true;

  String? _pathFolder;
  String? _autoFolder;
  bool _inChoreoFolder = false;

  final GlobalKey _addAutoKey = GlobalKey();

  FileSystem get fs => widget.fs;

  @override
  void initState() {
    super.initState();

    _pathSearchController = TextEditingController();
    _autoSearchController = TextEditingController();

    double leftWeight = widget.prefs.getDouble(PrefsKeys.projectLeftWeight) ??
        Defaults.projectLeftWeight;
    _controller.areas = [
      Area(
        weight: leftWeight,
        minimalWeight: 0.33,
      ),
      Area(
        weight: 1.0 - leftWeight,
        minimalWeight: 0.33,
      ),
    ];

    _pathSortValue = widget.prefs.getString(PrefsKeys.pathSortOption) ??
        Defaults.pathSortOption;
    _autoSortValue = widget.prefs.getString(PrefsKeys.autoSortOption) ??
        Defaults.autoSortOption;
    _pathsCompact = widget.prefs.getBool(PrefsKeys.pathsCompactView) ??
        Defaults.pathsCompactView;
    _autosCompact = widget.prefs.getBool(PrefsKeys.autosCompactView) ??
        Defaults.autosCompactView;

    _pathGridCount = _getCrossAxisCountForWeight(leftWeight);
    _autosGridCount = _getCrossAxisCountForWeight(1.0 - leftWeight);

    _pathFolders = widget.prefs.getStringList(PrefsKeys.pathFolders) ??
        Defaults.pathFolders;
    _autoFolders = widget.prefs.getStringList(PrefsKeys.autoFolders) ??
        Defaults.autoFolders;

    // Set up choreo directory watcher
    if (widget.watchChorDir) {
      widget.choreoDirectory.exists().then((value) {
        if (value) {
          _chorWatcher = DirectoryWatcher(widget.choreoDirectory.path,
              pollingDelay: const Duration(seconds: 1));

          Timer? loadTimer;

          _chorWatcherSub = _chorWatcher!.events.listen((event) {
            loadTimer?.cancel();
            loadTimer = Timer(const Duration(milliseconds: 500), () {
              _load();
              if (mounted) {
                if (Navigator.of(this.context).canPop()) {
                  // We might have a path or auto open, close it
                  Navigator.of(this.context).pop();
                }

                ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('Reloaded Choreo paths')));
              }
            });
          });
        }
      });
    }

    _load();
  }

  @override
  void dispose() {
    _chorWatcherSub?.cancel();
    _pathsWatcherSub?.cancel();
    _autosWatcherSub?.cancel();
    _pathplannerReloadTimer?.cancel();

    _pathSearchController.dispose();
    _autoSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadFolderPrefsFromSettingsFile() async {
    final settingsFile =
        fs.file(join(widget.pathplannerDirectory.path, 'settings.json'));

    if (!await settingsFile.exists()) {
      return;
    }

    try {
      final decoded = jsonDecode(await settingsFile.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final pathFolders = (decoded[PrefsKeys.pathFolders] as List<dynamic>?)
          ?.whereType<String>()
          .toList();
      final autoFolders = (decoded[PrefsKeys.autoFolders] as List<dynamic>?)
          ?.whereType<String>()
          .toList();

      if (pathFolders != null) {
        await widget.prefs.setStringList(PrefsKeys.pathFolders, pathFolders);
      }
      if (autoFolders != null) {
        await widget.prefs.setStringList(PrefsKeys.autoFolders, autoFolders);
      }
    } catch (_) {
      // Ignore malformed settings here. The project loader will keep using prefs/defaults.
    }
  }

  void _ensurePathplannerWatchers() {
    _pathsWatcher ??= DirectoryWatcher(
      _pathsDirectory.path,
      pollingDelay: const Duration(seconds: 1),
    );
    _pathsWatcherSub ??= _pathsWatcher!.events.listen((_) {
      _schedulePathplannerReloadCheck();
    });

    _autosWatcher ??= DirectoryWatcher(
      _autosDirectory.path,
      pollingDelay: const Duration(seconds: 1),
    );
    _autosWatcherSub ??= _autosWatcher!.events.listen((_) {
      _schedulePathplannerReloadCheck();
    });
  }

  void _schedulePathplannerReloadCheck() {
    if (_loading) {
      return;
    }

    _pathplannerReloadTimer?.cancel();
    _pathplannerReloadTimer = Timer(
      const Duration(milliseconds: 500),
      _reloadIfPathplannerFilesChanged,
    );
  }

  Future<void> _reloadIfPathplannerFilesChanged() async {
    if (_checkingPathplannerFiles || _loading || !mounted) {
      return;
    }

    _checkingPathplannerFiles = true;
    try {
      if (!_pathplannerFilesChangedExternally()) {
        return;
      }

      _load();

      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          const SnackBar(
              content: Text('Reloaded external PathPlanner changes')),
        );
      }
    } finally {
      _checkingPathplannerFiles = false;
    }
  }

  bool _pathplannerFilesChangedExternally() {
    return _filesChangedExternally<PathPlannerPath>(
          directory: _pathsDirectory,
          extension: '.path',
          currentItems: _paths,
          itemName: (path) => path.name,
          itemLastModified: (path) => path.lastModified,
        ) ||
        _filesChangedExternally<PathPlannerAuto>(
          directory: _autosDirectory,
          extension: '.auto',
          currentItems: _autos,
          itemName: (auto) => auto.name,
          itemLastModified: (auto) => auto.lastModified,
        );
  }

  bool _filesChangedExternally<T>({
    required Directory directory,
    required String extension,
    required Iterable<T> currentItems,
    required String Function(T item) itemName,
    required DateTime Function(T item) itemLastModified,
  }) {
    final knownModifiedTimes = <String, DateTime>{
      for (final item in currentItems) itemName(item): itemLastModified(item),
    };

    final files = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith(extension))
        .toList();

    if (files.length != knownModifiedTimes.length) {
      return true;
    }

    for (final file in files) {
      final fileName = basenameWithoutExtension(file.path);
      final knownModifiedTime = knownModifiedTimes[fileName];
      if (knownModifiedTime == null) {
        return true;
      }

      final diskModifiedTime = file.lastModifiedSync().toUtc();
      final deltaMs = diskModifiedTime
          .difference(knownModifiedTime.toUtc())
          .inMilliseconds
          .abs();

      if (deltaMs > 1500) {
        return true;
      }
    }

    return false;
  }

  void _load() async {
    await _loadFolderPrefsFromSettingsFile();
    _pathFolders = widget.prefs.getStringList(PrefsKeys.pathFolders) ??
        Defaults.pathFolders;
    _autoFolders = widget.prefs.getStringList(PrefsKeys.autoFolders) ??
        Defaults.autoFolders;

    // Make sure dirs exist
    _pathsDirectory =
        fs.directory(join(widget.pathplannerDirectory.path, 'paths'));
    _pathsDirectory.createSync(recursive: true);
    _autosDirectory =
        fs.directory(join(widget.pathplannerDirectory.path, 'autos'));
    _autosDirectory.createSync(recursive: true);
    _choreoDirectory = fs.directory(widget.choreoDirectory);
    _ensurePathplannerWatchers();

    var paths =
        await PathPlannerPath.loadAllPathsInDir(_pathsDirectory.path, fs);
    var autos =
        await PathPlannerAuto.loadAllAutosInDir(_autosDirectory.path, fs);
    List<ChoreoPath> choreoPaths =
        await ChoreoPath.loadAllPathsInDir(_choreoDirectory.path, fs);

    List<String> allPathNames = [];
    for (PathPlannerPath path in paths) {
      allPathNames.add(path.name);
    }

    List<String> allChoreoPathNames = [];
    for (ChoreoPath path in choreoPaths) {
      allChoreoPathNames.add(path.name);
    }

    for (int i = 0; i < paths.length; i++) {
      if (!_pathFolders.contains(paths[i].folder)) {
        paths[i].folder = null;
      }
    }
    for (int i = 0; i < autos.length; i++) {
      if (!_autoFolders.contains(autos[i].folder)) {
        autos[i].folder = null;
      }

      autos[i].handleMissingPaths(
          autos[i].choreoAuto ? allChoreoPathNames : allPathNames);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _paths = paths;
      _autos = autos;
      _choreoPaths = choreoPaths;
      if (_pathFolder != null && !_pathFolders.contains(_pathFolder)) {
        _pathFolder = null;
      }
      if (_autoFolder != null && !_autoFolders.contains(_autoFolder)) {
        _autoFolder = null;
      }
      _inChoreoFolder = false;

      if (_paths.isEmpty) {
        _paths.add(PathPlannerPath.defaultPath(
          pathDir: _pathsDirectory.path,
          name: 'Example Path',
          fs: fs,
          constraints: _getDefaultConstraints(),
        ));
      }

      _sortPaths(_pathSortValue);
      _sortAutos(_autoSortValue);

      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    // Update _pathSortValue from shared preferences
    _pathSortValue = widget.prefs.getString(PrefsKeys.pathSortOption) ??
        Defaults.pathSortOption;

    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // Stupid workaround but it works
    if (ProjectPage.settingsUpdated) {
      PathConstraints defaultConstraints = _getDefaultConstraints();

      for (PathPlannerPath path in _paths) {
        if (path.useDefaultConstraints) {
          PathConstraints cloned = defaultConstraints.clone();
          cloned.unlimited = path.globalConstraints.unlimited;
          path.globalConstraints = cloned;
          path.generateAndSavePath();
        }
      }

      ProjectPage.settingsUpdated = false;
    }

    return Stack(
      children: [
        Container(
          color: colorScheme.surfaceTint.withAlpha(15),
          child: MultiSplitViewTheme(
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
                setState(() {
                  _pathGridCount =
                      _getCrossAxisCountForWeight(_controller.areas[0].weight!);
                  _autosGridCount = _getCrossAxisCountForWeight(
                      1.0 - _controller.areas[0].weight!);
                });
                widget.prefs.setDouble(PrefsKeys.projectLeftWeight,
                    _controller.areas[0].weight ?? Defaults.projectLeftWeight);
              },
              children: [
                _buildPathsGrid(context),
                _buildAutosGrid(context),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: FloatingActionButton(
              clipBehavior: Clip.antiAlias,
              tooltip: 'Manage Events & Linked Waypoints',
              backgroundColor: colorScheme.surface,
              foregroundColor: colorScheme.onSurface,
              onPressed: () => showDialog(
                context: this.context,
                builder: (BuildContext context) => ManagementDialog(
                  onEventRenamed: (String oldName, String newName) {
                    setState(() {
                      for (PathPlannerPath path in _paths) {
                        for (EventMarker m in path.eventMarkers) {
                          if (m.command != null) {
                            _replaceNamedCommand(oldName, newName, m.command!);
                          }
                          if (m.name == oldName) {
                            m.name = newName;
                          }
                        }
                        path.generateAndSavePath();
                      }

                      for (PathPlannerAuto auto in _autos) {
                        for (Command cmd in auto.sequence.commands) {
                          _replaceNamedCommand(oldName, newName, cmd);
                        }
                        auto.saveFile();
                      }
                    });
                  },
                  onEventDeleted: (String name) {
                    setState(() {
                      for (PathPlannerPath path in _paths) {
                        for (EventMarker m in path.eventMarkers) {
                          if (m.command != null) {
                            _replaceNamedCommand(name, null, m.command!);
                          }
                          if (m.name == name) {
                            m.name = '';
                          }
                        }
                        path.generateAndSavePath();
                      }

                      for (PathPlannerAuto auto in _autos) {
                        for (Command cmd in auto.sequence.commands) {
                          _replaceNamedCommand(name, null, cmd);
                        }
                        auto.saveFile();
                      }
                    });
                  },
                  onLinkedRenamed: (String oldName, String newName) {
                    setState(() {
                      Pose2d? pose = Waypoint.linked.remove(oldName);

                      if (pose != null) {
                        Waypoint.linked[newName] = pose;

                        for (PathPlannerPath path in _paths) {
                          bool changed = false;

                          for (Waypoint w in path.waypoints) {
                            if (w.linkedName == oldName) {
                              w.linkedName = newName;
                              changed = true;
                            }
                          }

                          if (changed) {
                            path.generateAndSavePath();
                          }
                        }
                      }
                    });
                  },
                  onLinkedDeleted: (String name) {
                    setState(() {
                      Waypoint.linked.remove(name);

                      for (PathPlannerPath path in _paths) {
                        bool changed = false;

                        for (Waypoint w in path.waypoints) {
                          if (w.linkedName == name) {
                            w.linkedName = null;
                            changed = true;
                          }
                        }

                        if (changed) {
                          path.generateAndSavePath();
                        }
                      }
                    });
                  },
                ),
              ),
              // Dumb hack to get an elevation surface tint
              child: Stack(
                children: [
                  Container(
                    color: colorScheme.surfaceTint.withAlpha(30),
                  ),
                  const Center(child: Icon(Icons.edit_note_rounded)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _replaceNamedCommand(
      String originalName, String? newName, Command command) {
    if (command is NamedCommand && command.name == originalName) {
      command.name = newName;
    } else if (command is CommandGroup) {
      for (Command cmd in command.commands) {
        _replaceNamedCommand(originalName, newName, cmd);
      }
    }
  }

  Widget _buildPathsGrid(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    if (_inChoreoFolder) {
      return Padding(
        padding: const EdgeInsets.only(left: 8.0, bottom: 8.0),
        child: Card(
          elevation: 0.0,
          margin: const EdgeInsets.all(0),
          color: colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildOptionsRow(
                  sortValue: _pathSortValue,
                  viewValue: _pathsCompact,
                  onSortChanged: (value) async {
                    await widget.prefs
                        .setString(PrefsKeys.pathSortOption, value);
                    setState(() {
                      _pathSortValue = value;
                      _sortPaths(_pathSortValue);
                    });
                  },
                  onViewChanged: (value) {
                    widget.prefs.setBool(PrefsKeys.pathsCompactView, value);
                    setState(() {
                      _pathsCompact = value;
                    });
                  },
                  onSearchChanged: (value) {
                    setState(() {
                      _pathSearchQuery = value;
                    });
                  },
                  searchController: _pathSearchController,
                  onAddFolder: () {
                    String folderName = 'New Folder';
                    while (_pathFolders.contains(folderName)) {
                      folderName = 'New $folderName';
                    }

                    setState(() {
                      _pathFolders.add(folderName);
                      _sortPaths(_pathSortValue);
                    });
                    widget.prefs
                        .setStringList(PrefsKeys.pathFolders, _pathFolders);
                    widget.onFoldersChanged?.call();
                  },
                  onAddItem: () {
                    List<String> pathNames = [];
                    for (PathPlannerPath path in _paths) {
                      pathNames.add(path.name);
                    }
                    String pathName = 'New Path';
                    while (pathNames.contains(pathName)) {
                      pathName = 'New $pathName';
                    }

                    setState(() {
                      _paths.add(PathPlannerPath.defaultPath(
                        pathDir: _pathsDirectory.path,
                        name: pathName,
                        fs: fs,
                        folder: _pathFolder,
                        constraints: _getDefaultConstraints(),
                      ));
                      _sortPaths(_pathSortValue);
                    });
                  },
                  isPathsView: true,
                ),
                GridView.count(
                  crossAxisCount: _pathGridCount,
                  childAspectRatio: 5.5,
                  shrinkWrap: true,
                  children: [
                    Card(
                      elevation: 2,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          setState(() {
                            _inChoreoFolder = false;
                          });
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8.0),
                          child: Row(
                            children: [
                              Icon(Icons.drive_file_move_rtl_outlined),
                              SizedBox(width: 12),
                              Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Root Folder',
                                    style: TextStyle(
                                      fontSize: 20,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: GridView.count(
                    crossAxisCount:
                        _pathsCompact ? _pathGridCount + 1 : _pathGridCount,
                    childAspectRatio: _pathsCompact ? 2.5 : 1.55,
                    children: [
                      for (int i = 0; i < _choreoPaths.length; i++)
                        _buildChoreoPathCard(i, context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8.0, top: 8.0),
      child: Card(
        elevation: 0.0,
        margin: const EdgeInsets.all(0),
        color: colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              const SizedBox(height: 8),
              _buildOptionsRow(
                sortValue: _pathSortValue,
                viewValue: _pathsCompact,
                onSortChanged: (value) {
                  widget.prefs.setString(PrefsKeys.pathSortOption, value);
                  setState(() {
                    _pathSortValue = value;
                    _sortPaths(_pathSortValue);
                  });
                },
                onViewChanged: (value) {
                  widget.prefs.setBool(PrefsKeys.pathsCompactView, value);
                  setState(() {
                    _pathsCompact = value;
                  });
                },
                onSearchChanged: (value) {
                  setState(() {
                    _pathSearchQuery = value;
                  });
                },
                searchController: _pathSearchController,
                onAddFolder: () {
                  String folderName = 'New Folder';
                  while (_pathFolders.contains(folderName)) {
                    folderName = 'New $folderName';
                  }

                  setState(() {
                    _pathFolders.add(folderName);
                    _sortPaths(_pathSortValue);
                  });
                  widget.prefs
                      .setStringList(PrefsKeys.pathFolders, _pathFolders);
                  widget.onFoldersChanged?.call();
                },
                onAddItem: () {
                  List<String> pathNames = [];
                  for (PathPlannerPath path in _paths) {
                    pathNames.add(path.name);
                  }
                  String pathName = 'New Path';
                  while (pathNames.contains(pathName)) {
                    pathName = 'New $pathName';
                  }

                  setState(() {
                    _paths.add(PathPlannerPath.defaultPath(
                      pathDir: _pathsDirectory.path,
                      name: pathName,
                      fs: fs,
                      folder: _pathFolder,
                      constraints: _getDefaultConstraints(),
                    ));
                    _sortPaths(_pathSortValue);
                  });
                },
                isPathsView: true,
              ),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ConditionalWidget(
                      condition: _pathFolder == null,
                      falseChild: GridView.count(
                        crossAxisCount: _pathGridCount,
                        childAspectRatio: 5.5,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          DragTarget<PathPlannerPath>(
                            onAcceptWithDetails: (details) {
                              setState(() {
                                details.data.folder = null;
                                details.data.generateAndSavePath();
                              });
                            },
                            builder: (context, candidates, rejects) {
                              ColorScheme colorScheme =
                                  Theme.of(context).colorScheme;
                              return Card(
                                elevation: 2,
                                color: candidates.isNotEmpty
                                    ? colorScheme.primary
                                    : colorScheme.surface,
                                surfaceTintColor: colorScheme.surfaceTint,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    setState(() {
                                      _pathFolder = null;
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8.0),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.drive_file_move_rtl_outlined,
                                          color: candidates.isNotEmpty
                                              ? colorScheme.onPrimary
                                              : null,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'Root Folder',
                                              style: TextStyle(
                                                fontSize: 20,
                                                color: candidates.isNotEmpty
                                                    ? colorScheme.onPrimary
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      trueChild: GridView.count(
                        crossAxisCount: _pathGridCount,
                        childAspectRatio: 5.5,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          if (_choreoPaths.isNotEmpty)
                            Card(
                              elevation: 2,
                              color: colorScheme.surface,
                              surfaceTintColor: colorScheme.surfaceTint,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () {
                                  setState(() {
                                    _inChoreoFolder = true;
                                  });
                                },
                                child: const Padding(
                                  padding:
                                      EdgeInsets.symmetric(horizontal: 8.0),
                                  child: Row(
                                    children: [
                                      Icon(Icons.folder_outlined),
                                      SizedBox(width: 12),
                                      Expanded(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            'Choreo Paths',
                                            style: TextStyle(
                                              fontSize: 20,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          for (int i = 0; i < _pathFolders.length; i++)
                            DragTarget<PathPlannerPath>(
                              onAcceptWithDetails: (details) {
                                setState(() {
                                  details.data.folder = _pathFolders[i];
                                  details.data.generateAndSavePath();
                                });
                              },
                              builder: (context, candidates, rejects) {
                                ColorScheme colorScheme =
                                    Theme.of(context).colorScheme;
                                return Card(
                                  elevation: 2,
                                  color: candidates.isNotEmpty
                                      ? colorScheme.primary
                                      : colorScheme.surface,
                                  surfaceTintColor: colorScheme.surfaceTint,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      if (_bulkSelectPaths) {
                                        _toggleBulkFolder(
                                          isPathsView: true,
                                          folderName: _pathFolders[i],
                                        );
                                        return;
                                      }

                                      setState(() {
                                        _pathFolder = _pathFolders[i];
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8.0),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.folder_outlined,
                                            color: candidates.isNotEmpty
                                                ? colorScheme.onPrimary
                                                : null,
                                          ),
                                          _buildFolderSelectionCheckbox(
                                            isPathsView: true,
                                            folderName: _pathFolders[i],
                                            color: candidates.isNotEmpty
                                                ? colorScheme.onPrimary
                                                : null,
                                          ),
                                          Expanded(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: RenamableTitle(
                                                title: _pathFolders[i],
                                                textStyle: TextStyle(
                                                  fontSize: 20,
                                                  color: candidates.isNotEmpty
                                                      ? colorScheme.onPrimary
                                                      : null,
                                                ),
                                                onRename: (newName) {
                                                  if (newName !=
                                                      _pathFolders[i]) {
                                                    if (_pathFolders
                                                        .contains(newName)) {
                                                      showDialog(
                                                          context: this.context,
                                                          builder: (BuildContext
                                                              context) {
                                                            ColorScheme
                                                                colorScheme =
                                                                Theme.of(
                                                                        context)
                                                                    .colorScheme;
                                                            return AlertDialog(
                                                              backgroundColor:
                                                                  colorScheme
                                                                      .surface,
                                                              surfaceTintColor:
                                                                  colorScheme
                                                                      .surfaceTint,
                                                              title: const Text(
                                                                  'Unable to Rename'),
                                                              content: Text(
                                                                  'The folder "$newName" already exists'),
                                                              actions: [
                                                                TextButton(
                                                                  onPressed:
                                                                      Navigator.of(
                                                                              context)
                                                                          .pop,
                                                                  child:
                                                                      const Text(
                                                                          'OK'),
                                                                ),
                                                              ],
                                                            );
                                                          });
                                                    } else {
                                                      setState(() {
                                                        for (PathPlannerPath path
                                                            in _paths) {
                                                          if (path.folder ==
                                                              _pathFolders[i]) {
                                                            path.folder =
                                                                newName;
                                                            path.generateAndSavePath();
                                                          }
                                                        }
                                                        _pathFolders[i] =
                                                            newName;
                                                      });
                                                      widget.prefs
                                                          .setStringList(
                                                              PrefsKeys
                                                                  .pathFolders,
                                                              _pathFolders);
                                                      widget.onFoldersChanged
                                                          ?.call();
                                                    }
                                                  }
                                                },
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                    if (_pathFolders.isNotEmpty || _choreoPaths.isNotEmpty)
                      const SizedBox(height: 8),
                    GridView.count(
                      crossAxisCount:
                          _pathsCompact ? _pathGridCount + 1 : _pathGridCount,
                      childAspectRatio: _pathsCompact ? 2.5 : 1.55,
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      children: [
                        for (int i = 0; i < _paths.length; i++)
                          if (_paths[i].folder == _pathFolder &&
                              _paths[i]
                                  .name
                                  .toLowerCase()
                                  .contains(_pathSearchQuery.toLowerCase()))
                            _buildPathCard(i, context),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _safeSaveAsName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return cleaned.replaceAll(RegExp(r'\s+'), ' ');
  }

  String _uniqueCopyName(String baseName, Set<String> existingNames) {
    final cleanedBase = _safeSaveAsName('$baseName Copy');
    if (!existingNames.contains(cleanedBase)) {
      return cleanedBase;
    }

    int copyIndex = 2;
    while (existingNames.contains('$cleanedBase $copyIndex')) {
      copyIndex++;
    }

    return '$cleanedBase $copyIndex';
  }

  Future<String?> _promptSaveAsName({
    required BuildContext context,
    required String title,
    required String initialName,
    required bool Function(String name) exists,
    required String extension,
  }) async {
    final controller = TextEditingController(text: initialName);
    controller.selection = TextSelection.fromPosition(
      TextPosition(offset: controller.text.length),
    );

    final rawName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Save As'),
            ),
          ],
        );
      },
    );

    // Do not dispose this immediately. Flutter may still rebuild the closing
    // dialog route for one frame after showDialog returns.

    if (rawName == null || rawName.trim().isEmpty) {
      return null;
    }

    final newName = _safeSaveAsName(rawName);
    if (newName.isEmpty) {
      return null;
    }

    if (exists(newName)) {
      _showSaveAsError(
        context,
        'The file "$newName$extension" already exists.',
      );
      return null;
    }

    return newName;
  }

  void _showSaveAsError(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          backgroundColor: colorScheme.surface,
          surfaceTintColor: colorScheme.surfaceTint,
          title: const Text('Unable to Save As'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: Navigator.of(dialogContext).pop,
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _ensurePathFolder(String folder) {
    if (folder.trim().isEmpty) {
      return;
    }

    if (!_pathFolders.contains(folder)) {
      _pathFolders.add(folder);
      _pathFolders.sort();
      widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
      widget.onFoldersChanged?.call();
    }
  }

  void _prefixLinkedWaypointsInJson(
    Map<String, dynamic> pathJson,
    String prefix,
  ) {
    final waypoints = pathJson['waypoints'];
    if (waypoints is! List) {
      return;
    }

    for (final waypoint in waypoints) {
      if (waypoint is! Map) {
        continue;
      }

      final linkedName = waypoint['linkedName'];
      if (linkedName is String &&
          linkedName.isNotEmpty &&
          !linkedName.startsWith(prefix)) {
        waypoint['linkedName'] = '$prefix$linkedName';
      }
    }
  }

  PathPlannerPath _copyPathFile({
    required String sourcePathName,
    required String newPathName,
    required String folder,
    required String linkedWaypointPrefix,
  }) {
    final src = fs.file(join(_pathsDirectory.path, '$sourcePathName.path'));
    final dst = fs.file(join(_pathsDirectory.path, '$newPathName.path'));

    if (!src.existsSync()) {
      throw StateError('Missing path file "$sourcePathName.path"');
    }

    if (dst.existsSync()) {
      throw StateError('The path "$newPathName.path" already exists.');
    }

    final decoded = jsonDecode(src.readAsStringSync());
    if (decoded is! Map) {
      throw StateError(
          'Path file "$sourcePathName.path" is not a JSON object.');
    }

    final pathJson = Map<String, dynamic>.from(decoded);
    pathJson['folder'] = folder;
    _prefixLinkedWaypointsInJson(pathJson, linkedWaypointPrefix);

    const encoder = JsonEncoder.withIndent('  ');
    dst.writeAsStringSync('${encoder.convert(pathJson)}\n');

    final copiedPath = PathPlannerPath.fromJson(
      pathJson,
      newPathName,
      _pathsDirectory.path,
      fs,
    );
    copiedPath.lastModified = dst.lastModifiedSync().toUtc();
    return copiedPath;
  }

  Future<void> _saveAsPath(PathPlannerPath source, BuildContext context) async {
    final pathNames = _paths.map((path) => path.name).toSet();

    final newName = await _promptSaveAsName(
      context: context,
      title: 'Save Path As',
      initialName: 'Copy Of ${source.name}',
      exists: pathNames.contains,
      extension: '.path',
    );

    if (newName == null) {
      return;
    }

    try {
      final copiedPath = _copyPathFile(
        sourcePathName: source.name,
        newPathName: newName,
        folder: source.folder ?? '',
        linkedWaypointPrefix: '${newName}_',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _paths.add(copiedPath);
        _sortPaths(_pathSortValue);
      });

      if (widget.hotReload) {
        widget.telemetry?.hotReloadPath(copiedPath);
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text('Saved path "$newName.path"'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      if (mounted) {
        _showSaveAsError(this.context, err.toString());
      }
    }
  }

  Future<void> _saveAsAuto(PathPlannerAuto source, BuildContext context) async {
    final autoNames = _autos.map((auto) => auto.name).toSet();

    final newName = await _promptSaveAsName(
      context: context,
      title: 'Save Auto As',
      initialName: 'Copy Of ${source.name}',
      exists: autoNames.contains,
      extension: '.auto',
    );

    if (newName == null) {
      return;
    }

    try {
      final copiedAuto = source.duplicate(newName);
      copiedAuto.folder = source.folder;

      if (!copiedAuto.choreoAuto) {
        final copiedPathFolder = newName;
        _ensurePathFolder(copiedPathFolder);

        final originalPathNames = <String>[];
        for (final pathName in source.getAllPathNames()) {
          if (!originalPathNames.contains(pathName)) {
            originalPathNames.add(pathName);
          }
        }

        final mapping = <String, String>{};
        final copiedPaths = <PathPlannerPath>[];

        for (final sourcePathName in originalPathNames) {
          final copiedPathName = _safeSaveAsName('$newName - $sourcePathName');
          final copiedPath = _copyPathFile(
            sourcePathName: sourcePathName,
            newPathName: copiedPathName,
            folder: copiedPathFolder,
            linkedWaypointPrefix: '${newName}_',
          );

          mapping[sourcePathName] = copiedPathName;
          copiedPaths.add(copiedPath);
        }

        _rewriteAutoPathNames(copiedAuto.sequence, mapping);

        setState(() {
          _paths.addAll(copiedPaths);
          _sortPaths(_pathSortValue);
        });
      }

      copiedAuto.saveFile();

      if (!mounted) {
        return;
      }

      setState(() {
        _autos.add(copiedAuto);
        _sortAutos(_autoSortValue);
      });

      if (widget.hotReload) {
        widget.telemetry?.hotReloadAuto(copiedAuto);
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text('Saved auto "$newName.auto"'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      if (mounted) {
        _showSaveAsError(this.context, err.toString());
      }
    }
  }

  void _rewriteAutoPathNames(Command command, Map<String, String> mapping) {
    void walk(Command cmd) {
      if (cmd is PathCommand && cmd.pathName != null) {
        cmd.pathName = mapping[cmd.pathName] ?? cmd.pathName;
      } else if (cmd is CommandGroup) {
        for (final child in cmd.commands) {
          walk(child);
        }
      }
    }

    walk(command);
  }

  void _duplicatePath(PathPlannerPath source) {
    final pathNames = _paths.map((path) => path.name).toSet();
    final newName = _uniqueCopyName(source.name, pathNames);

    try {
      final copiedPath = _copyPathFile(
        sourcePathName: source.name,
        newPathName: newName,
        folder: source.folder ?? '',
        linkedWaypointPrefix: '',
      );

      setState(() {
        _paths.add(copiedPath);
        _sortPaths(_pathSortValue);
      });

      if (widget.hotReload) {
        widget.telemetry?.hotReloadPath(copiedPath);
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text('Duplicated path "$newName.path"'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      _showSaveAsError(this.context, err.toString());
    }
  }

  void _duplicateAuto(PathPlannerAuto source) {
    final autoNames = _autos.map((auto) => auto.name).toSet();
    final newName = _uniqueCopyName(source.name, autoNames);

    try {
      final copiedAuto = source.duplicate(newName);
      copiedAuto.folder = source.folder;
      copiedAuto.saveFile();

      setState(() {
        _autos.add(copiedAuto);
        _sortAutos(_autoSortValue);
      });

      if (widget.hotReload) {
        widget.telemetry?.hotReloadAuto(copiedAuto);
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text('Duplicated auto "$newName.auto"'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      _showSaveAsError(this.context, err.toString());
    }
  }

  Widget _buildBulkActionsButton({required bool isPathsView}) {
    final active = _bulkSelectActive(isPathsView);

    return Tooltip(
      message: active ? 'Exit Multi Select' : 'Multi Select',
      child: IconButton(
        icon: Icon(
          Icons.checklist_rounded,
          color: active ? Theme.of(this.context).colorScheme.primary : null,
        ),
        onPressed: () {
          setState(() {
            if (isPathsView) {
              _bulkSelectPaths = !_bulkSelectPaths;

              if (!_bulkSelectPaths) {
                _clearBulkSelection(isPathsView: true);
              }
            } else {
              _bulkSelectAutos = !_bulkSelectAutos;

              if (!_bulkSelectAutos) {
                _clearBulkSelection(isPathsView: false);
              }
            }
          });
        },
      ),
    );
  }

  bool _bulkSelectActive(bool isPathsView) {
    return isPathsView ? _bulkSelectPaths : _bulkSelectAutos;
  }

  Set<String> _bulkSelectedItemNames({required bool isPathsView}) {
    return isPathsView ? _selectedBulkPathNames : _selectedBulkAutoNames;
  }

  Set<String> _bulkSelectedFolderNames({required bool isPathsView}) {
    return isPathsView ? _selectedBulkPathFolders : _selectedBulkAutoFolders;
  }

  void _clearBulkSelection({required bool isPathsView}) {
    _bulkSelectedItemNames(isPathsView: isPathsView).clear();
    _bulkSelectedFolderNames(isPathsView: isPathsView).clear();
  }

  void _setBulkItemSelected({
    required bool isPathsView,
    required String name,
    required bool selected,
  }) {
    setState(() {
      final selectedItems = _bulkSelectedItemNames(isPathsView: isPathsView);

      if (selected) {
        selectedItems.add(name);
      } else {
        selectedItems.remove(name);
      }
    });
  }

  void _toggleBulkItem({
    required bool isPathsView,
    required String name,
  }) {
    final selectedItems = _bulkSelectedItemNames(isPathsView: isPathsView);
    _setBulkItemSelected(
      isPathsView: isPathsView,
      name: name,
      selected: !selectedItems.contains(name),
    );
  }

  void _setBulkFolderSelected({
    required bool isPathsView,
    required String folderName,
    required bool selected,
  }) {
    setState(() {
      final selectedFolders =
          _bulkSelectedFolderNames(isPathsView: isPathsView);

      if (selected) {
        selectedFolders.add(folderName);
      } else {
        selectedFolders.remove(folderName);
      }
    });
  }

  void _toggleBulkFolder({
    required bool isPathsView,
    required String folderName,
  }) {
    final selectedFolders = _bulkSelectedFolderNames(isPathsView: isPathsView);
    _setBulkFolderSelected(
      isPathsView: isPathsView,
      folderName: folderName,
      selected: !selectedFolders.contains(folderName),
    );
  }

  Widget _buildFolderSelectionCheckbox({
    required bool isPathsView,
    required String folderName,
    required Color? color,
  }) {
    if (!_bulkSelectActive(isPathsView)) {
      return const SizedBox.shrink();
    }

    final selectedFolders = _bulkSelectedFolderNames(isPathsView: isPathsView);

    return SizedBox(
      width: 34,
      child: Checkbox(
        value: selectedFolders.contains(folderName),
        visualDensity: VisualDensity.compact,
        checkColor: color,
        side: color == null ? null : BorderSide(color: color),
        onChanged: (value) {
          _setBulkFolderSelected(
            isPathsView: isPathsView,
            folderName: folderName,
            selected: value ?? false,
          );
        },
      ),
    );
  }

  Widget _buildBulkActionsRow({required bool isPathsView}) {
    if (!_bulkSelectActive(isPathsView)) {
      return const SizedBox.shrink();
    }

    final selectedItems = _bulkSelectedItemNames(isPathsView: isPathsView);
    final selectedFolders = _bulkSelectedFolderNames(isPathsView: isPathsView);
    final selectionCount = selectedItems.length + selectedFolders.length;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            avatar: const Icon(Icons.check_circle_outline_rounded),
            label: Text('$selectionCount selected'),
          ),
          ActionChip(
            avatar: const Icon(Icons.select_all_rounded),
            label: const Text('Select All'),
            onPressed: () {
              setState(() {
                selectedItems
                  ..clear()
                  ..addAll(_visibleBulkItemNames(isPathsView: isPathsView));
                selectedFolders
                  ..clear()
                  ..addAll(_visibleBulkFolderNames(isPathsView: isPathsView));
              });
            },
          ),
          ActionChip(
            avatar: const Icon(Icons.clear_all_rounded),
            label: const Text('Clear'),
            onPressed: () {
              setState(() {
                _clearBulkSelection(isPathsView: isPathsView);
              });
            },
          ),
          ActionChip(
            avatar: const Icon(Icons.save_as_rounded),
            label: const Text('Save As'),
            onPressed: selectionCount == 0
                ? null
                : () async {
                    final itemSnapshot = Set<String>.from(selectedItems);
                    final folderSnapshot = Set<String>.from(selectedFolders);

                    await _saveAsBulkSelection(
                      isPathsView: isPathsView,
                      itemNames: itemSnapshot,
                      folderNames: folderSnapshot,
                    );

                    // Intentionally do not clear selection here. If the user
                    // cancels a Save As dialog, their current selection should
                    // stay intact. They can press Clear or toggle multi-select
                    // off when done.
                  },
          ),
          ActionChip(
            avatar: const Icon(Icons.copy_rounded),
            label: const Text('Duplicate'),
            onPressed: selectionCount == 0
                ? null
                : () async {
                    final itemSnapshot = Set<String>.from(selectedItems);
                    final folderSnapshot = Set<String>.from(selectedFolders);

                    final ok = await _confirmBulkAction(
                      title: 'Duplicate Selection',
                      message:
                          'Duplicate $selectionCount selected ${isPathsView ? 'path/folder' : 'auto/folder'} item(s)?',
                    );

                    if (!ok || !mounted) {
                      return;
                    }

                    _duplicateBulkSelection(
                      isPathsView: isPathsView,
                      itemNames: itemSnapshot,
                      folderNames: folderSnapshot,
                    );

                    if (mounted) {
                      setState(() {
                        _clearBulkSelection(isPathsView: isPathsView);
                      });
                    }
                  },
          ),
          ActionChip(
            avatar: const Icon(Icons.delete_outline_rounded),
            label: const Text('Delete'),
            onPressed: selectionCount == 0
                ? null
                : () async {
                    final itemSnapshot = Set<String>.from(selectedItems);
                    final folderSnapshot = Set<String>.from(selectedFolders);

                    final ok = await _confirmBulkAction(
                      title: 'Delete Selection',
                      message:
                          'Delete $selectionCount selected ${isPathsView ? 'path/folder' : 'auto/folder'} item(s)?\n\nDeleting a folder also deletes everything in that folder.',
                    );

                    if (!ok || !mounted) {
                      return;
                    }

                    _deleteBulkSelection(
                      isPathsView: isPathsView,
                      itemNames: itemSnapshot,
                      folderNames: folderSnapshot,
                    );

                    if (mounted) {
                      setState(() {
                        _clearBulkSelection(isPathsView: isPathsView);
                      });
                    }
                  },
          ),
        ],
      ),
    );
  }

  List<String> _visibleBulkItemNames({required bool isPathsView}) {
    if (isPathsView) {
      if (_inChoreoFolder) {
        return [];
      }

      final query = _pathSearchQuery.toLowerCase();
      final names = <String>[];

      for (final path in _paths) {
        if (path.folder == _pathFolder &&
            path.name.toLowerCase().contains(query)) {
          names.add(path.name);
        }
      }

      names.sort();
      return names;
    }

    final query = _autoSearchQuery.toLowerCase();
    final names = <String>[];

    for (final auto in _autos) {
      if (auto.folder == _autoFolder &&
          auto.name.toLowerCase().contains(query)) {
        names.add(auto.name);
      }
    }

    names.sort();
    return names;
  }

  List<String> _bulkFolderNames({required bool isPathsView}) {
    final folders =
        List<String>.from(isPathsView ? _pathFolders : _autoFolders);
    folders.sort();
    return folders;
  }

  PathPlannerPath? _pathByName(String name) {
    for (final path in _paths) {
      if (path.name == name) {
        return path;
      }
    }

    return null;
  }

  PathPlannerAuto? _autoByName(String name) {
    for (final auto in _autos) {
      if (auto.name == name) {
        return auto;
      }
    }

    return null;
  }

  String _uniqueFolderName(String baseName, Set<String> existingNames) {
    var cleanedBase = _safeSaveAsName('$baseName Copy');
    if (cleanedBase.isEmpty) {
      cleanedBase = 'Folder Copy';
    }

    if (!existingNames.contains(cleanedBase)) {
      return cleanedBase;
    }

    var copyIndex = 2;
    while (existingNames.contains('$cleanedBase $copyIndex')) {
      copyIndex++;
    }

    return '$cleanedBase $copyIndex';
  }

  Future<bool> _confirmBulkAction({
    required String title,
    required String message,
  }) async {
    return await showDialog<bool>(
          context: this.context,
          builder: (dialogContext) {
            final colorScheme = Theme.of(dialogContext).colorScheme;

            return AlertDialog(
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Continue'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<void> _showBulkActionsDialog({required bool isPathsView}) async {
    final selectedItems = <String>{};
    final selectedFolders = <String>{};

    Future<void> Function()? deferredAction;

    await showDialog<void>(
      context: this.context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final colorScheme = Theme.of(context).colorScheme;
            final itemNames = _visibleBulkItemNames(isPathsView: isPathsView);
            final folderNames = _bulkFolderNames(isPathsView: isPathsView);
            final selectionCount =
                selectedItems.length + selectedFolders.length;
            final canSaveAsSingle =
                selectedItems.length == 1 && selectedFolders.isEmpty;

            return AlertDialog(
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: Text(
                  isPathsView ? 'Multi Select Paths' : 'Multi Select Autos'),
              content: SizedBox(
                width: 560,
                height: 560,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          avatar: const Icon(Icons.select_all_rounded),
                          label: const Text('Select All Visible'),
                          onPressed: () {
                            setDialogState(() {
                              selectedItems
                                ..clear()
                                ..addAll(itemNames);
                            });
                          },
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.clear_all_rounded),
                          label: const Text('Clear'),
                          onPressed: () {
                            setDialogState(() {
                              selectedItems.clear();
                              selectedFolders.clear();
                            });
                          },
                        ),
                        Chip(
                          avatar:
                              const Icon(Icons.check_circle_outline_rounded),
                          label: Text('$selectionCount selected'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView(
                        children: [
                          if (folderNames.isNotEmpty) ...[
                            Text(
                              'Folders',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            for (final folderName in folderNames)
                              CheckboxListTile(
                                dense: true,
                                value: selectedFolders.contains(folderName),
                                secondary: const Icon(Icons.folder_outlined),
                                title: Text(folderName),
                                subtitle: Text(
                                  isPathsView
                                      ? '${_paths.where((path) => path.folder == folderName).length} path(s)'
                                      : '${_autos.where((auto) => auto.folder == folderName).length} auto(s)',
                                ),
                                onChanged: (value) {
                                  setDialogState(() {
                                    if (value == true) {
                                      selectedFolders.add(folderName);
                                    } else {
                                      selectedFolders.remove(folderName);
                                    }
                                  });
                                },
                              ),
                            const Divider(),
                          ],
                          Text(
                            isPathsView ? 'Visible Paths' : 'Visible Autos',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          if (itemNames.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                isPathsView && _inChoreoFolder
                                    ? 'Choreo paths are read-only here.'
                                    : 'No visible ${isPathsView ? 'paths' : 'autos'} match this view/search.',
                                style: TextStyle(
                                    color: colorScheme.onSurfaceVariant),
                              ),
                            ),
                          for (final itemName in itemNames)
                            CheckboxListTile(
                              dense: true,
                              value: selectedItems.contains(itemName),
                              secondary: Icon(
                                isPathsView
                                    ? Icons.route_rounded
                                    : Icons.auto_mode_rounded,
                              ),
                              title: Text(itemName),
                              onChanged: (value) {
                                setDialogState(() {
                                  if (value == true) {
                                    selectedItems.add(itemName);
                                  } else {
                                    selectedItems.remove(itemName);
                                  }
                                });
                              },
                            ),
                        ],
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
                TextButton.icon(
                  icon: const Icon(Icons.save_as_rounded),
                  label: const Text('Save As'),
                  onPressed: !canSaveAsSingle
                      ? null
                      : () {
                          final name = selectedItems.single;
                          deferredAction = () async {
                            if (isPathsView) {
                              final path = _pathByName(name);
                              if (path != null) {
                                await _saveAsPath(path, this.context);
                              }
                            } else {
                              final auto = _autoByName(name);
                              if (auto != null) {
                                await _saveAsAuto(auto, this.context);
                              }
                            }
                          };
                          Navigator.of(dialogContext).pop();
                        },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Duplicate'),
                  onPressed: selectionCount == 0
                      ? null
                      : () async {
                          final ok = await _confirmBulkAction(
                            title: 'Duplicate Selection',
                            message:
                                'Duplicate $selectionCount selected ${isPathsView ? 'path/folder' : 'auto/folder'} item(s)?',
                          );
                          if (!ok || !mounted) {
                            return;
                          }

                          _duplicateBulkSelection(
                            isPathsView: isPathsView,
                            itemNames: selectedItems,
                            folderNames: selectedFolders,
                          );
                          Navigator.of(dialogContext).pop();
                        },
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Delete'),
                  onPressed: selectionCount == 0
                      ? null
                      : () async {
                          final ok = await _confirmBulkAction(
                            title: 'Delete Selection',
                            message:
                                'Delete $selectionCount selected ${isPathsView ? 'path/folder' : 'auto/folder'} item(s)?\n\nDeleting a folder also deletes everything in that folder.',
                          );
                          if (!ok || !mounted) {
                            return;
                          }

                          _deleteBulkSelection(
                            isPathsView: isPathsView,
                            itemNames: selectedItems,
                            folderNames: selectedFolders,
                          );
                          Navigator.of(dialogContext).pop();
                        },
                ),
              ],
            );
          },
        );
      },
    );

    if (deferredAction != null && mounted) {
      await deferredAction!.call();
    }
  }

  List<String> _visibleBulkFolderNames({required bool isPathsView}) {
    if (isPathsView) {
      if (_inChoreoFolder || _pathFolder != null) {
        return [];
      }

      return List<String>.from(_pathFolders)..sort();
    }

    if (_autoFolder != null) {
      return [];
    }

    return List<String>.from(_autoFolders)..sort();
  }

  String _uniqueCopyOfName(String baseName, Set<String> existingNames) {
    var cleanedBase = _safeSaveAsName('Copy Of $baseName');
    if (cleanedBase.isEmpty) {
      cleanedBase = 'Copy Of File';
    }

    if (!existingNames.contains(cleanedBase)) {
      return cleanedBase;
    }

    var copyIndex = 2;
    while (existingNames.contains('$cleanedBase $copyIndex')) {
      copyIndex++;
    }

    return '$cleanedBase $copyIndex';
  }

  String _formatPreviewLines(List<String> previewLines) {
    if (previewLines.isEmpty) {
      return 'No files will be copied.';
    }

    const maxPreviewLines = 18;
    final visibleLines = previewLines.take(maxPreviewLines).join('\n');
    final hiddenCount = previewLines.length - maxPreviewLines;

    if (hiddenCount <= 0) {
      return visibleLines;
    }

    return '$visibleLines\n...and $hiddenCount more';
  }

  List<String> _pathFolderSaveAsPreview({
    required String sourceFolder,
    required String newFolder,
  }) {
    final existingPathNames = _paths.map<String>((path) => path.name).toSet();
    final preview = <String>['Folder: $sourceFolder -> $newFolder'];

    final sourcePaths = _paths
        .where((path) => path.folder == sourceFolder)
        .cast<PathPlannerPath>()
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final sourcePath in sourcePaths) {
      final newName = _uniqueCopyOfName(sourcePath.name, existingPathNames);
      existingPathNames.add(newName);
      preview.add('  ${sourcePath.name}.path -> $newName.path');
    }

    return preview;
  }

  List<String> _autoFolderSaveAsPreview({
    required String sourceFolder,
    required String newFolder,
  }) {
    final existingAutoNames = _autos.map<String>((auto) => auto.name).toSet();
    final preview = <String>['Folder: $sourceFolder -> $newFolder'];

    final sourceAutos = _autos
        .where((auto) => auto.folder == sourceFolder)
        .cast<PathPlannerAuto>()
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final sourceAuto in sourceAutos) {
      final newName = _uniqueCopyOfName(sourceAuto.name, existingAutoNames);
      existingAutoNames.add(newName);
      preview.add('  ${sourceAuto.name}.auto -> $newName.auto');
    }

    return preview;
  }

  List<String> _pathSelectionSaveAsPreview({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    final existingPathNames = _paths.map<String>((path) => path.name).toSet();
    final existingFolderNames = _pathFolders.toSet();
    final preview = <String>[];

    final sortedFolders = folderNames.toList()..sort();
    for (final sourceFolder in sortedFolders) {
      final newFolder = _uniqueCopyOfName(sourceFolder, existingFolderNames);
      existingFolderNames.add(newFolder);
      preview.add('Folder: $sourceFolder -> $newFolder');

      final sourcePaths = _paths
          .where((path) => path.folder == sourceFolder)
          .cast<PathPlannerPath>()
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      for (final sourcePath in sourcePaths) {
        final newName = _uniqueCopyOfName(sourcePath.name, existingPathNames);
        existingPathNames.add(newName);
        preview.add('  ${sourcePath.name}.path -> $newName.path');
      }
    }

    final sortedItems = itemNames.toList()..sort();
    for (final itemName in sortedItems) {
      final sourcePath = _pathByName(itemName);
      if (sourcePath == null || folderNames.contains(sourcePath.folder)) {
        continue;
      }

      final newName = _uniqueCopyOfName(sourcePath.name, existingPathNames);
      existingPathNames.add(newName);
      preview.add('${sourcePath.name}.path -> $newName.path');
    }

    return preview;
  }

  List<String> _autoSelectionSaveAsPreview({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    final existingAutoNames = _autos.map<String>((auto) => auto.name).toSet();
    final existingFolderNames = _autoFolders.toSet();
    final preview = <String>[];

    final sortedFolders = folderNames.toList()..sort();
    for (final sourceFolder in sortedFolders) {
      final newFolder = _uniqueCopyOfName(sourceFolder, existingFolderNames);
      existingFolderNames.add(newFolder);
      preview.add('Folder: $sourceFolder -> $newFolder');

      final sourceAutos = _autos
          .where((auto) => auto.folder == sourceFolder)
          .cast<PathPlannerAuto>()
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      for (final sourceAuto in sourceAutos) {
        final newName = _uniqueCopyOfName(sourceAuto.name, existingAutoNames);
        existingAutoNames.add(newName);
        preview.add('  ${sourceAuto.name}.auto -> $newName.auto');
      }
    }

    final sortedItems = itemNames.toList()..sort();
    for (final itemName in sortedItems) {
      final sourceAuto = _autoByName(itemName);
      if (sourceAuto == null || folderNames.contains(sourceAuto.folder)) {
        continue;
      }

      final newName = _uniqueCopyOfName(sourceAuto.name, existingAutoNames);
      existingAutoNames.add(newName);
      preview.add('${sourceAuto.name}.auto -> $newName.auto');
    }

    return preview;
  }

  Future<void> _saveAsBulkSelection({
    required bool isPathsView,
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) async {
    if (itemNames.length == 1 && folderNames.isEmpty) {
      final name = itemNames.single;

      if (isPathsView) {
        final path = _pathByName(name);
        if (path != null) {
          await _saveAsPath(path, this.context);
        }
      } else {
        final auto = _autoByName(name);
        if (auto != null) {
          await _saveAsAuto(auto, this.context);
        }
      }

      return;
    }

    if (folderNames.length == 1 && itemNames.isEmpty) {
      await _saveAsBulkFolder(
        isPathsView: isPathsView,
        sourceFolder: folderNames.single,
      );
      return;
    }

    await _saveAsBulkSelectionCopies(
      isPathsView: isPathsView,
      itemNames: itemNames,
      folderNames: folderNames,
    );
  }

  Future<void> _saveAsBulkFolder({
    required bool isPathsView,
    required String sourceFolder,
  }) async {
    final existingFolders =
        isPathsView ? _pathFolders.toSet() : _autoFolders.toSet();

    final newFolder = await _promptSaveAsName(
      context: this.context,
      title: isPathsView ? 'Save Path Folder As' : 'Save Auto Folder As',
      initialName: 'Copy Of $sourceFolder',
      exists: existingFolders.contains,
      extension: '',
    );

    if (newFolder == null) {
      return;
    }

    final previewLines = isPathsView
        ? _pathFolderSaveAsPreview(
            sourceFolder: sourceFolder,
            newFolder: newFolder,
          )
        : _autoFolderSaveAsPreview(
            sourceFolder: sourceFolder,
            newFolder: newFolder,
          );

    final ok = await _confirmBulkAction(
      title: 'Save Folder As',
      message:
          'This will create the following ${isPathsView ? 'path' : 'auto'} folder copy:\n\n${_formatPreviewLines(previewLines)}',
    );

    if (!ok || !mounted) {
      return;
    }

    if (isPathsView) {
      await _saveAsPathFolderCopy(
        sourceFolder: sourceFolder,
        newFolder: newFolder,
      );
    } else {
      await _saveAsAutoFolderCopy(
        sourceFolder: sourceFolder,
        newFolder: newFolder,
      );
    }
  }

  Future<void> _saveAsBulkSelectionCopies({
    required bool isPathsView,
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) async {
    final selectionCount = itemNames.length + folderNames.length;
    final previewLines = isPathsView
        ? _pathSelectionSaveAsPreview(
            itemNames: itemNames,
            folderNames: folderNames,
          )
        : _autoSelectionSaveAsPreview(
            itemNames: itemNames,
            folderNames: folderNames,
          );

    final ok = await _confirmBulkAction(
      title: 'Save Selection As',
      message:
          'This will save $selectionCount selected ${isPathsView ? 'path/folder' : 'auto/folder'} item(s) as:\n\n${_formatPreviewLines(previewLines)}',
    );

    if (!ok || !mounted) {
      return;
    }

    if (isPathsView) {
      await _saveAsPathSelectionCopies(
        itemNames: itemNames,
        folderNames: folderNames,
      );
    } else {
      await _saveAsAutoSelectionCopies(
        itemNames: itemNames,
        folderNames: folderNames,
      );
    }
  }

  Future<void> _saveAsPathSelectionCopies({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) async {
    try {
      final existingPathNames = _paths.map<String>((path) => path.name).toSet();
      final existingFolderNames = _pathFolders.toSet();
      final copiedPaths = <PathPlannerPath>[];
      final newFolders = <String>[];

      final sortedFolders = folderNames.toList()..sort();
      for (final sourceFolder in sortedFolders) {
        final newFolder = _uniqueCopyOfName(sourceFolder, existingFolderNames);
        existingFolderNames.add(newFolder);
        newFolders.add(newFolder);

        final sourcePaths = _paths
            .where((path) => path.folder == sourceFolder)
            .cast<PathPlannerPath>()
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

        for (final sourcePath in sourcePaths) {
          final newName = _uniqueCopyOfName(sourcePath.name, existingPathNames);
          existingPathNames.add(newName);

          copiedPaths.add(
            _copyPathFile(
              sourcePathName: sourcePath.name,
              newPathName: newName,
              folder: newFolder,
              linkedWaypointPrefix: '${newName}_',
            ),
          );
        }
      }

      final sortedItems = itemNames.toList()..sort();
      for (final itemName in sortedItems) {
        final sourcePath = _pathByName(itemName);
        if (sourcePath == null || folderNames.contains(sourcePath.folder)) {
          continue;
        }

        final newName = _uniqueCopyOfName(sourcePath.name, existingPathNames);
        existingPathNames.add(newName);

        copiedPaths.add(
          _copyPathFile(
            sourcePathName: sourcePath.name,
            newPathName: newName,
            folder: sourcePath.folder ?? '',
            linkedWaypointPrefix: '${newName}_',
          ),
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _pathFolders.addAll(newFolders);
        _pathFolders.sort();
        _paths.addAll(copiedPaths);
        _sortPaths(_pathSortValue);
      });

      widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
      widget.onFoldersChanged?.call();

      for (final path in copiedPaths) {
        if (widget.hotReload) {
          widget.telemetry?.hotReloadPath(path);
        }
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${copiedPaths.length} path copy/copies'
            '${newFolders.isEmpty ? '' : ' in ${newFolders.length} copied folder(s)'}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      if (mounted) {
        _showSaveAsError(this.context, err.toString());
      }
    }
  }

  Future<void> _saveAsAutoSelectionCopies({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) async {
    try {
      final existingAutoNames = _autos.map<String>((auto) => auto.name).toSet();
      final existingFolderNames = _autoFolders.toSet();
      final copiedAutos = <PathPlannerAuto>[];
      final newFolders = <String>[];

      final sortedFolders = folderNames.toList()..sort();
      for (final sourceFolder in sortedFolders) {
        final newFolder = _uniqueCopyOfName(sourceFolder, existingFolderNames);
        existingFolderNames.add(newFolder);
        newFolders.add(newFolder);

        final sourceAutos = _autos
            .where((auto) => auto.folder == sourceFolder)
            .cast<PathPlannerAuto>()
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

        for (final sourceAuto in sourceAutos) {
          final newName = _uniqueCopyOfName(sourceAuto.name, existingAutoNames);
          existingAutoNames.add(newName);

          final copiedAuto = sourceAuto.duplicate(newName);
          copiedAuto.folder = newFolder;
          copiedAuto.saveFile();
          copiedAutos.add(copiedAuto);
        }
      }

      final sortedItems = itemNames.toList()..sort();
      for (final itemName in sortedItems) {
        final sourceAuto = _autoByName(itemName);
        if (sourceAuto == null || folderNames.contains(sourceAuto.folder)) {
          continue;
        }

        final newName = _uniqueCopyOfName(sourceAuto.name, existingAutoNames);
        existingAutoNames.add(newName);

        final copiedAuto = sourceAuto.duplicate(newName);
        copiedAuto.folder = sourceAuto.folder;
        copiedAuto.saveFile();
        copiedAutos.add(copiedAuto);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _autoFolders.addAll(newFolders);
        _autoFolders.sort();
        _autos.addAll(copiedAutos);
        _sortAutos(_autoSortValue);
      });

      widget.prefs.setStringList(PrefsKeys.autoFolders, _autoFolders);
      widget.onFoldersChanged?.call();

      for (final auto in copiedAutos) {
        if (widget.hotReload) {
          widget.telemetry?.hotReloadAuto(auto);
        }
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${copiedAutos.length} auto copy/copies'
            '${newFolders.isEmpty ? '' : ' in ${newFolders.length} copied folder(s)'}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      if (mounted) {
        _showSaveAsError(this.context, err.toString());
      }
    }
  }

  Future<void> _saveAsPathFolderCopy({
    required String sourceFolder,
    required String newFolder,
  }) async {
    try {
      final existingPathNames = _paths.map<String>((path) => path.name).toSet();
      final copiedPaths = <PathPlannerPath>[];

      final sourcePaths = _paths
          .where((path) => path.folder == sourceFolder)
          .cast<PathPlannerPath>()
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      for (final sourcePath in sourcePaths) {
        final newName = _uniqueCopyOfName(sourcePath.name, existingPathNames);
        existingPathNames.add(newName);

        copiedPaths.add(
          _copyPathFile(
            sourcePathName: sourcePath.name,
            newPathName: newName,
            folder: newFolder,
            linkedWaypointPrefix: '${newName}_',
          ),
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        if (!_pathFolders.contains(newFolder)) {
          _pathFolders.add(newFolder);
          _pathFolders.sort();
        }

        _paths.addAll(copiedPaths);
        _sortPaths(_pathSortValue);
      });

      widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
      widget.onFoldersChanged?.call();

      for (final path in copiedPaths) {
        if (widget.hotReload) {
          widget.telemetry?.hotReloadPath(path);
        }
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved folder "$newFolder" with ${copiedPaths.length} path copy/copies',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      if (mounted) {
        _showSaveAsError(this.context, err.toString());
      }
    }
  }

  Future<void> _saveAsAutoFolderCopy({
    required String sourceFolder,
    required String newFolder,
  }) async {
    try {
      final existingAutoNames = _autos.map<String>((auto) => auto.name).toSet();
      final copiedAutos = <PathPlannerAuto>[];

      final sourceAutos = _autos
          .where((auto) => auto.folder == sourceFolder)
          .cast<PathPlannerAuto>()
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      for (final sourceAuto in sourceAutos) {
        final newName = _uniqueCopyOfName(sourceAuto.name, existingAutoNames);
        existingAutoNames.add(newName);

        final copiedAuto = sourceAuto.duplicate(newName);
        copiedAuto.folder = newFolder;
        copiedAuto.saveFile();
        copiedAutos.add(copiedAuto);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        if (!_autoFolders.contains(newFolder)) {
          _autoFolders.add(newFolder);
          _autoFolders.sort();
        }

        _autos.addAll(copiedAutos);
        _sortAutos(_autoSortValue);
      });

      widget.prefs.setStringList(PrefsKeys.autoFolders, _autoFolders);
      widget.onFoldersChanged?.call();

      for (final auto in copiedAutos) {
        if (widget.hotReload) {
          widget.telemetry?.hotReloadAuto(auto);
        }
      }

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved folder "$newFolder" with ${copiedAutos.length} auto copy/copies',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (err) {
      if (mounted) {
        _showSaveAsError(this.context, err.toString());
      }
    }
  }

  void _duplicateBulkSelection({
    required bool isPathsView,
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    if (isPathsView) {
      _duplicateBulkPaths(itemNames: itemNames, folderNames: folderNames);
    } else {
      _duplicateBulkAutos(itemNames: itemNames, folderNames: folderNames);
    }
  }

  void _duplicateBulkPaths({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    final existingPathNames = _paths.map<String>((path) => path.name).toSet();
    final existingFolderNames = _pathFolders.cast<String>().toSet();
    final copiedPaths = <PathPlannerPath>[];
    final newFolders = <String>[];

    for (final folderName in folderNames) {
      final newFolder = _uniqueFolderName(folderName, existingFolderNames);
      existingFolderNames.add(newFolder);
      newFolders.add(newFolder);

      final sourcePaths = _paths
          .where((path) => path.folder == folderName)
          .cast<PathPlannerPath>()
          .toList();

      for (final sourcePath in sourcePaths) {
        final newName = _uniqueCopyName(sourcePath.name, existingPathNames);
        existingPathNames.add(newName);

        copiedPaths.add(
          _copyPathFile(
            sourcePathName: sourcePath.name,
            newPathName: newName,
            folder: newFolder,
            linkedWaypointPrefix: '${newName}_',
          ),
        );
      }
    }

    for (final itemName in itemNames) {
      final sourcePath = _pathByName(itemName);
      if (sourcePath == null || folderNames.contains(sourcePath.folder)) {
        continue;
      }

      final newName = _uniqueCopyName(sourcePath.name, existingPathNames);
      existingPathNames.add(newName);

      copiedPaths.add(
        _copyPathFile(
          sourcePathName: sourcePath.name,
          newPathName: newName,
          folder: sourcePath.folder ?? '',
          linkedWaypointPrefix: '',
        ),
      );
    }

    setState(() {
      _pathFolders.addAll(newFolders);
      _pathFolders.sort();
      _paths.addAll(copiedPaths);
      _sortPaths(_pathSortValue);
    });

    widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
    widget.onFoldersChanged?.call();

    for (final path in copiedPaths) {
      if (widget.hotReload) {
        widget.telemetry?.hotReloadPath(path);
      }
    }

    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(
        content: Text(
          'Duplicated ${copiedPaths.length} path(s)'
          '${newFolders.isEmpty ? '' : ' into ${newFolders.length} folder(s)'}',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _duplicateBulkAutos({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    final existingAutoNames = _autos.map<String>((auto) => auto.name).toSet();
    final existingFolderNames = _autoFolders.cast<String>().toSet();
    final copiedAutos = <PathPlannerAuto>[];
    final newFolders = <String>[];

    for (final folderName in folderNames) {
      final newFolder = _uniqueFolderName(folderName, existingFolderNames);
      existingFolderNames.add(newFolder);
      newFolders.add(newFolder);

      final sourceAutos = _autos
          .where((auto) => auto.folder == folderName)
          .cast<PathPlannerAuto>()
          .toList();

      for (final sourceAuto in sourceAutos) {
        final newName = _uniqueCopyName(sourceAuto.name, existingAutoNames);
        existingAutoNames.add(newName);

        final copiedAuto = sourceAuto.duplicate(newName);
        copiedAuto.folder = newFolder;
        copiedAuto.saveFile();
        copiedAutos.add(copiedAuto);
      }
    }

    for (final itemName in itemNames) {
      final sourceAuto = _autoByName(itemName);
      if (sourceAuto == null || folderNames.contains(sourceAuto.folder)) {
        continue;
      }

      final newName = _uniqueCopyName(sourceAuto.name, existingAutoNames);
      existingAutoNames.add(newName);

      final copiedAuto = sourceAuto.duplicate(newName);
      copiedAuto.folder = sourceAuto.folder;
      copiedAuto.saveFile();
      copiedAutos.add(copiedAuto);
    }

    setState(() {
      _autoFolders.addAll(newFolders);
      _autoFolders.sort();
      _autos.addAll(copiedAutos);
      _sortAutos(_autoSortValue);
    });

    widget.prefs.setStringList(PrefsKeys.autoFolders, _autoFolders);
    widget.onFoldersChanged?.call();

    for (final auto in copiedAutos) {
      if (widget.hotReload) {
        widget.telemetry?.hotReloadAuto(auto);
      }
    }

    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(
        content: Text(
          'Duplicated ${copiedAutos.length} auto(s)'
          '${newFolders.isEmpty ? '' : ' into ${newFolders.length} folder(s)'}',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _deleteBulkSelection({
    required bool isPathsView,
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    if (isPathsView) {
      _deleteBulkPaths(itemNames: itemNames, folderNames: folderNames);
    } else {
      _deleteBulkAutos(itemNames: itemNames, folderNames: folderNames);
    }
  }

  void _deleteBulkPaths({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    final namesToDelete = <String>{...itemNames};

    for (final path in _paths) {
      if (folderNames.contains(path.folder)) {
        namesToDelete.add(path.name);
      }
    }

    for (final name in namesToDelete) {
      _pathByName(name)?.deletePath();
    }

    setState(() {
      _paths.removeWhere((path) => namesToDelete.contains(path.name));
      _pathFolders.removeWhere(folderNames.contains);

      if (_pathFolder != null && folderNames.contains(_pathFolder)) {
        _pathFolder = null;
      }

      _refreshAutoMissingPaths();
      _sortPaths(_pathSortValue);
    });

    widget.prefs.setStringList(PrefsKeys.pathFolders, _pathFolders);
    widget.onFoldersChanged?.call();

    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(
        content: Text('Deleted ${namesToDelete.length} path(s)'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _deleteBulkAutos({
    required Set<String> itemNames,
    required Set<String> folderNames,
  }) {
    final namesToDelete = <String>{...itemNames};

    for (final auto in _autos) {
      if (folderNames.contains(auto.folder)) {
        namesToDelete.add(auto.name);
      }
    }

    for (final name in namesToDelete) {
      _autoByName(name)?.delete();
    }

    setState(() {
      _autos.removeWhere((auto) => namesToDelete.contains(auto.name));
      _autoFolders.removeWhere(folderNames.contains);

      if (_autoFolder != null && folderNames.contains(_autoFolder)) {
        _autoFolder = null;
      }

      _sortAutos(_autoSortValue);
    });

    widget.prefs.setStringList(PrefsKeys.autoFolders, _autoFolders);
    widget.onFoldersChanged?.call();

    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(
        content: Text('Deleted ${namesToDelete.length} auto(s)'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _refreshAutoMissingPaths() {
    final allPathNames = _paths.map((path) => path.name).toList();

    for (final auto in _autos) {
      if (!auto.choreoAuto) {
        auto.handleMissingPaths(allPathNames);
      }
    }
  }

  Widget _buildPathCard(int i, BuildContext context) {
    final pathCard = ProjectItemCard(
      name: _paths[i].name,
      compact: _pathsCompact,
      fieldImage: widget.fieldImage,
      paths: [_paths[i].pathPositions],
      warningMessage: _paths[i].hasEmptyNamedCommand()
          ? 'Contains a NamedCommand that does not have a command selected'
          : null,
      selectionMode: _bulkSelectPaths,
      selected: _selectedBulkPathNames.contains(_paths[i].name),
      onSelectionChanged: (selected) => _setBulkItemSelected(
        isPathsView: true,
        name: _paths[i].name,
        selected: selected,
      ),
      showOptions: !_bulkSelectPaths,
      onDuplicated: () => _duplicatePath(_paths[i]),
      onSaveAs: () => _saveAsPath(_paths[i], context),
      onDeleted: () {
        _paths[i].deletePath();
        setState(() {
          _paths.removeAt(i);
        });

        List<String> allPathNames = _paths.map((e) => e.name).toList();
        for (PathPlannerAuto auto in _autos) {
          if (!auto.choreoAuto) {
            auto.handleMissingPaths(allPathNames);
          }
        }
      },
      onRenamed: (value) => _renamePath(_paths[i], value, context),
      onOpened: () => _bulkSelectPaths
          ? _toggleBulkItem(isPathsView: true, name: _paths[i].name)
          : _openPath(_paths[i]),
    );

    return LayoutBuilder(builder: (context, constraints) {
      return Draggable<PathPlannerPath>(
        data: _paths[i],
        feedback: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Opacity(
            opacity: 0.8,
            child: pathCard,
          ),
        ),
        childWhenDragging: Container(),
        child: pathCard,
      );
    });
  }

  Widget _buildChoreoPathCard(int i, BuildContext context) {
    final pathCard = ProjectItemCard(
      name: _choreoPaths[i].name,
      compact: _pathsCompact,
      fieldImage: widget.fieldImage,
      showOptions: false,
      paths: [_choreoPaths[i].pathPositions],
      choreoItem: true,
      onOpened: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChoreoPathEditorPage(
              prefs: widget.prefs,
              path: _choreoPaths[i],
              fieldImage: widget.fieldImage,
              undoStack: widget.undoStack,
              shortcuts: widget.shortcuts,
              simulatePath: widget.simulatePath,
            ),
          ),
        );
      },
    );

    return LayoutBuilder(builder: (context, constraints) {
      return Draggable<ChoreoPath>(
        data: _choreoPaths[i],
        feedback: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Opacity(
            opacity: 0.8,
            child: pathCard,
          ),
        ),
        childWhenDragging: Container(),
        child: pathCard,
      );
    });
  }

  void _openPath(PathPlannerPath path) async {
    await Navigator.push(
      this.context,
      MaterialPageRoute(
        builder: (context) => PathEditorPage(
          prefs: widget.prefs,
          path: path,
          fieldImage: widget.fieldImage,
          undoStack: widget.undoStack,
          onRenamed: (value) => _renamePath(path, value, context),
          shortcuts: widget.shortcuts,
          telemetry: widget.telemetry,
          hotReload: widget.hotReload,
          simulatePath: widget.simulatePath,
          onPathChanged: () {
            // Update the linked rotation for the start/end states
            if (path.waypoints.first.linkedName != null) {
              Waypoint.linked[path.waypoints.first.linkedName!] = Pose2d(
                  path.waypoints.first.anchor,
                  path.idealStartingState.rotation);
            }
            if (path.waypoints.last.linkedName != null) {
              Waypoint.linked[path.waypoints.last.linkedName!] = Pose2d(
                  path.waypoints.last.anchor, path.goalEndState.rotation);
            }

            // Make sure all paths with linked waypoints are updated
            for (PathPlannerPath p in _paths) {
              bool changed = false;

              for (int i = 0; i < p.waypoints.length; i++) {
                Waypoint w = p.waypoints[i];
                if (w.linkedName != null &&
                    Waypoint.linked.containsKey(w.linkedName!)) {
                  Pose2d link = Waypoint.linked[w.linkedName!]!;

                  if (link.translation.getDistance(w.anchor) >= 0.01) {
                    w.move(link.translation.x, link.translation.y);
                    changed = true;
                  }

                  if (i == 0 &&
                      (link.rotation - p.idealStartingState.rotation)
                              .degrees
                              .abs() >
                          0.01) {
                    p.idealStartingState.rotation = link.rotation;
                    changed = true;
                  } else if (i == p.waypoints.length - 1 &&
                      (link.rotation - p.goalEndState.rotation).degrees.abs() >
                          0.01) {
                    p.goalEndState.rotation = link.rotation;
                    changed = true;
                  }
                }
              }

              if (changed) {
                p.generateAndSavePath();

                if (widget.hotReload) {
                  widget.telemetry?.hotReloadPath(p);
                }
              }
            }
          },
        ),
      ),
    );

    setState(() {
      _sortPaths(_pathSortValue);
    });
  }

  void _renamePath(PathPlannerPath path, String newName, BuildContext context) {
    List<String> pathNames = [];
    for (PathPlannerPath p in _paths) {
      pathNames.add(p.name);
    }

    if (pathNames.contains(newName)) {
      showDialog(
          context: this.context,
          builder: (BuildContext context) {
            ColorScheme colorScheme = Theme.of(context).colorScheme;
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: const Text('Unable to Rename'),
              content: Text('The file "$newName.path" already exists'),
              actions: [
                TextButton(
                  onPressed: Navigator.of(context).pop,
                  child: const Text('OK'),
                ),
              ],
            );
          });
    } else {
      String oldName = path.name;
      setState(() {
        path.renamePath(newName);
        for (PathPlannerAuto auto in _autos) {
          auto.updatePathName(oldName, newName);
        }
        _sortPaths(_pathSortValue);
      });
    }
  }

  int _getCrossAxisCountForWeight(double weight) {
    if (weight < 0.4) {
      return 1;
    } else if (weight < 0.6) {
      return 2;
    } else {
      return 3;
    }
  }

  Widget _buildAutosGrid(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 8.0, top: 8.0),
      child: Card(
        elevation: 0.0,
        margin: const EdgeInsets.all(0),
        color: colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              const SizedBox(height: 8),
              _buildOptionsRow(
                sortValue: _autoSortValue,
                viewValue: _autosCompact,
                onSortChanged: (value) {
                  widget.prefs.setString(PrefsKeys.autoSortOption, value);
                  setState(() {
                    _autoSortValue = value;
                    _sortAutos(_autoSortValue);
                  });
                },
                onViewChanged: (value) {
                  widget.prefs.setBool(PrefsKeys.autosCompactView, value);
                  setState(() {
                    _autosCompact = value;
                  });
                },
                onSearchChanged: (value) {
                  setState(() {
                    _autoSearchQuery = value;
                  });
                },
                searchController: _autoSearchController,
                onAddFolder: () {
                  String folderName = 'New Folder';
                  while (_autoFolders.contains(folderName)) {
                    folderName = 'New $folderName';
                  }

                  setState(() {
                    _autoFolders.add(folderName);
                    _sortAutos(_autoSortValue);
                  });
                  widget.prefs
                      .setStringList(PrefsKeys.autoFolders, _autoFolders);
                  widget.onFoldersChanged?.call();
                },
                onAddItem: () {
                  if (_choreoPaths.isNotEmpty) {
                    final RenderBox renderBox = _addAutoKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    final Size size = renderBox.size;
                    final Offset offset = renderBox.localToGlobal(Offset.zero);

                    showMenu(
                      context: context,
                      position: RelativeRect.fromLTRB(
                        offset.dx,
                        offset.dy + size.height,
                        offset.dx + size.width,
                        offset.dy + size.height,
                      ),
                      items: [
                        PopupMenuItem(
                          child: const Text('New PathPlanner Auto'),
                          onTap: () => _createNewAuto(),
                        ),
                        PopupMenuItem(
                          child: const Text('New Choreo Auto'),
                          onTap: () => _createNewAuto(choreo: true),
                        ),
                      ],
                    );
                  } else {
                    _createNewAuto();
                  }
                },
                isPathsView: false,
              ),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ConditionalWidget(
                      condition: _autoFolder == null,
                      falseChild: GridView.count(
                        crossAxisCount: _autosGridCount,
                        childAspectRatio: 5.5,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          DragTarget<PathPlannerAuto>(
                            onAcceptWithDetails: (details) {
                              setState(() {
                                details.data.folder = null;
                                details.data.saveFile();
                              });
                            },
                            builder: (context, candidates, rejects) {
                              ColorScheme colorScheme =
                                  Theme.of(context).colorScheme;
                              return Card(
                                elevation: 2,
                                color: candidates.isNotEmpty
                                    ? colorScheme.primary
                                    : colorScheme.surface,
                                surfaceTintColor: colorScheme.surfaceTint,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    setState(() {
                                      _autoFolder = null;
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8.0),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.drive_file_move_rtl_outlined,
                                          color: candidates.isNotEmpty
                                              ? colorScheme.onPrimary
                                              : null,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'Root Folder',
                                              style: TextStyle(
                                                fontSize: 20,
                                                color: candidates.isNotEmpty
                                                    ? colorScheme.onPrimary
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      trueChild: GridView.count(
                        crossAxisCount: _autosGridCount,
                        childAspectRatio: 5.5,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (int i = 0; i < _autoFolders.length; i++)
                            DragTarget<PathPlannerAuto>(
                              onAcceptWithDetails: (details) {
                                setState(() {
                                  details.data.folder = _autoFolders[i];
                                  details.data.saveFile();
                                });
                              },
                              builder: (context, candidates, rejects) {
                                ColorScheme colorScheme =
                                    Theme.of(context).colorScheme;
                                return Card(
                                  elevation: 2,
                                  color: candidates.isNotEmpty
                                      ? colorScheme.primary
                                      : colorScheme.surface,
                                  surfaceTintColor: colorScheme.surfaceTint,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      if (_bulkSelectAutos) {
                                        _toggleBulkFolder(
                                          isPathsView: false,
                                          folderName: _autoFolders[i],
                                        );
                                        return;
                                      }

                                      setState(() {
                                        _autoFolder = _autoFolders[i];
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8.0),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.folder_outlined,
                                            color: candidates.isNotEmpty
                                                ? colorScheme.onPrimary
                                                : null,
                                          ),
                                          _buildFolderSelectionCheckbox(
                                            isPathsView: false,
                                            folderName: _autoFolders[i],
                                            color: candidates.isNotEmpty
                                                ? colorScheme.onPrimary
                                                : null,
                                          ),
                                          Expanded(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: RenamableTitle(
                                                title: _autoFolders[i],
                                                textStyle: TextStyle(
                                                  fontSize: 20,
                                                  color: candidates.isNotEmpty
                                                      ? colorScheme.onPrimary
                                                      : null,
                                                ),
                                                onRename: (newName) {
                                                  if (newName !=
                                                      _autoFolders[i]) {
                                                    if (_autoFolders
                                                        .contains(newName)) {
                                                      showDialog(
                                                          context: this.context,
                                                          builder: (BuildContext
                                                              context) {
                                                            ColorScheme
                                                                colorScheme =
                                                                Theme.of(
                                                                        context)
                                                                    .colorScheme;
                                                            return AlertDialog(
                                                              backgroundColor:
                                                                  colorScheme
                                                                      .surface,
                                                              surfaceTintColor:
                                                                  colorScheme
                                                                      .surfaceTint,
                                                              title: const Text(
                                                                  'Unable to Rename'),
                                                              content: Text(
                                                                  'The folder "$newName" already exists'),
                                                              actions: [
                                                                TextButton(
                                                                  onPressed:
                                                                      Navigator.of(
                                                                              context)
                                                                          .pop,
                                                                  child:
                                                                      const Text(
                                                                          'OK'),
                                                                ),
                                                              ],
                                                            );
                                                          });
                                                    } else {
                                                      setState(() {
                                                        for (PathPlannerAuto auto
                                                            in _autos) {
                                                          if (auto.folder ==
                                                              _autoFolders[i]) {
                                                            auto.folder =
                                                                newName;
                                                            auto.saveFile();
                                                          }
                                                        }
                                                        _autoFolders[i] =
                                                            newName;
                                                      });
                                                      widget.prefs
                                                          .setStringList(
                                                              PrefsKeys
                                                                  .autoFolders,
                                                              _autoFolders);
                                                      widget.onFoldersChanged
                                                          ?.call();
                                                    }
                                                  }
                                                },
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                    if (_autoFolders.isNotEmpty) const SizedBox(height: 8),
                    GridView.count(
                      crossAxisCount:
                          _autosCompact ? _autosGridCount + 1 : _autosGridCount,
                      childAspectRatio: _autosCompact ? 2.5 : 1.55,
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      children: [
                        for (int i = 0; i < _autos.length; i++)
                          if (_autos[i].folder == _autoFolder &&
                              _autos[i]
                                  .name
                                  .toLowerCase()
                                  .contains(_autoSearchQuery.toLowerCase()))
                            _buildAutoCard(i, context),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutoCard(int i, BuildContext context) {
    String? warningMessage;

    if (_autos[i].hasEmptyPathCommands()) {
      warningMessage =
          'Contains a FollowPathCommand that does not have a path selected';
    } else if (_autos[i].hasEmptyNamedCommand()) {
      warningMessage =
          'Contains a NamedCommand that does not have a command selected';
    }

    final autoCard = ProjectItemCard(
      name: _autos[i].name,
      compact: _autosCompact,
      fieldImage: widget.fieldImage,
      choreoItem: _autos[i].choreoAuto,
      selectionMode: _bulkSelectAutos,
      selected: _selectedBulkAutoNames.contains(_autos[i].name),
      onSelectionChanged: (selected) => _setBulkItemSelected(
        isPathsView: false,
        name: _autos[i].name,
        selected: selected,
      ),
      showOptions: !_bulkSelectAutos,
      paths: _autos[i].choreoAuto
          ? [
              for (ChoreoPath path
                  in _getChoreoPathsFromNames(_autos[i].getAllPathNames()))
                path.pathPositions,
            ]
          : [
              for (PathPlannerPath path
                  in _getPathsFromNames(_autos[i].getAllPathNames()))
                path.pathPositions,
            ],
      onDuplicated: () => _duplicateAuto(_autos[i]),
      onSaveAs: () => _saveAsAuto(_autos[i], context),
      onDeleted: () {
        _autos[i].delete();
        setState(() {
          _autos.removeAt(i);
        });
      },
      onRenamed: (value) => _renameAuto(i, value, context),
      onOpened: () async {
        if (_bulkSelectAutos) {
          _toggleBulkItem(isPathsView: false, name: _autos[i].name);
          return;
        }

        String? pathNameToOpen = await Navigator.push<String?>(
          context,
          MaterialPageRoute(
            builder: (context) => AutoEditorPage(
              prefs: widget.prefs,
              auto: _autos[i],
              allPaths: _paths,
              allChoreoPaths: _choreoPaths,
              undoStack: widget.undoStack,
              allPathNames: _autos[i].choreoAuto
                  ? _choreoPaths.map((e) => e.name).toList()
                  : _paths.map((e) => e.name).toList(),
              fieldImage: widget.fieldImage,
              onRenamed: (value) => _renameAuto(i, value, context),
              shortcuts: widget.shortcuts,
              telemetry: widget.telemetry,
              hotReload: widget.hotReload,
              pathDir: _pathsDirectory.path,
              onAutoSaved: () {
                if (mounted) {
                  setState(() {
                    _sortAutos(_autoSortValue);
                  });
                }
              },
              onPathsChanged: () {
                if (mounted) {
                  _load();
                }
              },
            ),
          ),
        );
        setState(() {
          _sortAutos(_autoSortValue);
        });

        if (pathNameToOpen != null) {
          final pathToOpen =
              _paths.firstWhereOrNull((p) => p.name == pathNameToOpen);
          if (pathToOpen != null) {
            _openPath(pathToOpen);
          }
        }
      },
      warningMessage: warningMessage,
    );

    return LayoutBuilder(builder: (context, constraints) {
      return Draggable<PathPlannerAuto>(
        data: _autos[i],
        feedback: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Opacity(
            opacity: 0.8,
            child: autoCard,
          ),
        ),
        childWhenDragging: Container(),
        child: autoCard,
      );
    });
  }

  Widget _buildOptionsRow({
    required String sortValue,
    required bool viewValue,
    required ValueChanged<String> onSortChanged,
    required ValueChanged<bool> onViewChanged,
    required ValueChanged<String> onSearchChanged,
    required TextEditingController searchController,
    required VoidCallback onAddFolder,
    required VoidCallback onAddItem,
    required bool isPathsView,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6.0),
      child: Column(children: [
        Row(
          children: [
            _buildViewButton(
              viewValue: viewValue,
              onViewChanged: onViewChanged,
            ),
            _buildSortButton(
              sortValue: sortValue,
              onSortChanged: onSortChanged,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildSearchBar(
                isPathsView: isPathsView,
                onChanged: onSearchChanged,
                controller: searchController,
              ),
            ),
            const SizedBox(width: 14),
            if (isPathsView) ...[
              _buildExportAllPathsButton(),
              const SizedBox(width: 8),
            ],
            _buildBulkActionsButton(isPathsView: isPathsView),
            const SizedBox(width: 8),
            _buildFolderButton(
              isPathsView: isPathsView,
              onAddFolder: onAddFolder,
              onDeleteFolder: () {
                showDialog(
                  context: this.context,
                  builder: (context) {
                    ColorScheme colorScheme = Theme.of(context).colorScheme;
                    return AlertDialog(
                      backgroundColor: colorScheme.surface,
                      surfaceTintColor: colorScheme.surfaceTint,
                      title: const Text('Delete Folder'),
                      content: SizedBox(
                        width: 400,
                        child: Text(
                          'Are you sure you want to delete the folder "${isPathsView ? _pathFolder : _autoFolder}"?\n\nThis will also delete all ${isPathsView ? "paths" : "autos"} within the folder. This cannot be undone.',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: Navigator.of(context).pop,
                          child: const Text('CANCEL'),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();

                            if (isPathsView) {
                              for (int p = 0; p < _paths.length; p++) {
                                if (_paths[p].folder == _pathFolder) {
                                  _paths[p].deletePath();
                                }
                              }

                              setState(() {
                                _paths.removeWhere(
                                    (path) => path.folder == _pathFolder);
                                _pathFolders.remove(_pathFolder);
                                _pathFolder = null;
                              });
                              widget.prefs.setStringList(
                                  PrefsKeys.pathFolders, _pathFolders);
                            } else {
                              for (int a = 0; a < _autos.length; a++) {
                                if (_autos[a].folder == _autoFolder) {
                                  _autos[a].delete();
                                }
                              }

                              setState(() {
                                _autos.removeWhere(
                                    (auto) => auto.folder == _autoFolder);
                                _autoFolders.remove(_autoFolder);
                                _autoFolder = null;
                              });
                              widget.prefs.setStringList(
                                  PrefsKeys.autoFolders, _autoFolders);
                            }
                            widget.onFoldersChanged?.call();
                          },
                          child: const Text('DELETE'),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            const SizedBox(width: 8),
            if (!isPathsView) _buildAutoStudioButton(),
            if (!isPathsView) const SizedBox(width: 8),
            _buildAddButton(
              isPathsView: isPathsView,
              onAddItem: onAddItem,
            ),
            const SizedBox(width: 8),
          ],
        ),
        _buildBulkActionsRow(isPathsView: isPathsView),
        const SizedBox(height: 10),
      ]),
    );
  }

  Widget _buildViewButton({
    required bool viewValue,
    required ValueChanged<bool> onViewChanged,
  }) {
    return PopupMenuButton<bool>(
      initialValue: viewValue,
      tooltip: 'View options',
      icon: Icon(viewValue ? Icons.view_list_rounded : Icons.grid_view_rounded),
      itemBuilder: (context) => const [
        PopupMenuItem(value: false, child: Text('Default')),
        PopupMenuItem(value: true, child: Text('Compact')),
      ],
      onSelected: onViewChanged,
    );
  }

  Widget _buildSortButton({
    required String sortValue,
    required ValueChanged<String> onSortChanged,
  }) {
    return PopupMenuButton<String>(
      initialValue: sortValue,
      tooltip: 'Sort options',
      icon: const Icon(Icons.sort_rounded),
      itemBuilder: (context) => _sortOptions(),
      onSelected: onSortChanged,
    );
  }

  Widget _buildExportAllPathsButton() {
    return IconButton.filledTonal(
      tooltip: 'Export all paths as dark GIFs or dark transparent PNGs',
      icon: const Icon(Icons.file_download_outlined),
      onPressed: _paths.isEmpty
          ? null
          : () {
              showDialog(
                context: this.context,
                builder: (context) => BatchPathExportDialog(
                  fieldImage: widget.fieldImage,
                  prefs: widget.prefs,
                  paths: _paths,
                ),
              );
            },
    );
  }

  Widget _buildFolderButton({
    required bool isPathsView,
    required VoidCallback onAddFolder,
    required VoidCallback onDeleteFolder,
  }) {
    final bool isRootFolder =
        isPathsView ? _pathFolder == null : _autoFolder == null;

    return IconButton.filledTonal(
      icon: Icon(isRootFolder
          ? Icons.create_new_folder_outlined
          : Icons.delete_forever_rounded),
      tooltip: isRootFolder
          ? 'Add new folder'
          : isPathsView
              ? 'Delete path folder'
              : 'Delete auto folder',
      onPressed: () {
        if (isRootFolder) {
          onAddFolder();
        } else {
          onDeleteFolder();
        }
      },
    );
  }

  void _openAutoStudio() {
    final auto = _createNewBattlecryAuto();
    auto.saveFile();

    Navigator.of(this.context)
        .push(MaterialPageRoute(
      builder: (context) => AutoStudioPage(
        prefs: widget.prefs,
        auto: auto,
        allPaths: _paths,
        allChoreoPaths: _choreoPaths,
        allPathNames: [
          for (final path in _paths) path.name,
          for (final path in _choreoPaths) path.name,
        ],
        pathDir: _pathsDirectory.path,
        initialAutoFolder: _autoFolder,
        fieldImage: widget.fieldImage,
        undoStack: widget.undoStack,
        telemetry: widget.telemetry,
        hotReload: widget.hotReload,
        onRenamed: (value) {
          final autoIdx = _autos.indexWhere((item) => identical(item, auto));
          if (autoIdx >= 0) {
            _renameAuto(autoIdx, value, this.context);
            _autos[autoIdx].folder = _autoFolder;
            _autos[autoIdx].saveFile();
          }
        },
        onAutoSaved: () {
          if (mounted) {
            setState(() {
              _sortAutos(_autoSortValue);
            });
          }
        },
        onPathsChanged: () {
          if (mounted) {
            _load();
          }
        },
      ),
    ))
        .then((value) {
      widget.undoStack.clearHistory();
      if (mounted) {
        _load();
      }
    });
  }

  PathPlannerAuto _createNewBattlecryAuto() {
    final autoNames = <String>[];
    for (final auto in _autos) {
      autoNames.add(auto.name);
    }

    var autoName = 'New Frenzy Auto';
    var copyIndex = 2;
    while (autoNames.contains(autoName)) {
      autoName = 'New Frenzy Auto $copyIndex';
      copyIndex++;
    }

    final auto = PathPlannerAuto.defaultAuto(
      autoDir: _autosDirectory.path,
      name: autoName,
      fs: fs,
      folder: _autoFolder,
      choreoAuto: false,
    );

    setState(() {
      _autos.add(auto);
      _sortAutos(_autoSortValue);
    });

    return auto;
  }

  Widget _buildAutoStudioButton() {
    return IconButton.filledTonal(
      tooltip: 'Open Frenzy Auto Studio',
      icon: const Icon(Icons.auto_awesome_motion_rounded),
      onPressed: _openAutoStudio,
    );
  }

  Widget _buildAddButton({
    required bool isPathsView,
    required VoidCallback onAddItem,
  }) {
    if (!isPathsView) {
      return Tooltip(
        message: 'Add new auto',
        waitDuration: const Duration(seconds: 1),
        child: IconButton.filled(
          key: _addAutoKey,
          onPressed: () {
            if (_choreoPaths.isNotEmpty) {
              final RenderBox renderBox =
                  _addAutoKey.currentContext?.findRenderObject() as RenderBox;
              final Size size = renderBox.size;
              final Offset offset = renderBox.localToGlobal(Offset.zero);
              showMenu(
                context: this.context,
                position: RelativeRect.fromLTRB(
                  offset.dx,
                  offset.dy + size.height,
                  offset.dx + size.width,
                  offset.dy + size.height,
                ),
                items: [
                  PopupMenuItem(
                    child: const Text('New PathPlanner Auto'),
                    onTap: () => _createNewAuto(),
                  ),
                  PopupMenuItem(
                    child: const Text('New Choreo Auto'),
                    onTap: () => _createNewAuto(choreo: true),
                  ),
                ],
              );
            } else {
              _createNewAuto();
            }
          },
          icon: const Icon(Icons.add_rounded),
        ),
      );
    } else {
      return IconButton.filled(
        tooltip: 'Add new path',
        icon: const Icon(Icons.add_rounded),
        onPressed: onAddItem,
      );
    }
  }

  void _createNewAuto({bool choreo = false}) {
    List<String> autoNames = [];
    for (PathPlannerAuto auto in _autos) {
      autoNames.add(auto.name);
    }
    String autoName = 'New Auto';
    while (autoNames.contains(autoName)) {
      autoName = 'New $autoName';
    }

    setState(() {
      _autos.add(PathPlannerAuto.defaultAuto(
        autoDir: _autosDirectory.path,
        name: autoName,
        fs: fs,
        folder: _autoFolder,
        choreoAuto: choreo,
      ));
      _sortAutos(_autoSortValue);
    });
  }

  Widget _buildSearchBar({
    required bool isPathsView,
    required ValueChanged<String> onChanged,
    required TextEditingController controller,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: 'Search for ${isPathsView ? "Paths..." : "Autos..."}',
        prefixIcon: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: Icon(Icons.search_rounded),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
      ),
      onChanged: (value) {
        // Debounce the search to avoid freezing
        Future.delayed(const Duration(milliseconds: 300), () {
          if (value == controller.text) {
            onChanged(value);
          }
        });
      },
    );
  }

  List<PathPlannerPath> _getPathsFromNames(List<String> names) {
    List<PathPlannerPath> paths = [];
    for (String name in names) {
      List<PathPlannerPath> matched =
          _paths.where((path) => path.name == name).toList();
      if (matched.isNotEmpty) {
        paths.add(matched[0]);
      }
    }
    return paths;
  }

  List<ChoreoPath> _getChoreoPathsFromNames(List<String> names) {
    List<ChoreoPath> paths = [];
    for (String name in names) {
      List<ChoreoPath> matched =
          _choreoPaths.where((path) => path.name == name).toList();
      if (matched.isNotEmpty) {
        paths.add(matched[0]);
      }
    }
    return paths;
  }

  Future<void> _safeRenameOrRemoveExistingProjectFile(
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

    try {
      if (targetFile != null && await targetFile.exists()) {
        if (await sourceFile.exists()) {
          await sourceFile.delete();
        }
        return;
      }

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

      if (await sourceFile.exists()) {
        try {
          if (targetFile != null) {
            await sourceFile.copy(targetPath);
            await sourceFile.delete();
            return;
          }
        } catch (_) {
          rethrow;
        }
      }

      rethrow;
    }
  }

  void _renameAuto(int autoIdx, String newName, BuildContext context) {
    List<String> autoNames = [];
    for (PathPlannerAuto auto in _autos) {
      autoNames.add(auto.name);
    }

    if (autoNames.contains(newName)) {
      showDialog(
          context: this.context,
          builder: (BuildContext context) {
            ColorScheme colorScheme = Theme.of(context).colorScheme;
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              surfaceTintColor: colorScheme.surfaceTint,
              title: const Text('Unable to Rename'),
              content: Text('The file "$newName.auto" already exists'),
              actions: [
                TextButton(
                  onPressed: Navigator.of(context).pop,
                  child: const Text('OK'),
                ),
              ],
            );
          });
    } else {
      setState(() {
        _autos[autoIdx].rename(newName);
        _sortAutos(_autoSortValue);
      });
    }
  }

  void _sortPaths(String sortOption) {
    // Get the latest sort option from shared preferences
    String latestSortOption =
        widget.prefs.getString(PrefsKeys.pathSortOption) ??
            Defaults.pathSortOption;

    switch (latestSortOption) {
      case 'recent':
        _paths.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        _pathFolders.sort((a, b) => a.compareTo(b));
        break;
      case 'nameDesc':
        _paths.sort((a, b) => b.name.compareTo(a.name));
        _pathFolders.sort((a, b) => b.compareTo(a));
        break;
      case 'nameAsc':
        _paths.sort((a, b) => a.name.compareTo(b.name));
        _pathFolders.sort((a, b) => a.compareTo(b));
        break;
      default:
        throw FormatException('Invalid sort value', sortOption);
    }
  }

  void _sortAutos(String sortOption) {
    switch (sortOption) {
      case 'recent':
        _autos.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        _autoFolders.sort((a, b) => a.compareTo(b));
        break;
      case 'nameDesc':
        _autos.sort((a, b) => b.name.compareTo(a.name));
        _autoFolders.sort((a, b) => b.compareTo(a));
        break;
      case 'nameAsc':
        _autos.sort((a, b) => a.name.compareTo(b.name));
        _autoFolders.sort((a, b) => a.compareTo(b));
        break;
      default:
        throw FormatException('Invalid sort value', sortOption);
    }
  }

  List<PopupMenuItem<String>> _sortOptions() {
    return const [
      PopupMenuItem(
        value: 'recent',
        child: Text('Recent'),
      ),
      PopupMenuItem(
        value: 'nameAsc',
        child: Text('Name Ascending'),
      ),
      PopupMenuItem(
        value: 'nameDesc',
        child: Text('Name Descending'),
      ),
    ];
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
      nominalVoltage: widget.prefs.getDouble(PrefsKeys.defaultNominalVoltage) ??
          Defaults.defaultNominalVoltage,
    );
  }
}
