import 'dart:collection';

import 'package:pathplanner/util/wpimath/geometry.dart';

class PointTowardsZone {
  static HashMap<String, Translation2d> linkedTargets = HashMap();

  Translation2d fieldPosition;
  Rotation2d rotationOffset;

  num minWaypointRelativePos;
  num maxWaypointRelativePos;

  String name;
  String? linkedName;

  PointTowardsZone({
    this.fieldPosition = const Translation2d(0.4, 5.5),
    this.rotationOffset = const Rotation2d(),
    this.minWaypointRelativePos = 0.25,
    this.maxWaypointRelativePos = 0.75,
    this.name = 'Point Towards Zone',
    this.linkedName,
  }) {
    final link = linkedName?.trim();

    if (link != null && link.isNotEmpty) {
      linkedName = link;

      if (linkedTargets.containsKey(link)) {
        fieldPosition = linkedTargets[link]!;
      } else {
        linkedTargets[link] = fieldPosition;
      }
    } else {
      linkedName = null;
    }
  }

  PointTowardsZone.fromJson(Map<String, dynamic> json)
      : this(
          fieldPosition: Translation2d.fromJson(json['fieldPosition']),
          rotationOffset: Rotation2d.fromDegrees(json['rotationOffset']),
          minWaypointRelativePos: json['minWaypointRelativePos'],
          maxWaypointRelativePos: json['maxWaypointRelativePos'],
          name: json['name'],
          linkedName: json['linkedName'],
        );

  bool get isLinked => linkedName != null && linkedName!.trim().isNotEmpty;

  Translation2d get targetPosition {
    final link = linkedName?.trim();

    if (link != null && link.isNotEmpty && linkedTargets.containsKey(link)) {
      return linkedTargets[link]!;
    }

    return fieldPosition;
  }

  void setTargetPosition(Translation2d position) {
    fieldPosition = position;

    final link = linkedName?.trim();
    if (link != null && link.isNotEmpty) {
      linkedTargets[link] = position;
    }
  }

  void setLinkedName(String? linkName) {
    final cleanedName = linkName?.trim();

    if (cleanedName == null || cleanedName.isEmpty) {
      linkedName = null;
      return;
    }

    linkedName = cleanedName;

    if (linkedTargets.containsKey(cleanedName)) {
      fieldPosition = linkedTargets[cleanedName]!;
    } else {
      linkedTargets[cleanedName] = fieldPosition;
    }
  }

  PointTowardsZone clone() {
    return PointTowardsZone(
      fieldPosition: fieldPosition,
      rotationOffset: rotationOffset,
      minWaypointRelativePos: minWaypointRelativePos,
      maxWaypointRelativePos: maxWaypointRelativePos,
      name: name,
      linkedName: linkedName,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fieldPosition': targetPosition.toJson(),
      'rotationOffset': rotationOffset.degrees,
      'minWaypointRelativePos': minWaypointRelativePos,
      'maxWaypointRelativePos': maxWaypointRelativePos,
      'name': name,
      if (linkedName != null && linkedName!.trim().isNotEmpty)
        'linkedName': linkedName!.trim(),
    };
  }

  @override
  bool operator ==(Object other) {
    return other is PointTowardsZone &&
        other.runtimeType == runtimeType &&
        other.fieldPosition == fieldPosition &&
        other.rotationOffset == rotationOffset &&
        other.minWaypointRelativePos == minWaypointRelativePos &&
        other.maxWaypointRelativePos == maxWaypointRelativePos &&
        other.name == name &&
        other.linkedName == linkedName;
  }

  @override
  int get hashCode => Object.hash(fieldPosition, rotationOffset,
      minWaypointRelativePos, maxWaypointRelativePos, name, linkedName);
}
