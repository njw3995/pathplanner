import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pathplanner/widgets/keyboard_shortcuts.dart';

class ImportFieldDialog extends StatefulWidget {
  final Function(
    String name,
    double pixelsPerMeter,
    double marginMeters,
    File imageFile,
  ) onImport;

  const ImportFieldDialog({
    required this.onImport,
    super.key,
  });

  @override
  State<ImportFieldDialog> createState() => _ImportFieldDialogState();
}

class _ImportFieldDialogState extends State<ImportFieldDialog> {
  late TextEditingController _nameController;
  late TextEditingController _ppmController;
  late TextEditingController _marginController;
  File? _selectedFile;

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController(text: 'Custom Field');
    _nameController.selection = TextSelection.fromPosition(
      TextPosition(offset: _nameController.text.length),
    );

    _ppmController = TextEditingController(text: '100');
    _ppmController.selection = TextSelection.fromPosition(
      TextPosition(offset: _ppmController.text.length),
    );

    _marginController = TextEditingController(text: '0.00');
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
        title: const Text('Import Custom Field'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
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
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Row(
                    children: [
                      const Text('Image: '),
                      Flexible(
                        child: (_selectedFile == null)
                            ? Text(
                                'None Selected',
                                style: TextStyle(color: colorScheme.error),
                              )
                            : Text(
                                _selectedFile!.path
                                    .split(Platform.pathSeparator)
                                    .last,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: colorScheme.primary),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () async {
                    const typeGroup = XTypeGroup(
                      label: 'images',
                      extensions: ['jpg', 'png'],
                    );
                    final file = await openFile(
                      acceptedTypeGroups: [typeGroup],
                      initialDirectory: Directory.current.path,
                    );
                    if (file != null) {
                      setState(() {
                        _selectedFile = File(file.path);
                      });
                    }
                  },
                  child: const Text('Choose File'),
                ),
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

  void confirm(BuildContext context) {
    if (_nameController.text.isNotEmpty &&
        _ppmController.text.isNotEmpty &&
        _marginController.text.isNotEmpty &&
        _selectedFile != null) {
      Navigator.of(context).pop();
      widget.onImport.call(
        _nameController.text,
        double.parse(_ppmController.text),
        double.parse(_marginController.text),
        _selectedFile!,
      );
    }
  }
}
