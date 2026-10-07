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
  return paths.join(paths.dirname(sessionsPath), 'whiteboard.md');
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
