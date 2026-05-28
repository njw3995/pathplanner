import 'package:pathplanner/auto_builder/auto_spec.dart';
import 'package:pathplanner/commands/command.dart';
import 'package:pathplanner/commands/command_groups.dart';
import 'package:pathplanner/commands/named_command.dart';
import 'package:pathplanner/commands/path_command.dart';

const String namedPrepare = 'Prepare Intake';
const String namedStopIntake = 'Stop Intake';
const String namedShoot = 'Shoot Hub';
const String namedLower = 'Lower Hood And Stop Shooting';
const String namedSetCoast = 'Set Coast';
const String namedTunableWait = 'Tunable Wait';
const String namedIdleShooter = 'Idle Shooter';

const Map<String, String> aSweepPaths = {
  'MidA': 'Pass2_MidSweepA',
  'CloseA': 'Pass2_CloseSweepA',
  'FarA': 'Pass2_FarSweepA',
  'RiskA': 'Pass2_RiskSweepA',
};

const Map<String, String> bSweepPaths = {
  'MidB': 'Pass2_MidSweepB',
  'CloseB': 'Pass2_CloseSweepB',
  'FarB': 'Pass2_FarSweepB',
  'RiskB': 'Pass2_RiskSweepB',
};

const Map<String, String> dotPaths = {
  'center': 'Shoot - Center',
  'close': 'Shoot - Close',
};

const Map<String, String> zeroDotPaths = {
  'center': 'Close - Center',
  'close': 'Close - Close',
};

const Map<String, String> sneakyDotPaths = {
  'center': 'Sneaky - Center',
  'close': 'Sneaky - Close',
};

class FirstPassPaths {
  final String readable;
  final String start;
  final String sweep;
  final String returnPath;

  const FirstPassPaths(this.readable, this.start, this.sweep, this.returnPath);
}

class SweepChain {
  final String readable;
  final List<String> paths;
  final String endToken;

  const SweepChain(this.readable, this.paths, this.endToken);
}

class BattlecryAutoGenerationResult {
  final SequentialCommandGroup sequence;
  final List<String> warnings;
  final List<String> pathNames;
  final List<String> namedCommandNames;

  const BattlecryAutoGenerationResult({
    required this.sequence,
    required this.warnings,
    required this.pathNames,
    required this.namedCommandNames,
  });
}

class BattlecryAutoImportResult {
  final BattlecryAutoSpec spec;
  final Map<String, String> pathCopyMap;
  final List<String> warnings;

  const BattlecryAutoImportResult({
    required this.spec,
    required this.pathCopyMap,
    required this.warnings,
  });
}

class _ParsedSweepSpec {
  final BattlecryPassSpec pass;
  final String endToken;

  const _ParsedSweepSpec(this.pass, this.endToken);
}

class _ParsedReturningPass {
  final BattlecryPassSpec pass;
  final int nextIndex;

  const _ParsedReturningPass(this.pass, this.nextIndex);
}

class BattlecryAutoGenerator {
  static BattlecryAutoGenerationResult generate(BattlecryAutoSpec spec) {
    final commands = <Command>[];
    final warnings = <String>[];

    final hasSneakyStart =
        spec.passes.isNotEmpty && spec.passes.first.start == 'sneaky';

    if (hasSneakyStart) {
      return _generateSneakyAuto(spec, warnings);
    }

    int shotCount = 0;
    for (int index = 0; index < spec.passes.length; index++) {
      final pass = spec.passes[index];

      if (index == 0) {
        final first = firstPassPaths(
          risk: pass.risky,
          greedy: pass.greedy,
          hub: pass.hub,
        );
        commands.addAll([
          _named(namedPrepare),
          _path(first.start),
          _path(first.sweep),
          _path(first.returnPath),
        ]);
      } else {
        commands.addAll(_returningSecondPassCommands(
          pass: pass,
          includePassStart: true,
        ));
      }

      commands.addAll([
        _named(namedShoot),
        _named(namedLower),
      ]);
      shotCount++;
    }

    _appendFinalCommands(commands, spec.finalSpec, shotCount);

    if (commands.isEmpty) {
      throw StateError('Add at least one pass or a final pass.');
    }

    return _result(commands, warnings);
  }

  static BattlecryAutoGenerationResult _generateSneakyAuto(
    BattlecryAutoSpec spec,
    List<String> warnings,
  ) {
    final commands = <Command>[];
    final finalSpec = spec.finalSpec;

    if (spec.passes.length == 1 && finalSpec == null) {
      return _result(commands, warnings);
    }

    if (spec.passes.length == 1 && finalSpec?.type == 'dot') {
      final dot = _normalizeDot(finalSpec?.dot ?? 'center');
      commands.addAll([
        _named(namedTunableWait),
        _path(sneakyDotPaths[dot]!),
        _named(namedIdleShooter),
      ]);
      return _result(commands, warnings);
    }

    commands.addAll([
      _named(namedTunableWait),
      _path('Pass1 Sneaky Start'),
    ]);

    int shotCount = 0;

    if (spec.passes.length > 1) {
      for (int index = 1; index < spec.passes.length; index++) {
        final pass = spec.passes[index];
        commands.addAll(_returningSecondPassCommands(
          pass: pass,
          includePassStart: index != 1,
        ));
        commands.addAll([
          _named(namedShoot),
          _named(namedLower),
        ]);
        shotCount++;
      }
    }

    if (finalSpec != null) {
      if (finalSpec.type == 'dot') {
        final dot = _normalizeDot(finalSpec.dot);
        if (shotCount > 0) {
          commands.add(_path(dotPaths[dot]!));
        } else {
          commands.addAll([
            _path(sneakyDotPaths[dot]!),
            _named(namedIdleShooter),
          ]);
        }
      } else {
        final finalPassAsPass = BattlecryPassSpec(
          risky: finalSpec.risky,
          greedy: finalSpec.greedy,
          hub: finalSpec.hub,
          route: finalSpec.route,
        );
        final sweep = parseChainLabel(_chainFromPass(finalPassAsPass));
        commands.addAll([
          _named(namedPrepare),
          _named(namedSetCoast),
          for (final pathName in sweep.paths) _path(pathName),
          _named(namedStopIntake),
        ]);
      }
    }

    return _result(commands, warnings);
  }

  static List<Command> _returningSecondPassCommands({
    required BattlecryPassSpec pass,
    required bool includePassStart,
  }) {
    final sweep = parseChainLabel(_chainFromPass(pass));
    return [
      _named(namedPrepare),
      if (includePassStart) _path('Pass_Start'),
      for (final pathName in sweep.paths) _path(pathName),
      for (final pathName in returnPathsForSecond(
        sweep.endToken,
        pass.localize,
      ))
        _path(pathName),
    ];
  }

  static void _appendFinalCommands(
    List<Command> commands,
    BattlecryFinalSpec? finalSpec,
    int shotCount,
  ) {
    if (finalSpec == null) {
      return;
    }

    if (finalSpec.type == 'dot') {
      final dot = _normalizeDot(finalSpec.dot);
      if (shotCount > 0) {
        commands.add(_path(dotPaths[dot]!));
      } else {
        commands.addAll([
          _path(zeroDotPaths[dot]!),
          _named(namedIdleShooter),
        ]);
      }
      return;
    }

    final finalPassAsPass = BattlecryPassSpec(
      risky: finalSpec.risky,
      greedy: finalSpec.greedy,
      hub: finalSpec.hub,
      route: finalSpec.route,
    );
    final sweep = parseChainLabel(_chainFromPass(finalPassAsPass));
    commands.addAll([
      _named(namedPrepare),
      _path('Pass_Start'),
      _named(namedSetCoast),
      for (final pathName in sweep.paths) _path(pathName),
      _named(namedStopIntake),
    ]);
  }

  static BattlecryAutoImportResult parseExistingAuto(
    SequentialCommandGroup sequence,
  ) {
    final commands = sequence.commands;
    final passes = <BattlecryPassSpec>[];
    BattlecryFinalSpec? finalSpec;
    final pathCopyMap = <String, String>{};
    final warnings = <String>[];

    if (commands.isEmpty) {
      return BattlecryAutoImportResult(
        spec: BattlecryAutoSpec(
          passes: [BattlecryPassSpec(start: 'sneaky')],
          finalSpec: null,
        ),
        pathCopyMap: pathCopyMap,
        warnings: const ['Imported an empty auto as Sneaky + None.'],
      );
    }

    int index = 0;

    if (commands.length >= 3 && _commandNamed(commands[0], namedTunableWait)) {
      final firstPath = _commandPathName(commands[1], pathCopyMap);
      if (sneakyDotPaths.containsValue(firstPath)) {
        final dot = _dotForPath(firstPath!, sneakyDotPaths);
        return BattlecryAutoImportResult(
          spec: BattlecryAutoSpec(
            passes: [BattlecryPassSpec(start: 'sneaky')],
            finalSpec: BattlecryFinalSpec(type: 'dot', dot: dot),
          ),
          pathCopyMap: pathCopyMap,
          warnings: warnings,
        );
      }

      if (firstPath == 'Pass1 Sneaky Start') {
        passes.add(BattlecryPassSpec(start: 'sneaky'));
        index = 2;

        while (index < commands.length) {
          if (_commandNamed(commands[index], namedPrepare)) {
            final afterPrepare = index + 1 < commands.length
                ? _commandPathName(commands[index + 1], pathCopyMap)
                : null;

            if (index + 1 < commands.length &&
                _commandNamed(commands[index + 1], namedSetCoast)) {
              final parsedFinal = _parseFinalSweep(
                commands,
                index,
                pathCopyMap,
                sneakyFinal: true,
              );
              finalSpec = parsedFinal.finalSpec;
              index = parsedFinal.nextIndex;
              continue;
            }

            if (afterPrepare == 'Pass_Start') {
              final parsed = _parseReturningSecondPass(
                commands,
                index,
                pathCopyMap,
                includePassStart: true,
              );
              passes.add(parsed.pass);
              index = parsed.nextIndex;
              continue;
            }

            if (afterPrepare != null) {
              final parsed = _parseReturningSecondPass(
                commands,
                index,
                pathCopyMap,
                includePassStart: false,
              );
              passes.add(parsed.pass);
              index = parsed.nextIndex;
              continue;
            }
          }

          final pathName = _commandPathName(commands[index], pathCopyMap);
          if (pathName != null && dotPaths.containsValue(pathName)) {
            finalSpec = BattlecryFinalSpec(
              type: 'dot',
              dot: _dotForPath(pathName, dotPaths),
            );
            index++;
            continue;
          }

          if (pathName != null && sneakyDotPaths.containsValue(pathName)) {
            finalSpec = BattlecryFinalSpec(
              type: 'dot',
              dot: _dotForPath(pathName, sneakyDotPaths),
            );
            index++;
            continue;
          }

          if (_commandNamed(commands[index], namedIdleShooter)) {
            index++;
            continue;
          }

          throw StateError(
            'custom sneaky auto selected, cannot parse into Auto Studio builder controls',
          );
        }

        if (pathCopyMap.isNotEmpty) {
          warnings.add(
            'Imported copied path names and will keep using those copied paths.',
          );
        }

        return BattlecryAutoImportResult(
          spec: BattlecryAutoSpec(
            passes: passes,
            finalSpec: finalSpec,
          ),
          pathCopyMap: pathCopyMap,
          warnings: warnings,
        );
      }
    }

    index = 0;
    while (index < commands.length) {
      if (_commandNamed(commands[index], namedPrepare)) {
        final nextPath = index + 1 < commands.length
            ? _commandPathName(commands[index + 1], pathCopyMap)
            : null;

        if (nextPath == 'Pass1_Safe_Start' ||
            nextPath == 'Pass1_Risk_Start') {
          if (index + 5 >= commands.length) {
            throw StateError('first pass is incomplete');
          }

          final startPath = nextPath!;
          final sweepPath = _commandPathName(commands[index + 2], pathCopyMap);
          final returnPath = _commandPathName(commands[index + 3], pathCopyMap);

          if (sweepPath == null || returnPath == null) {
            throw StateError('first pass is missing sweep or return');
          }

          passes.add(_parseFirstPass(startPath, sweepPath, returnPath));

          if (!_commandNamed(commands[index + 4], namedShoot) ||
              !_commandNamed(commands[index + 5], namedLower)) {
            throw StateError('first pass is missing shoot/lower commands');
          }

          index += 6;
          continue;
        }

        if (nextPath == 'Pass_Start') {
          if (index + 2 < commands.length &&
              _commandNamed(commands[index + 2], namedSetCoast)) {
            final parsedFinal = _parseFinalSweep(
              commands,
              index,
              pathCopyMap,
              sneakyFinal: false,
            );
            finalSpec = parsedFinal.finalSpec;
            index = parsedFinal.nextIndex;
            continue;
          }

          final parsed = _parseReturningSecondPass(
            commands,
            index,
            pathCopyMap,
            includePassStart: true,
          );
          passes.add(parsed.pass);
          index = parsed.nextIndex;
          continue;
        }
      }

      final pathName = _commandPathName(commands[index], pathCopyMap);
      if (pathName != null && dotPaths.containsValue(pathName)) {
        finalSpec = BattlecryFinalSpec(
          type: 'dot',
          dot: _dotForPath(pathName, dotPaths),
        );
        index++;
        continue;
      }

      if (pathName != null && zeroDotPaths.containsValue(pathName)) {
        finalSpec = BattlecryFinalSpec(
          type: 'dot',
          dot: _dotForPath(pathName, zeroDotPaths),
        );
        index++;
        continue;
      }

      if (_commandNamed(commands[index], namedIdleShooter)) {
        index++;
        continue;
      }

      throw StateError(
        'custom auto selected, cannot parse into Auto Studio builder controls',
      );
    }

    if (passes.isEmpty && finalSpec == null) {
      throw StateError(
        'custom auto selected, cannot parse into Auto Studio builder controls',
      );
    }

    if (pathCopyMap.isNotEmpty) {
      warnings.add(
        'Imported copied path names and will keep using those copied paths.',
      );
    }

    return BattlecryAutoImportResult(
      spec: BattlecryAutoSpec(
        passes: passes,
        finalSpec: finalSpec,
      ),
      pathCopyMap: pathCopyMap,
      warnings: warnings,
    );
  }

  static _ParsedReturningPass _parseReturningSecondPass(
    List<Command> commands,
    int index,
    Map<String, String> pathCopyMap, {
    required bool includePassStart,
  }) {
    if (!_commandNamed(commands[index], namedPrepare)) {
      throw StateError('second pass is missing Prepare Intake');
    }

    index++;

    if (includePassStart) {
      final passStart = _commandPathName(commands[index], pathCopyMap);
      if (passStart != 'Pass_Start') {
        throw StateError('second pass is missing Pass_Start');
      }
      index++;
    }

    final sweepPaths = <String>[];
    while (index < commands.length) {
      final pathName = _commandPathName(commands[index], pathCopyMap);
      if (pathName == null || _isSecondPassReturnPath(pathName)) {
        break;
      }
      sweepPaths.add(pathName);
      index++;
    }

    final parsed = _parseChainFromPaths(sweepPaths);
    bool localize = true;

    if (index < commands.length) {
      final localizePath = _commandPathName(commands[index], pathCopyMap);
      if (localizePath != null &&
          (localizePath.endsWith('-Localize') ||
              localizePath.endsWith('-NoLocalize'))) {
        localize = !localizePath.endsWith('-NoLocalize');
        index++;
      }
    }

    if (index < commands.length) {
      final returnPath = _commandPathName(commands[index], pathCopyMap);
      if (returnPath != null && _isSecondPassReturnCommand(returnPath)) {
        if (returnPath.contains('NoLocalize_Return')) {
          localize = false;
        }
        index++;
      }
    }

    if (index + 1 >= commands.length ||
        !_commandNamed(commands[index], namedShoot) ||
        !_commandNamed(commands[index + 1], namedLower)) {
      throw StateError('second pass is missing shoot/lower commands');
    }

    parsed.pass.localize = localize;
    index += 2;

    return _ParsedReturningPass(parsed.pass, index);
  }

  static _ParsedFinalSweep _parseFinalSweep(
    List<Command> commands,
    int index,
    Map<String, String> pathCopyMap, {
    required bool sneakyFinal,
  }) {
    if (!_commandNamed(commands[index], namedPrepare)) {
      throw StateError('final sweep is missing Prepare Intake');
    }
    index++;

    if (!sneakyFinal) {
      final passStart = _commandPathName(commands[index], pathCopyMap);
      if (passStart != 'Pass_Start') {
        throw StateError('final sweep is missing Pass_Start');
      }
      index++;
    }

    if (!_commandNamed(commands[index], namedSetCoast)) {
      throw StateError('final sweep is missing Set Coast');
    }
    index++;

    final sweepPaths = <String>[];
    while (index < commands.length) {
      final pathName = _commandPathName(commands[index], pathCopyMap);
      if (pathName == null) {
        break;
      }
      sweepPaths.add(pathName);
      index++;
    }

    final parsed = _parseChainFromPaths(sweepPaths);

    if (index < commands.length && _commandNamed(commands[index], namedStopIntake)) {
      index++;
    }

    return _ParsedFinalSweep(
      BattlecryFinalSpec(
        type: 'sweep',
        risky: parsed.pass.risky,
        greedy: parsed.pass.greedy,
        hub: parsed.pass.hub,
        route: parsed.pass.route,
      ),
      index,
    );
  }

  static FirstPassPaths firstPassPaths({
    required bool risk,
    required bool greedy,
    required bool hub,
  }) {
    final side = risk ? 'Risk' : 'Safe';
    final greed = greedy ? 'Greedy' : '';
    final hubText = hub ? 'Hub' : 'NoHub';
    final readable =
        'P1 ${risk ? "Risk" : "Safe"} ${greedy ? "Greedy" : "NG"} ${hub ? "Hub" : "NoHub"}';
    return FirstPassPaths(
      readable,
      'Pass1_${side}_Start',
      'Pass1_${greed}${side}_Sweep',
      'Pass1_${greed}${side}${hubText}_Return',
    );
  }

  static SweepChain parseChainLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('empty sweep chain');
    }

    final explicitGreedy = trimmed.startsWith('Greedy_');
    final cleanLabel =
        explicitGreedy ? trimmed.substring('Greedy_'.length) : trimmed;

    if (aSweepPaths.containsKey(cleanLabel)) {
      return SweepChain(
        '${explicitGreedy ? "Greedy " : ""}$cleanLabel',
        [aSweepPaths[cleanLabel]!],
        cleanLabel,
      );
    }

    final match =
        RegExp(r'^(MidA|CloseA|FarA|RiskA)-(MidB|CloseB|FarB|RiskB)$')
            .firstMatch(cleanLabel);
    if (match == null) {
      throw ArgumentError(
        'Could not parse sweep chain "$label". Use MidA, RiskA, MidA-RiskB, Greedy_MidA-RiskB, etc.',
      );
    }

    final aToken = match.group(1)!;
    final bToken = match.group(2)!;
    final connector =
        explicitGreedy ? 'Greedy_$aToken-$bToken' : '$aToken-$bToken';
    final bPath =
        explicitGreedy ? 'Greedy_${bSweepPaths[bToken]!}' : bSweepPaths[bToken]!;

    return SweepChain(
      '${explicitGreedy ? "Greedy " : ""}$aToken-$bToken',
      [aSweepPaths[aToken]!, connector, bPath],
      bToken,
    );
  }

  static List<String> returnPathsForSecond(String endToken, bool localize) {
    final loc = localize ? 'Localize' : 'NoLocalize';
    if (endToken.endsWith('B')) {
      return ['$endToken-$loc', 'Pass2_${endToken}_${loc}_Return'];
    }
    return ['Pass2_${loc}_Return'];
  }

  static List<String> collectPathNames(Command command) {
    final names = <String>[];
    void walk(Command cmd) {
      if (cmd is PathCommand && cmd.pathName != null) {
        names.add(cmd.pathName!);
      } else if (cmd is CommandGroup) {
        for (final child in cmd.commands) {
          walk(child);
        }
      }
    }

    walk(command);
    return names;
  }

  static List<String> collectNamedCommandNames(Command command) {
    final names = <String>[];
    void walk(Command cmd) {
      if (cmd is NamedCommand && cmd.name != null) {
        names.add(cmd.name!);
      } else if (cmd is CommandGroup) {
        for (final child in cmd.commands) {
          walk(child);
        }
      }
    }

    walk(command);
    return names;
  }

  static Command _named(String name) => NamedCommand(name: name);

  static Command _path(String name) => PathCommand(pathName: name);

  static String _normalizeDot(String dot) {
    return dotPaths.containsKey(dot) ? dot : 'center';
  }

  static String _routeToKey(String value) {
    return value == 'Close -> Far' ? 'close-far' : 'far-close';
  }

  static String _chainFromPass(BattlecryPassSpec pass) {
    final near = pass.hub ? 'Close' : 'Mid';
    final far = pass.risky ? 'Risk' : 'Far';
    final route = _routeToKey(pass.route);
    final chain =
        route == 'far-close' ? '${far}A-${near}B' : '${near}A-${far}B';
    return pass.greedy ? 'Greedy_$chain' : chain;
  }

  static BattlecryAutoGenerationResult _result(
    List<Command> commands,
    List<String> warnings,
  ) {
    final sequence = SequentialCommandGroup(commands: commands);
    return BattlecryAutoGenerationResult(
      sequence: sequence,
      warnings: warnings,
      pathNames: collectPathNames(sequence),
      namedCommandNames: collectNamedCommandNames(sequence),
    );
  }

  static String? _commandPathName(
    Command command,
    Map<String, String> pathCopyMap,
  ) {
    if (command is! PathCommand || command.pathName == null) {
      return null;
    }

    final rawPathName = command.pathName!;
    final canonical = _canonicalGeneratedPath(rawPathName);

    if (canonical != rawPathName) {
      pathCopyMap[canonical] = rawPathName;
    }

    return canonical;
  }

  static bool _commandNamed(Command command, String name) {
    return command is NamedCommand && command.name == name;
  }

  static BattlecryPassSpec _parseFirstPass(
    String startPath,
    String sweepPath,
    String returnPath,
  ) {
    if (startPath != 'Pass1_Safe_Start' && startPath != 'Pass1_Risk_Start') {
      throw StateError('expected Pass1 start path, got $startPath');
    }

    final risky = startPath == 'Pass1_Risk_Start';
    final greedy = sweepPath.startsWith('Pass1_Greedy');
    final hub = !returnPath.contains('NoHub');
    final expected = firstPassPaths(risk: risky, greedy: greedy, hub: hub);

    if (sweepPath != expected.sweep || returnPath != expected.returnPath) {
      throw StateError(
        'first pass paths do not match: $startPath, $sweepPath, $returnPath',
      );
    }

    return BattlecryPassSpec(
      start: 'rush',
      risky: risky,
      greedy: greedy,
      hub: hub,
      route: 'Far -> Close',
      localize: true,
    );
  }

  static _ParsedSweepSpec _parseChainFromPaths(List<String> paths) {
    if (paths.isEmpty) {
      throw StateError('missing sweep path');
    }

    final invA = <String, String>{
      for (final entry in aSweepPaths.entries) entry.value: entry.key,
    };
    final invB = <String, String>{
      for (final entry in bSweepPaths.entries) entry.value: entry.key,
      for (final entry in bSweepPaths.entries) 'Greedy_${entry.value}': entry.key,
    };

    final aToken = invA[paths.first];
    if (aToken == null) {
      throw StateError('expected SweepA path, got ${paths.first}');
    }

    if (paths.length == 1) {
      return _ParsedSweepSpec(
        BattlecryPassSpec(
          risky: aToken == 'RiskA',
          greedy: false,
          hub: aToken == 'CloseA',
          route: 'Far -> Close',
          localize: true,
        ),
        aToken,
      );
    }

    if (paths.length != 3) {
      throw StateError('expected A or A-connector-B sweep, got $paths');
    }

    final connector = paths[1];
    final bToken = invB[paths[2]];
    if (bToken == null) {
      throw StateError('expected SweepB path, got ${paths[2]}');
    }

    final greedy =
        connector.startsWith('Greedy_') || paths[2].startsWith('Greedy_');
    final cleanConnector =
        connector.startsWith('Greedy_') ? connector.substring('Greedy_'.length) : connector;

    final match =
        RegExp(r'^(MidA|CloseA|FarA|RiskA)-(MidB|CloseB|FarB|RiskB)$')
            .firstMatch(cleanConnector);
    if (match == null) {
      throw StateError('could not parse connector $connector');
    }

    final startToken = match.group(1)!;
    final endToken = match.group(2)!;
    if (startToken != aToken || endToken != bToken) {
      throw StateError(
        'connector $connector does not match ${paths[0]} -> ${paths[2]}',
      );
    }

    late String route;
    late String farToken;
    late String nearToken;

    if (aToken == 'FarA' || aToken == 'RiskA') {
      route = 'Far -> Close';
      farToken = aToken;
      nearToken = bToken;
    } else {
      route = 'Close -> Far';
      farToken = bToken;
      nearToken = aToken;
    }

    return _ParsedSweepSpec(
      BattlecryPassSpec(
        risky: farToken.contains('Risk'),
        greedy: greedy,
        hub: nearToken.contains('Close'),
        route: route,
        localize: true,
      ),
      bToken,
    );
  }

  static bool _isSecondPassReturnPath(String pathName) {
    return pathName.endsWith('-Localize') ||
        pathName.endsWith('-NoLocalize') ||
        _isSecondPassReturnCommand(pathName);
  }

  static bool _isSecondPassReturnCommand(String pathName) {
    return pathName == 'Pass2_Localize_Return' ||
        pathName == 'Pass2_NoLocalize_Return' ||
        RegExp(r'^Pass2_(MidB|CloseB|FarB|RiskB)_(Localize|NoLocalize)_Return$')
            .hasMatch(pathName);
  }

  static String _dotForPath(String pathName, Map<String, String> dotMap) {
    for (final entry in dotMap.entries) {
      if (entry.value == pathName) {
        return entry.key;
      }
    }
    return 'center';
  }

  static String _canonicalGeneratedPath(String pathName) {
    final knownPaths = _knownGeneratedPaths();
    if (knownPaths.contains(pathName)) {
      return pathName;
    }

    final sortedKnown = knownPaths.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final known in sortedKnown) {
      if (pathName.endsWith(' - $known')) {
        return known;
      }
    }

    return pathName;
  }

  static Set<String> _knownGeneratedPaths() {
    final known = <String>{
      ...dotPaths.values,
      ...zeroDotPaths.values,
      ...sneakyDotPaths.values,
      ...aSweepPaths.values,
      ...bSweepPaths.values,
      for (final value in bSweepPaths.values) 'Greedy_$value',
      'Pass1_Safe_Start',
      'Pass1_Risk_Start',
      'Pass1 Sneaky Start',
      'Pass_Start',
      'Pass2_Localize_Return',
      'Pass2_NoLocalize_Return',
    };

    for (final endToken in bSweepPaths.keys) {
      known.add('$endToken-Localize');
      known.add('$endToken-NoLocalize');
      known.add('Pass2_${endToken}_Localize_Return');
      known.add('Pass2_${endToken}_NoLocalize_Return');
    }

    for (final risk in [false, true]) {
      for (final greedy in [false, true]) {
        for (final hub in [false, true]) {
          final first = firstPassPaths(risk: risk, greedy: greedy, hub: hub);
          known.add(first.start);
          known.add(first.sweep);
          known.add(first.returnPath);
        }
      }
    }

    for (final aToken in aSweepPaths.keys) {
      for (final bToken in bSweepPaths.keys) {
        known.add('$aToken-$bToken');
        known.add('Greedy_$aToken-$bToken');
      }
    }

    return known;
  }
}

class _ParsedFinalSweep {
  final BattlecryFinalSpec finalSpec;
  final int nextIndex;

  const _ParsedFinalSweep(this.finalSpec, this.nextIndex);
}
