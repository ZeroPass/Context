import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../src/bindings/bindings.dart';
import 'whiteboard.dart';

class ResolvedReference {
  const ResolvedReference(this.source, this.paths);
  final String source;
  final List<String> paths;
  bool get missing => paths.isEmpty;
}

class FileReferenceResolver {
  FileReferenceResolver({
    required this.markdownPath,
    required this.roots,
    this.workDir,
    bool? windows,
    Future<bool> Function(String)? exists,
  }) : windows = windows ?? Platform.isWindows,
       _exists = exists ?? _fileExists;
  final String markdownPath;
  final List<String> roots;
  final String? workDir;
  final bool windows;
  final Future<bool> Function(String) _exists;
  final _cache = <String, Future<ResolvedReference>>{};
  static Future<bool> _fileExists(String path) async =>
      await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

  p.Context get _paths =>
      p.Context(style: windows ? p.Style.windows : p.Style.posix);

  static String clean(String source) {
    var path = source.trim();
    if (path.startsWith('file:')) {
      try {
        path = Uri.parse(path).toFilePath(
          windows:
              path.contains('\\') ||
              path.contains('localhost') ||
              path.contains('file:///C:'),
        );
      } on FormatException {
        return source;
      }
    }
    if (path.contains('%')) {
      try {
        path = Uri.decodeComponent(path);
      } on FormatException {
        // A literal percent sign is also a valid filename character.
      }
    }
    return path.replaceFirst(RegExp(r'(?:#L\d+(?:C\d+)?|:\d+(?::\d+)?)$'), '');
  }

  String translate(String source) {
    var path = clean(source);
    if (windows) {
      final unc = markdownPath.replaceAll('/', '\\');
      final parts = unc.split('\\').where((part) => part.isNotEmpty).toList();
      if (path.startsWith('/') &&
          parts.length >= 2 &&
          (parts[0] == 'wsl.localhost' || parts[0] == r'wsl$')) {
        path = '\\\\${parts[0]}\\${parts[1]}${path.replaceAll('/', '\\')}';
      } else if (path.startsWith('~/') &&
          parts.length >= 4 &&
          parts[2] == 'home') {
        path =
            '\\\\${parts.take(4).join('\\')}\\${path.substring(2).replaceAll('/', '\\')}';
      }
      path = path.replaceAll('/', '\\');
    } else if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'];
      if (home != null) path = p.join(home, path.substring(2));
    }
    return path;
  }

  Future<ResolvedReference> resolve(
    String source,
  ) => _cache.putIfAbsent(source, () async {
    final path = translate(source);
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(path)) {
      return ResolvedReference(source, const []);
    }
    if (_paths.isAbsolute(path)) {
      return ResolvedReference(source, await _exists(path) ? [path] : const []);
    }
    final candidates = <String>{};
    // Prefer the session's working directory over fallback roots.
    if (workDir != null && workDir!.isNotEmpty) {
      final candidate = _paths.normalize(
        _paths.join(translate(workDir!), path),
      );
      if (await _exists(candidate)) {
        return ResolvedReference(source, [candidate]);
      }
      candidates.add(candidate);
    }
    final matches = <String>[];
    for (final root in roots.take(20)) {
      final candidate = _paths.normalize(_paths.join(translate(root), path));
      if (candidates.add(candidate) && await _exists(candidate)) {
        matches.add(candidate);
      }
    }
    return ResolvedReference(source, matches);
  });
}

String fileReferenceLabel(String label, String source) {
  final uri = Uri.tryParse(source);
  final path = FileReferenceResolver.clean(
    uri?.scheme == 'http' || uri?.scheme == 'https' ? uri!.path : source,
  );
  final filename = path.split(RegExp(r'[/\\]')).last;
  final dot = filename.lastIndexOf('.');
  if (dot <= 0 ||
      !RegExp(r'^[a-zA-Z0-9]{1,10}$').hasMatch(filename.substring(dot + 1))) {
    return label;
  }
  final normalized = label.trim().toLowerCase();
  if (normalized.isEmpty) return filename;
  if (label.trim() == source.trim() ||
      normalized.contains(filename.toLowerCase())) {
    return label;
  }
  if (normalized == filename.substring(0, dot).toLowerCase()) return filename;
  return '$label ($filename)';
}

// Deliberately require a slash or a recognized extension: prose isn't a path.
final fileReferencePattern = RegExp(
  r'''(?:https?://[^\s`<>"|]+|\\[^\s`<>"|]+|(?:[A-Za-z]:[\\/]|\~/|\.{1,2}/|/)[^\s`<>"|]+|[A-Za-z0-9_.-]+[/\\][^\s`<>"|]+|[A-Za-z0-9_.-]+\.(?:png|jpe?g|webp|gif|bmp|svg|mp4|webm|mov|mkv|avi|m4v|pdf|csv|jsonl?|md|markdown|txt|log|ya?ml|toml|rs|py|dart|cpp|hpp|h|c|ts|tsx|js|html|css|zip)(?::\d+(?::\d+)?)?)''',
  caseSensitive: false,
);

bool isPreviewImage(String path) =>
    RegExp(r'\.(png|jpe?g|webp|gif|bmp)$', caseSensitive: false).hasMatch(path);
bool isPreviewMarkdown(String path) =>
    RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(path);
bool isPreviewVideo(String path) => RegExp(
  r'\.(mp4|webm|mov|mkv|avi|m4v)$',
  caseSensitive: false,
).hasMatch(path);
bool isWhiteboardPreview(String path) =>
    isPreviewMarkdown(path) || isPreviewImage(path) || isPreviewVideo(path);
bool isRunnableFile(String path) => RegExp(
  r'\.(exe|com|scr|bat|cmd|ps1|sh|msi|lnk|jar|py|js|vbs)$',
  caseSensitive: false,
).hasMatch(path);

typedef ReferenceOpener = Future<void> Function(String path, {bool reveal});

Future<void> openReference(String path, {bool reveal = false}) async {
  final id = nextWhiteboardRequestId();
  final completer = Completer<void>();
  final subscription = WhiteboardResult.rustSignalStream.listen((pack) {
    if (pack.message.requestId != id || completer.isCompleted) return;
    if (pack.message.error != null) {
      completer.completeError(StateError(pack.message.error!));
    } else {
      completer.complete();
    }
  });
  try {
    OpenWhiteboardFile(
      requestId: id,
      path: path,
      reveal: reveal,
    ).sendSignalToRust();
    await completer.future.timeout(const Duration(seconds: 20));
  } finally {
    await subscription.cancel();
  }
}
