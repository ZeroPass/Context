import 'package:flutter/services.dart';

import 'models.dart';
import 'terminal_profiles.dart';
import 'workspace_paths.dart';

const sessionTerminalChannel = MethodChannel('context/terminal');

bool canOpenSessionInTerminal(SessionProvider provider) =>
    provider != SessionProvider.zcode;

List<String> terminalSessionArguments({
  required SessionProvider provider,
  required String sessionId,
  required String title,
  required String markdownPath,
  String? workDir,
  String window = '0',
}) {
  if (window != '0' &&
      !RegExp(r'^context-[a-zA-Z0-9_-]{1,80}$').hasMatch(window)) {
    throw ArgumentError('Invalid Terminal window name.');
  }
  if (!canOpenSessionInTerminal(provider)) {
    throw ArgumentError(
      'This provider does not expose a terminal resume command.',
    );
  }
  final id = sessionId.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$').hasMatch(id)) {
    throw ArgumentError('The session id is not valid for terminal launching.');
  }
  final command = switch (provider) {
    SessionProvider.codex => ['codex', 'resume', id],
    SessionProvider.claude => ['claude', '--resume', id],
    SessionProvider.kimi => ['kimi', '--session', id],
    SessionProvider.opencode => ['opencode', '--session', id],
    SessionProvider.qwen => ['qwen', '--resume', id],
    SessionProvider.muse => ['muse', 'resume', id, '--yolo'],
    SessionProvider.zcode => throw StateError('No ZCode terminal command.'),
  };
  final label = String.fromCharCodes(
    title.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim().runes.take(200),
  );
  final args = <String>[
    '-w',
    window,
    'new-tab',
    if (label.isNotEmpty) ...['--title', label],
  ];
  var directory =
      (workDir?.trim().isNotEmpty == true
              ? workDir!.trim()
              : sessionWorkspaceRoot(markdownPath))
          .replaceAll('\\', '/');
  if (directory.isEmpty ||
      !directory.startsWith('/') &&
          !RegExp(r'^[A-Za-z]:/').hasMatch(directory) ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(directory)) {
    throw ArgumentError('A valid session working directory is required.');
  }
  final wsl = RegExp(
    r'^//wsl(?:\.localhost|\$)/([^/]+)(/.*)?$',
    caseSensitive: false,
  );
  final location = wsl.firstMatch(directory);
  if (location == null && RegExp(r'^[A-Za-z]:/').hasMatch(directory)) {
    directory = '/mnt/${directory[0].toLowerCase()}/${directory.substring(3)}';
  }
  if (location == null && directory.startsWith('//')) {
    throw ArgumentError('This network folder is not a WSL working directory.');
  }
  final config = wsl.firstMatch(markdownPath.replaceAll('\\', '/'));
  final distro = location?.group(1) ?? config?.group(1);
  if (distro != null &&
      (distro.length > 128 ||
          distro.startsWith('-') ||
          RegExp(r'[\x00-\x1f\x7f\\/]').hasMatch(distro))) {
    throw ArgumentError('Invalid WSL distribution name.');
  }
  args.addAll([
    'wsl.exe',
    if (distro != null) ...['-d', distro],
    '--cd',
    location?.group(2) ?? (location != null ? '/' : directory),
    '--exec',
    'bash',
    '-lic',
    r'exec "$@"',
    'context-session',
    ...command,
  ]);
  return args;
}

class SessionTerminal {
  const SessionTerminal();

  Future<bool> isElevated() async =>
      await sessionTerminalChannel.invokeMethod<bool>('isElevated') ?? false;

  Future<void> open(List<String> arguments) async {
    final wsl = arguments.indexOf('wsl.exe');
    if (wsl < 3) throw ArgumentError('Expected a WSL session command.');
    final distroIndex = arguments.indexOf('-d', wsl + 1);
    final settings = await sessionTerminalChannel.invokeMethod<String>(
      'readSettings',
    );
    if (settings == null) {
      throw StateError('Windows Terminal settings unavailable.');
    }
    final profile = windowsTerminalProfile(
      settings,
      distribution: distroIndex < 0 ? null : arguments[distroIndex + 1],
    );
    await sessionTerminalChannel.invokeMethod<void>('openTab', [
      ...arguments.take(3),
      '--profile',
      profile,
      ...arguments.skip(3),
    ]);
  }

  Future<void> restartElevated() =>
      sessionTerminalChannel.invokeMethod<void>('restartElevated');

  Future<void> closeWindow(String handle, String pid, String started) =>
      sessionTerminalChannel.invokeMethod<void>('closeWindow', [
        handle,
        pid,
        started,
      ]);
}
