import 'package:flutter/material.dart';
import 'package:pathplanner/widgets/app_settings.dart';
import 'package:pathplanner/widgets/field_image.dart';
import 'package:pathplanner/widgets/robot_config_settings.dart';
import 'package:pathplanner/util/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsDialog extends StatelessWidget {
  final VoidCallback onSettingsChanged;
  final ValueChanged<FieldImage> onFieldSelected;
  final List<FieldImage> fieldImages;
  final FieldImage selectedField;
  final SharedPreferences prefs;
  final ValueChanged<Color> onTeamColorChanged;

  const SettingsDialog({
    required this.onSettingsChanged,
    required this.onFieldSelected,
    required this.fieldImages,
    required this.selectedField,
    required this.prefs,
    required this.onTeamColorChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return DefaultTabController(
      length: 3,
      child: AlertDialog(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
        title: const TabBar(
          tabs: [
            Tab(
              text: 'Robot Config',
            ),
            Tab(
              text: 'App Settings',
            ),
            Tab(
              text: 'Frenzy',
            ),
          ],
        ),
        content: SizedBox(
          width: 800,
          height: 420,
          child: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              RobotConfigSettings(
                onSettingsChanged: onSettingsChanged,
                prefs: prefs,
              ),
              AppSettings(
                onSettingsChanged: onSettingsChanged,
                onFieldSelected: onFieldSelected,
                fieldImages: fieldImages,
                selectedField: selectedField,
                prefs: prefs,
                onTeamColorChanged: onTeamColorChanged,
              ),
              FrenzySettings(
                prefs: prefs,
                onSettingsChanged: onSettingsChanged,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class FrenzySettings extends StatefulWidget {
  final SharedPreferences prefs;
  final VoidCallback onSettingsChanged;

  const FrenzySettings({
    required this.prefs,
    required this.onSettingsChanged,
    super.key,
  });

  @override
  State<FrenzySettings> createState() => _FrenzySettingsState();
}

class _FrenzySettingsState extends State<FrenzySettings> {
  late bool _hasFrenzyDot;

  @override
  void initState() {
    super.initState();
    _hasFrenzyDot =
        widget.prefs.getBool(PrefsKeys.hasFrenzyDot) ?? Defaults.hasFrenzyDot;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SwitchListTile(
          title: const Text('Has Frenzy Dot?'),
          subtitle: const Text(
            'Show the Final Dot options in Frenzy Auto Studio.',
          ),
          value: _hasFrenzyDot,
          onChanged: (value) {
            setState(() {
              _hasFrenzyDot = value;
            });
            widget.prefs.setBool(PrefsKeys.hasFrenzyDot, value);
            widget.onSettingsChanged();
          },
        ),
      ],
    );
  }
}
