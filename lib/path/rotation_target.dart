import 'package:pathplanner/util/wpimath/geometry.dart';

class RotationTarget {
  num waypointRelativePos;
  Rotation2d rotation;
  final bool displayInEditor;
  String? name;

  RotationTarget(
    this.waypointRelativePos,
    this.rotation, [
    this.displayInEditor = true,
    this.name,
  ]);

  RotationTarget.fromJson(Map json)
      : this(
          json['waypointRelativePos'] ?? 0.5,
          Rotation2d.fromDegrees(json['rotationDegrees'] ?? 0),
          true,
          json['name'],
        );

  Map toJson() {
    return {
      if (name != null && name!.trim().isNotEmpty) 'name': name!.trim(),
      'waypointRelativePos': waypointRelativePos,
      'rotationDegrees': rotation.degrees,
    };
  }

  RotationTarget clone() {
    return RotationTarget(waypointRelativePos, rotation, displayInEditor, name);
  }

  @override
  bool operator ==(Object other) =>
      other is RotationTarget &&
      other.runtimeType == runtimeType &&
      other.waypointRelativePos == waypointRelativePos &&
      other.rotation == rotation &&
      other.name == name;

  @override
  int get hashCode => Object.hash(waypointRelativePos, rotation, name);

  @override
  String toString() {
    return 'RotationTarget($waypointRelativePos, $rotation, $name)';
  }
}
