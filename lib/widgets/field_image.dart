import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_size_getter/file_input.dart';
import 'package:image_size_getter/image_size_getter.dart';

enum OfficialField {
  rapidReact,
  chargedUp,
  crescendo,
  reefscape,
  reefscapeAnnotated,
  rebuilt,
}

class FieldImage {
  late final Image image;
  late final ui.Size defaultSize;
  late num pixelsPerMeter;
  late num marginMeters;
  late String name;
  late final bool isCustom;
  late final String extension;

  static List<FieldImage>? _officialFields;

  static final FieldImage defaultField = FieldImage.official(OfficialField.rebuilt);

  static List<FieldImage> offialFields() {
    _officialFields ??= [
      FieldImage.official(OfficialField.rapidReact),
      FieldImage.official(OfficialField.chargedUp),
      FieldImage.official(OfficialField.crescendo),
      FieldImage.official(OfficialField.reefscape),
      FieldImage.official(OfficialField.reefscapeAnnotated),
      FieldImage.official(OfficialField.rebuilt),
    ];
    return _officialFields!;
  }

  FieldImage.official(OfficialField field) {
    switch (field) {
      case OfficialField.rapidReact:
        image = Image.asset(
          'images/field22.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
        defaultSize = const ui.Size(3240, 1620);
        pixelsPerMeter = 196.85;
        name = 'Rapid React';
        marginMeters = 0.0;
        break;
      case OfficialField.chargedUp:
        image = Image.asset(
          'images/field23.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
        defaultSize = const ui.Size(3256, 1578);
        pixelsPerMeter = 196.85;
        name = 'Charged Up';
        marginMeters = 0.0;
        break;
      case OfficialField.crescendo:
        image = Image.asset(
          'images/field24.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
        defaultSize = const ui.Size(3256, 1616);
        pixelsPerMeter = 196.85;
        name = 'Crescendo';
        marginMeters = 0.0;
        break;
      case OfficialField.reefscape:
        image = Image.asset(
          'images/field25.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
        defaultSize = const ui.Size(3510, 1610);
        pixelsPerMeter = 200.0;
        name = 'Reefscape';
        marginMeters = 0.0;
        break;
      case OfficialField.reefscapeAnnotated:
        image = Image.asset(
          'images/field25-annotated.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
        defaultSize = const ui.Size(3510, 1610);
        pixelsPerMeter = 200.0;
        name = 'Reefscape (Annotated)';
        marginMeters = 0.0;
        break;
      case OfficialField.rebuilt:
        image = Image.asset(
          'images/field26.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
        defaultSize = const ui.Size(3508, 1814);
        pixelsPerMeter = 200.0;
        name = 'Rebuilt';
        marginMeters = 0.5;
        break;
    }

    isCustom = false;
    extension = 'png';
  }

  FieldImage.custom(File imageFile) {
    image = Image.file(
      imageFile,
      fit: BoxFit.contain,
    );

    final imageSize = ImageSizeGetter.getSizeResult(FileInput(imageFile)).size;
    if (imageSize.needRotate) {
      defaultSize = ui.Size(
        imageSize.height.toDouble(),
        imageSize.width.toDouble(),
      );
    } else {
      defaultSize = ui.Size(
        imageSize.width.toDouble(),
        imageSize.height.toDouble(),
      );
    }

    final fileName = imageFile.path.split(Platform.pathSeparator).last;
    extension = fileName.substring(fileName.lastIndexOf('.') + 1);

    final baseName = fileName.substring(0, fileName.lastIndexOf('.'));
    final parts = baseName.split('_');

    if (parts.length >= 3 &&
        num.tryParse(parts[parts.length - 1]) != null &&
        num.tryParse(parts[parts.length - 2]) != null) {
      marginMeters = num.parse(parts.last);
      pixelsPerMeter = num.parse(parts[parts.length - 2]);
      name = parts.sublist(0, parts.length - 2).join('_');
    } else if (parts.length >= 2 && num.tryParse(parts.last) != null) {
      marginMeters = 0.0;
      pixelsPerMeter = num.parse(parts.last);
      name = parts.sublist(0, parts.length - 1).join('_');
    } else {
      marginMeters = 0.0;
      pixelsPerMeter = 100.0;
      name = baseName;
    }

    isCustom = true;
  }

  String get customFileName {
    final ppm = pixelsPerMeter.toStringAsFixed(2);
    if (marginMeters == 0.0) {
      return '${name}_$ppm.$extension';
    }

    return '${name}_${ppm}_${marginMeters.toStringAsFixed(2)}.$extension';
  }

  ui.Size getFieldSizeMeters() {
    ui.Offset temp = ((defaultSize / pixelsPerMeter.toDouble()) -
        ui.Size(
          2 * marginMeters.toDouble(),
          2 * marginMeters.toDouble(),
        )) as ui.Offset;

    return ui.Size(temp.dx, temp.dy);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }

    if (other.runtimeType != runtimeType) {
      return false;
    }

    return other is FieldImage && other.name == name;
  }

  @override
  int get hashCode => Object.hash(
        image.hashCode,
        defaultSize.hashCode,
        pixelsPerMeter.hashCode,
        marginMeters.hashCode,
        name.hashCode,
      );

  Widget getWidget() {
    return AspectRatio(
      aspectRatio: defaultSize.width / defaultSize.height,
      child: SizedBox.expand(
        child: image,
      ),
    );
  }
}
