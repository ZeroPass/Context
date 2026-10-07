import 'package:path/path.dart' as p;

p.Context contextPaths(String path) => p.Context(
  style: RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\|//)').hasMatch(path)
      ? p.Style.windows
      : p.Style.posix,
);

String migratedSessionPath(String path) {
  final paths = contextPaths(path);
  final folder = paths.dirname(path);
  if (paths.basename(folder).toLowerCase() == 'codex-out' &&
      paths.basename(path).toLowerCase() == 'codex sessions.md') {
    return paths.join(folder, 'Context', 'codex sessions.md');
  }
  return path;
}

String whiteboardFilePath(String sessionsPath) {
  if (sessionsPath.trim().isEmpty) return '';
  final paths = contextPaths(sessionsPath);
  final normalized = paths.style == p.Style.windows
      ? sessionsPath.replaceAll('/', '\\')
      : sessionsPath;
  return paths.join(paths.dirname(normalized), 'whiteboard.md');
}

String whiteboardPublishPrompt(String sessionsPath) {
  final board = whiteboardFilePath(sessionsPath);
  if (board.isEmpty) return '';
  final paths = contextPaths(board);
  final fullPath = paths.normalize(paths.absolute(board));
  final wsl = RegExp(
    r'^//wsl(?:\.localhost|\$)/[^/]+(/.*)$',
    caseSensitive: false,
  ).firstMatch(fullPath.replaceAll('\\', '/'));
  final location = wsl == null
      ? '`$fullPath`'
      : '`${wsl.group(1)}` (Windows: `$fullPath`)';
  return 'Read $location and follow its instructions to publish your last final answer.';
}

String sessionWorkspaceRoot(String sessionsPath) {
  final paths = contextPaths(sessionsPath);
  final folder = paths.dirname(sessionsPath);
  if (paths.basename(folder).toLowerCase() == 'context' &&
      paths.basename(paths.dirname(folder)).toLowerCase() == 'codex-out') {
    return paths.dirname(folder);
  }
  return folder;
}
