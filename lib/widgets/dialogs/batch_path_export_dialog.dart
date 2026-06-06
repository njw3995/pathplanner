import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:isolate_manager/isolate_manager.dart';
import 'package:path/path.dart' as p;
import 'package:pathplanner/path/pathplanner_path.dart';
import 'package:pathplanner/trajectory/config.dart';
import 'package:pathplanner/trajectory/trajectory.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/trajectory_render.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:widgets_to_image/widgets_to_image.dart';

typedef BatchGifProgress = ({double progress, Uint8List? bytes});

enum BatchPathExportMode {
  darkGif,
  darkTransparentPng,
  viewerAssets,
}

class BatchPathExportDialog extends StatefulWidget {
  final FieldImage fieldImage;
  final SharedPreferences prefs;
  final List<PathPlannerPath> paths;

  const BatchPathExportDialog({
    super.key,
    required this.fieldImage,
    required this.prefs,
    required this.paths,
  });

  @override
  State<BatchPathExportDialog> createState() => _BatchPathExportDialogState();
}

class _BatchPathExportDialogState extends State<BatchPathExportDialog> {
  final WidgetsToImageController _controller = WidgetsToImageController();
  static IsolateManager? _gifManager;

  late final ThemeData _darkTheme;
  PathPlannerTrajectory? _activeTrajectory;
  num? _sampleTime;
  bool _showFieldImage = true;
  bool _solidBackground = true;
  bool _exporting = false;
  double _progress = 0.0;
  String _status = 'Choose an export format.';

  @override
  void initState() {
    super.initState();
    final teamColor =
        widget.prefs.getInt(PrefsKeys.teamColor) ?? Defaults.teamColor;
    _darkTheme = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Color(teamColor),
      brightness: Brightness.dark,
    );

    if (widget.paths.isNotEmpty) {
      _activeTrajectory = _createTrajectory(widget.paths.first).trajectory;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: colorScheme.surfaceTint,
      title: const Text('Export All Path Images'),
      content: SizedBox(
        width: 820,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 800,
              height: 400,
              child: FittedBox(
                child: WidgetsToImage(
                  controller: _controller,
                  child: Container(
                    color: _solidBackground
                        ? _darkTheme.colorScheme.surface
                        : null,
                    child: Theme(
                      data: _darkTheme,
                      child: _activeTrajectory == null
                          ? SizedBox(
                              width: widget.fieldImage.defaultSize.width / 4,
                              height: widget.fieldImage.defaultSize.height / 4,
                            )
                          : TrajectoryRender(
                              fieldImage: widget.fieldImage,
                              prefs: widget.prefs,
                              trajectory: _activeTrajectory!,
                              sampleTime: _sampleTime,
                              showFieldImage: _showFieldImage,
                            ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(_status),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _exporting ? _progress : null),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _exporting ? null : Navigator.of(context).pop,
          child: const Text('Close'),
        ),
        FilledButton.tonalIcon(
          onPressed: _exporting
              ? null
              : () => _export(BatchPathExportMode.darkTransparentPng),
          icon: const Icon(Icons.layers_clear_rounded),
          label: const Text('Dark Transparent PNGs'),
        ),
        FilledButton.tonalIcon(
          onPressed:
              _exporting ? null : () => _export(BatchPathExportMode.darkGif),
          icon: const Icon(Icons.movie_creation_outlined),
          label: const Text('Dark GIFs'),
        ),
        FilledButton.icon(
          onPressed: _exporting
              ? null
              : () => _export(BatchPathExportMode.viewerAssets),
          icon: const Icon(Icons.video_collection_outlined),
          label: const Text('Viewer Assets'),
        ),
      ],
    );
  }

  ({PathPlannerTrajectory? trajectory, String? error}) _createTrajectory(
      PathPlannerPath path) {
    try {
      return (
        trajectory: PathPlannerTrajectory(
          path: path,
          robotConfig: RobotConfig.fromPrefs(widget.prefs),
        ),
        error: null,
      );
    } catch (error) {
      return (trajectory: null, error: error.toString());
    }
  }

  Future<void> _export(BatchPathExportMode mode) async {
    final outputDir = await getDirectoryPath(
      confirmButtonText: 'Export Here',
    );

    if (outputDir == null) {
      return;
    }

    setState(() {
      _exporting = true;
      _progress = 0.0;
      _status = 'Preparing export...';
    });

    final failures = <String>[];
    final exported = <Map<String, String>>[];
    final paths = [...widget.paths]..sort((a, b) => a.name.compareTo(b.name));
    final gifDir = mode == BatchPathExportMode.viewerAssets
        ? Directory(p.join(outputDir, 'gifs'))
        : Directory(outputDir);
    final overlayDir = mode == BatchPathExportMode.viewerAssets
        ? Directory(p.join(outputDir, 'overlays'))
        : Directory(outputDir);

    if (mode == BatchPathExportMode.viewerAssets) {
      await gifDir.create(recursive: true);
      await overlayDir.create(recursive: true);
    }

    for (int i = 0; i < paths.length; i++) {
      final path = paths[i];
      final created = _createTrajectory(path);
      final trajectory = created.trajectory;
      if (trajectory == null || trajectory.states.isEmpty) {
        failures.add('${path.name}: ${created.error ?? 'empty trajectory'}');
        continue;
      }

      setState(() {
        _activeTrajectory = trajectory;
        _status = 'Exporting ${path.name} (${i + 1}/${paths.length})';
        _progress = i / paths.length;
      });

      final stem = _safeFileName(path.name);
      final entry = <String, String>{'name': path.name};

      if (mode == BatchPathExportMode.darkGif ||
          mode == BatchPathExportMode.viewerAssets) {
        try {
          _showFieldImage = true;
          _solidBackground = true;
          _sampleTime = 0.0;
          final gifFile = File(p.join(gifDir.path, '$stem.gif'));
          final bytes = await _captureGif(trajectory);
          await gifFile.writeAsBytes(bytes);
          entry['gif'] = p.relative(gifFile.path, from: outputDir);
        } catch (error) {
          failures.add('${path.name} GIF: $error');
        }
      }

      if (mode == BatchPathExportMode.darkTransparentPng ||
          mode == BatchPathExportMode.viewerAssets) {
        try {
          _showFieldImage = false;
          _solidBackground = false;
          _sampleTime = null;
          setState(() {});
          final overlayFile = File(p.join(overlayDir.path, '$stem.png'));
          final bytes = await _capturePng();
          if (bytes == null) {
            throw Exception('Capture returned no image bytes');
          }
          await overlayFile.writeAsBytes(bytes);
          entry['overlay'] = p.relative(overlayFile.path, from: outputDir);
        } catch (error) {
          failures.add('${path.name} PNG: $error');
        }
      }

      if (entry.length > 1) {
        exported.add(entry);
      }
    }

    if (mode == BatchPathExportMode.viewerAssets) {
      final manifest = File(p.join(outputDir, 'manifest.json'));
      await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'description': 'PathPlanner preview assets for external auto viewers',
          'paths': exported,
          'failures': failures,
        }),
      );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _exporting = false;
      _progress = 1.0;
      _sampleTime = null;
      final successCount = exported.length;
      final locationText = mode == BatchPathExportMode.viewerAssets
          ? '$outputDir (gifs/, overlays/, manifest.json)'
          : outputDir;
      _status = failures.isEmpty
          ? 'Exported $successCount path(s) to $locationText'
          : 'Exported $successCount/${paths.length} path(s) to $locationText. Failed: ${failures.join('; ')}';
    });
  }

  Future<Uint8List?> _capturePng() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final bytes = await _controller.capture(pixelRatio: 1);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return bytes;
  }

  Future<Uint8List> _captureGif(PathPlannerTrajectory trajectory) async {
    final frames = <Uint8List>[];
    double sampleTime = 0.0;
    final totalTime = trajectory.getTotalTimeSeconds().toDouble();

    while (sampleTime < totalTime) {
      setState(() {
        _sampleTime = sampleTime;
      });
      final frame = await _capturePng();
      if (frame != null) {
        frames.add(frame);
      }
      sampleTime += 0.04;
    }

    setState(() {
      _sampleTime = totalTime;
    });
    final finalFrame = await _capturePng();
    if (finalFrame != null) {
      frames.add(finalFrame);
    }

    if (frames.isEmpty) {
      throw Exception('No GIF frames were captured');
    }

    _gifManager ??= IsolateManager.createCustom(_encodeGif);
    final BatchGifProgress result = await _gifManager!.compute(
      frames,
      callback: (progressValue) {
        final BatchGifProgress progress = progressValue;
        return progress.bytes != null;
      },
    );

    if (result.bytes == null) {
      throw Exception('GIF encoder returned no bytes');
    }

    return result.bytes!;
  }

  String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return cleaned.isEmpty ? 'Path' : cleaned;
  }

  @isolateManagerCustomWorker
  static void _encodeGif(dynamic params) {
    IsolateManagerFunction.customFunction<BatchGifProgress, List<Uint8List>>(
      params,
      onEvent: (controller, message) {
        final decoder = img.PngDecoder();
        final encoder = img.GifEncoder(
          numColors: 64,
          dither: img.DitherKernel.none,
        );
        var addedFrames = 0;
        final denom = message.length <= 1 ? 1 : message.length - 1;

        for (int i = 0; i < message.length; i++) {
          try {
            final decoded = decoder.decode(message[i]);
            if (decoded != null) {
              encoder.addFrame(decoded, duration: 4);
              addedFrames++;
            }
          } catch (_) {
            // Skip bad captures instead of taking down the whole desktop app.
          }

          controller.sendResult((
            progress: i / denom,
            bytes: null,
          ));
        }

        if (addedFrames == 0) {
          return (progress: 1.0, bytes: null);
        }

        return (progress: 1.0, bytes: encoder.finish());
      },
    );
  }
}
