import 'package:flutter/material.dart';
import 'package:pathplanner/trajectory/trajectory.dart';

class GhostAutoPauseAnchor {
  final String id;
  final String label;
  final double seconds;

  const GhostAutoPauseAnchor({
    required this.id,
    required this.label,
    required this.seconds,
  });
}

class GhostAutoPauseBlock {
  static const String holdMode = 'hold';
  static const String slowZoneMode = 'slowZone';

  final String id;
  double afterSeconds;
  double durationSeconds;
  String label;
  String? anchorId;
  String? anchorLabel;
  String mode;
  double slowWindowSeconds;

  GhostAutoPauseBlock({
    required this.id,
    required this.afterSeconds,
    required this.durationSeconds,
    required this.label,
    this.anchorId,
    this.anchorLabel,
    this.mode = holdMode,
    this.slowWindowSeconds = 1.0,
  });
}

double timelineSecondsToTrajectorySeconds({
  required double timelineSeconds,
  required double trajectoryDurationSeconds,
  required List<GhostAutoPauseBlock> pauses,
}) {
  double consumedExtraSeconds = 0.0;
  final sortedPauses = List<GhostAutoPauseBlock>.of(pauses)
    ..sort((a, b) => a.afterSeconds.compareTo(b.afterSeconds));

  for (final pause in sortedPauses) {
    if (pause.durationSeconds <= 0.0) {
      continue;
    }

    if (pause.mode == GhostAutoPauseBlock.slowZoneMode) {
      final slowWindow = pause.slowWindowSeconds.clamp(
        0.05,
        trajectoryDurationSeconds <= 0.0 ? 0.05 : trajectoryDurationSeconds,
      );

      final center = pause.afterSeconds.clamp(0.0, trajectoryDurationSeconds);
      final nativeStart = (center - (slowWindow / 2.0)).clamp(
        0.0,
        trajectoryDurationSeconds,
      );
      final nativeEnd = (center + (slowWindow / 2.0)).clamp(
        0.0,
        trajectoryDurationSeconds,
      );
      final nativeDuration = nativeEnd - nativeStart;

      if (nativeDuration <= 0.0) {
        continue;
      }

      final timelineStart = nativeStart + consumedExtraSeconds;
      final timelineEnd =
          nativeEnd + consumedExtraSeconds + pause.durationSeconds;

      if (timelineSeconds < timelineStart) {
        return (timelineSeconds - consumedExtraSeconds).clamp(
          0.0,
          trajectoryDurationSeconds,
        );
      }

      if (timelineSeconds <= timelineEnd) {
        final pct =
            ((timelineSeconds - timelineStart) / (timelineEnd - timelineStart))
                .clamp(0.0, 1.0);

        // Smoothly stretch this section of the trajectory. This is not a full
        // physics re-generation, but it makes the robot visibly slow through
        // the selected area instead of snapping to a frozen point.
        final eased = _smoothStep(pct);
        return nativeStart + (nativeDuration * eased);
      }

      consumedExtraSeconds += pause.durationSeconds;
      continue;
    }

    final pauseAt = pause.afterSeconds.clamp(0.0, trajectoryDurationSeconds);
    final pauseStartTimeline = pauseAt + consumedExtraSeconds;
    final pauseEndTimeline = pauseStartTimeline + pause.durationSeconds;

    if (timelineSeconds < pauseStartTimeline) {
      return (timelineSeconds - consumedExtraSeconds).clamp(
        0.0,
        trajectoryDurationSeconds,
      );
    }

    if (timelineSeconds <= pauseEndTimeline) {
      return pauseAt;
    }

    consumedExtraSeconds += pause.durationSeconds;
  }

  return (timelineSeconds - consumedExtraSeconds).clamp(
    0.0,
    trajectoryDurationSeconds,
  );
}

double _smoothStep(double x) {
  return x * x * (3.0 - (2.0 * x));
}

class GhostAutoOverlay {
  final String name;
  final PathPlannerTrajectory trajectory;
  final Color color;
  final List<GhostAutoPauseBlock> pauses;
  final List<GhostAutoPauseAnchor> pauseAnchors;
  bool visible;

  GhostAutoOverlay({
    required this.name,
    required this.trajectory,
    required this.color,
    List<GhostAutoPauseBlock>? pauses,
    List<GhostAutoPauseAnchor>? pauseAnchors,
    this.visible = true,
  })  : pauses = pauses ?? [],
        pauseAnchors = pauseAnchors ?? [];

  double get nativeTimeSeconds {
    if (trajectory.states.isEmpty) {
      return 0.0;
    }

    return trajectory.states.last.timeSeconds.toDouble();
  }

  double get totalTimeSeconds {
    double total = nativeTimeSeconds;
    for (final pause in pauses) {
      if (pause.durationSeconds > 0.0) {
        total += pause.durationSeconds;
      }
    }
    return total;
  }

  double trajectoryTimeForPreview(double previewSeconds) {
    return timelineSecondsToTrajectorySeconds(
      timelineSeconds: previewSeconds,
      trajectoryDurationSeconds: nativeTimeSeconds,
      pauses: pauses,
    );
  }
}
