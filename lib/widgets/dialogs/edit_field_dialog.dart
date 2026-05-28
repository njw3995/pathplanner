import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/keyboard_shortcuts.dart';

class EditFieldDialog extends StatefulWidget {
  final FieldImage fieldImage;

  const EditFieldDialog({
    required this.fieldImage,
    super.key,
  });

  @override
  State<EditFieldDialog> createState() => _EditFieldDialogState();
}

class _EditFieldDialogState extends State<EditFieldDialog> {
  late TextEditingController _nameController;
  late TextEditingController _ppmController;
  late TextEditingController _marginController;

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController(text: widget.fieldImage.name);
    _nameController.selection = TextSelection.fromPosition(
      TextPosition(offset: _nameController.text.length),
    );

    _ppmController = TextEditingController(
      text: widget.fieldImage.pixelsPerMeter.toStringAsFixed(2),
    );
    _ppmController.selection = TextSelection.fromPosition(
      TextPosition(offset: _ppmController.text.length),
    );

    _marginController = TextEditingController(
      text: widget.fieldImage.marginMeters.toStringAsFixed(2),
    );
    _marginController.selection = TextSelection.fromPosition(
      TextPosition(offset: _marginController.text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return KeyBoardShortcuts(
      keysToPress: {LogicalKeyboardKey.enter},
      onKeysPressed: () => confirm(context),
      child: AlertDialog(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
        title: const Text('Edit Custom Field'),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _textField(
              controller: _nameController,
              label: 'Field Name',
              width: 190,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp('["*<>?|/:\\\\]')),
              ],
            ),
            const SizedBox(width: 12),
            _textField(
              controller: _ppmController,
              label: 'Pixels Per Meter',
              width: 150,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'(^\d*\.?\d*)')),
              ],
            ),
            const SizedBox(width: 12),
            _textField(
              controller: _marginController,
              label: 'Margin (m)',
              width: 120,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'(^\d*\.?\d*)')),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => confirm(context),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required double width,
    required List<TextInputFormatter> inputFormatters,
  }) {
    return SizedBox(
      height: 42,
      width: width,
      child: TextField(
        controller: controller,
        inputFormatters: inputFormatters,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          labelText: label,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  void confirm(BuildContext context) async {
    if (_nameController.text.isNotEmpty &&
        _ppmController.text.isNotEmpty &&
        _marginController.text.isNotEmpty) {
      Navigator.of(context).pop();

      final oldFileName = widget.fieldImage.customFileName;
      final name = _nameController.text;
      final ppm = double.parse(_ppmController.text);
      final margin = double.parse(_marginController.text);

      Directory appDir = await getApplicationSupportDirectory();
      Directory imagesDir = Directory(join(appDir.path, 'custom_fields'));
      File imageFile = File(join(imagesDir.path, oldFileName));

      widget.fieldImage.name = name;
      widget.fieldImage.pixelsPerMeter = ppm;
      widget.fieldImage.marginMeters = margin;

      await imageFile.rename(
        join(imagesDir.path, widget.fieldImage.customFileName),
      );
    }
  }
}
