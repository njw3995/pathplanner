import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pathplanner/trajectory/trajectory.dart';

class PreviewSeekbar extends StatefulWidget {
  final AnimationController previewController;
  final ValueChanged<bool>? onPauseStateChanged;
  final num totalPathTime;
  final PathPlannerTrajectory? simulatedPath;

  const PreviewSeekbar({
    super.key,
    required this.previewController,
    this.onPauseStateChanged,
    required this.totalPathTime,
    this.simulatedPath,
  });

  @override
  State<PreviewSeekbar> createState() => _PreviewSeekbarState();
}

class _PreviewSeekbarState extends State<PreviewSeekbar> {
  static const double _endSampleBackoffSeconds = 0.02;

  num _displaySampleTime() {
    final totalTime = widget.totalPathTime;
    if (totalTime <= 0) {
      return 0.0;
    }

    final rawTime = widget.previewController.value * totalTime;
    if (widget.previewController.value >= 0.999999 && totalTime > _endSampleBackoffSeconds) {
      return totalTime - _endSampleBackoffSeconds;
    }

    return rawTime.clamp(0.0, totalTime);
  }

  String _velocityText() {
    final path = widget.simulatedPath;
    if (path == null || path.states.isEmpty || widget.totalPathTime <= 0) {
      return 'v: -- m/s   ω: --°/s';
    }

    final state = path.sample(_displaySampleTime());
    final linear = state.fieldSpeeds.linearVel;
    final omegaDeg = state.fieldSpeeds.omega * 180.0 / pi;

    return 'v: ${linear.toStringAsFixed(2)} m/s   ω: ${omegaDeg.toStringAsFixed(0)}°/s';
  }

  String _num(num value) {
    if (value.isNaN || value.isInfinite) {
      return '';
    }
    return value.toStringAsFixed(6);
  }

  String _csv(List<Object?> values) {
    return values.map((value) {
      final text = value == null ? '' : value.toString();
      if (text.contains(',') || text.contains('"') || text.contains('\n')) {
        return '"${text.replaceAll('"', '""')}"';
      }
      return text;
    }).join(',');
  }

  Future<void> _exportVelocityCsv() async {
    final path = widget.simulatedPath;
    if (path == null || path.states.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No simulated path trajectory to export')),
      );
      return;
    }

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}pathplanner_velocity_debug',
    );
    await directory.create(recursive: true);

    final stateFile = File(
      '${directory.path}${Platform.pathSeparator}trajectory_states_$timestamp.csv',
    );
    final sampleFile = File(
      '${directory.path}${Platform.pathSeparator}trajectory_samples_$timestamp.csv',
    );

    final states = StringBuffer();
    states.writeln(
      'index,time_s,x_m,y_m,rotation_deg,heading_deg,vx_mps,vy_mps,linear_mps,omega_radps,omega_degps,delta_pos_m,constraint_max_vel_mps,constraint_max_accel_mps2',
    );
    for (int i = 0; i < path.states.length; i++) {
      final state = path.states[i];
      states.writeln(_csv([
        i,
        _num(state.timeSeconds),
        _num(state.pose.x),
        _num(state.pose.y),
        _num(state.pose.rotation.degrees),
        _num(state.heading.degrees),
        _num(state.fieldSpeeds.vx),
        _num(state.fieldSpeeds.vy),
        _num(state.fieldSpeeds.linearVel),
        _num(state.fieldSpeeds.omega),
        _num(state.fieldSpeeds.omega * 180.0 / pi),
        _num(state.deltaPos),
        _num(state.constraints.maxVelocityMPS),
        _num(state.constraints.maxAccelerationMPSSq),
      ]));
    }

    final totalTime = path.getTotalTimeSeconds();
    final samples = StringBuffer();
    samples.writeln(
      'sample_index,time_s,x_m,y_m,rotation_deg,vx_mps,vy_mps,linear_mps,omega_radps,omega_degps,note',
    );

    int sampleIndex = 0;
    void writeSample(num time, String note) {
      final clamped = time.clamp(0.0, totalTime);
      final state = path.sample(clamped);
      samples.writeln(_csv([
        sampleIndex++,
        _num(clamped),
        _num(state.pose.x),
        _num(state.pose.y),
        _num(state.pose.rotation.degrees),
        _num(state.fieldSpeeds.vx),
        _num(state.fieldSpeeds.vy),
        _num(state.fieldSpeeds.linearVel),
        _num(state.fieldSpeeds.omega),
        _num(state.fieldSpeeds.omega * 180.0 / pi),
        note,
      ]));
    }

    for (num time = 0.0; time < totalTime; time += 0.02) {
      writeSample(time, '20ms sample');
    }
    writeSample(max(0.0, totalTime - 0.10), 'end minus 100ms');
    writeSample(max(0.0, totalTime - 0.05), 'end minus 50ms');
    writeSample(max(0.0, totalTime - 0.02), 'end minus 20ms');
    writeSample(totalTime, 'exact end');

    await stateFile.writeAsString(states.toString());
    await sampleFile.writeAsString(samples.toString());

    final message = 'Velocity CSV exported to ${directory.path}';
    // ignore: avoid_print
    print(message);
    // ignore: avoid_print
    print('  ${stateFile.path}');
    // ignore: avoid_print
    print('  ${sampleFile.path}');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(left: 8.0, bottom: 8.0),
        child: Card(
          color: colorScheme.surface,
          surfaceTintColor: colorScheme.surfaceTint,
          elevation: 4.0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    setState(() {
                      if (widget.previewController.isAnimating) {
                        widget.previewController.stop();
                        widget.onPauseStateChanged?.call(true);
                      } else {
                        widget.previewController.repeat();
                        widget.onPauseStateChanged?.call(false);
                      }
                    });
                  },
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: widget.previewController.isAnimating
                        ? const Icon(Icons.pause)
                        : const Icon(Icons.play_arrow),
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: widget.previewController.isAnimating ? 'Pause' : 'Play',
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      widget.previewController.reset();
                      widget.previewController.repeat();
                      widget.onPauseStateChanged?.call(false);
                    });
                  },
                  icon: const Icon(Icons.replay),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Restart',
                ),
                Expanded(
                  child: AnimatedBuilder(
                    animation: widget.previewController.view,
                    builder: (context, _) {
                      return Theme(
                        data: Theme.of(context).copyWith(
                          sliderTheme: const SliderThemeData(
                            showValueIndicator: ShowValueIndicator.onDrag,
                            thumbShape: RoundSliderThumbShape(
                              enabledThumbRadius: 8,
                            ),
                            overlayShape: RoundSliderOverlayShape(
                              overlayRadius: 16,
                            ),
                          ),
                        ),
                        child: Slider(
                          value: widget.previewController.value,
                          label: (widget.previewController.value * widget.totalPathTime)
                              .toStringAsFixed(2),
                          onChanged: (value) {
                            if (widget.previewController.isAnimating) {
                              setState(() {
                                widget.previewController.stop();
                              });
                              widget.onPauseStateChanged?.call(true);
                            }
                            widget.previewController.value = value;
                          },
                        ),
                      );
                    },
                  ),
                ),
                AnimatedBuilder(
                  animation: widget.previewController.view,
                  builder: (context, _) {
                    return SizedBox(
                      width: 170,
                      child: Text(
                        _velocityText(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  },
                ),
                IconButton(
                  onPressed: _exportVelocityCsv,
                  icon: const Icon(Icons.file_download_outlined),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Export velocity CSV',
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
