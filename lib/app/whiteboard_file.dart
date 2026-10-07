import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'whiteboard.dart';
import 'workspace_paths.dart';

const _maxWhiteboardBytes = 8 * 1024 * 1024;
const _entryStart = '<!-- context:whiteboard:entry ';

class WhiteboardPost {
  const WhiteboardPost(
    this.id,
    this.title,
    this.provider,
    this.cwd,
    this.time,
    this.body,
  );
  final String id;
  final String title;
  final String provider;
  final String cwd;
  final int time;
  final String body;
}

List<WhiteboardPost> parseWhiteboard(String text) {
  final posts = <String, WhiteboardPost>{};
  var cursor = 0;
  while (true) {
    final start = text.indexOf(_entryStart, cursor);
    if (start < 0) break;
    final headerStart = start + _entryStart.length;
    final headerEnd = text.indexOf('\n', headerStart);
    if (headerEnd < 0) break;
    cursor = headerEnd + 1;
    if (headerEnd - headerStart > 131072) continue;
    final line = text.substring(headerStart, headerEnd);
    if (!line.endsWith(' -->')) continue;
    try {
      final metadata =
          jsonDecode(line.substring(0, line.length - 4))
              as Map<String, dynamic>;
      final id = metadata['id'] as String;
      if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(id)) continue;
      final endMarker = '\n<!-- context:whiteboard:end $id -->';
      final bodyStart = headerEnd + 1;
      final length = metadata['body_chars'] as int;
      if (length < 0 || length > _maxWhiteboardBytes) continue;
      final end = bodyStart + length;
      if (end > text.length || !text.startsWith(endMarker, end)) continue;
      final post = WhiteboardPost(
        id,
        metadata['title'] as String,
        metadata['provider'] as String,
        metadata['cwd'] as String,
        metadata['published_at_ms'] as int,
        text.substring(bodyStart, end),
      );
      posts.remove(id);
      posts[id] = post;
      if (posts.length > 3) posts.remove(posts.keys.first);
      cursor = end + endMarker.length;
    } on Object {
      // Ignore malformed/orphaned entries; the publisher cleans them on its next write.
    }
  }
  return posts.values.toList().reversed.take(3).toList();
}

typedef _Stamp = (FileSystemEntityType, int, DateTime, DateTime);
_Stamp _stamp(FileStat stat) =>
    (stat.type, stat.size, stat.modified, stat.changed);

class FileWhiteboardReader implements WhiteboardReader {
  String? _cachePath;
  _Stamp? _cacheStamp;
  List<WhiteboardPost> _posts = const [];
  final _inflight = <String, Future<List<WhiteboardPost>>>{};
  int _revision = 0;
  bool _disposed = false;

  @override
  List<SessionProvider> get providers => const [];

  void _invalidate(String path) {
    _revision++;
    if (_cachePath == path) _cacheStamp = null;
  }

  // Directory watching observes atomic file replacement, not just the old inode.
  // WSL shares may silently miss Linux-side events: their fallback checks only
  // one file's metadata, and reads content only when it changes.
  Stream<void> changes(String markdownPath) {
    final path = whiteboardFilePath(markdownPath);
    final file = File(path);
    StreamSubscription<FileSystemEvent>? watch;
    Timer? poll;
    Timer? debounce;
    var checking = false;
    var cancelled = false;
    _Stamp? previous;
    late StreamController<void> controller;
    void changed() {
      _invalidate(path);
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 20), () {
        if (!cancelled) controller.add(null);
      });
    }

    Future<void> check() async {
      if (cancelled || checking) return;
      checking = true;
      try {
        final current = _stamp(await file.stat());
        if (cancelled) return;
        if (previous == null || current != previous) changed();
        previous = current;
      } on FileSystemException {
        if (!cancelled) changed();
      } finally {
        checking = false;
      }
    }

    void fallback() {
      if (poll != null || cancelled) return;
      unawaited(check());
      poll = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(check()),
      );
    }

    bool isBoard(String eventPath) =>
        eventPath.split(RegExp(r'[/\\]')).last.toLowerCase() == 'whiteboard.md';
    controller = StreamController<void>(
      onListen: () {
        try {
          watch = file.parent.watch().listen(
            (event) {
              if (isBoard(event.path) ||
                  (event is FileSystemMoveEvent &&
                      event.destination != null &&
                      isBoard(event.destination!))) {
                changed();
              }
            },
            onError: (Object _) => fallback(),
            onDone: fallback,
          );
        } on FileSystemException {
          fallback();
        }
        if (path.startsWith('\\\\') || path.startsWith('//')) fallback();
      },
      onCancel: () async {
        cancelled = true;
        poll?.cancel();
        debounce?.cancel();
        await watch?.cancel();
      },
    );
    return controller.stream;
  }

  Future<List<WhiteboardPost>> _read(String markdownPath) async {
    if (_disposed) throw StateError('Whiteboard reader closed');
    final path = whiteboardFilePath(markdownPath);
    if (path.isEmpty) return const [];
    final pending = _inflight[path];
    if (pending != null) return pending;
    final future = _readFile(path);
    _inflight[path] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[path], future)) _inflight.remove(path);
    }
  }

  Future<List<WhiteboardPost>> _readFile(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) return const [];
    if (stat.size > _maxWhiteboardBytes) {
      throw const FormatException('Whiteboard exceeds 8 MiB.');
    }
    if (_cachePath == path && _cacheStamp == _stamp(stat)) return _posts;
    final revision = _revision;
    final handle = await file.open();
    final bytes = BytesBuilder(copy: false);
    try {
      while (bytes.length <= _maxWhiteboardBytes) {
        final remaining = _maxWhiteboardBytes + 1 - bytes.length;
        final chunk = await handle.read(remaining < 65536 ? remaining : 65536);
        if (chunk.isEmpty) break;
        bytes.add(chunk);
      }
    } finally {
      await handle.close();
    }
    if (bytes.length > _maxWhiteboardBytes) {
      throw const FormatException('Whiteboard exceeds 8 MiB.');
    }
    final posts = parseWhiteboard(utf8.decode(bytes.takeBytes()));
    if (!_disposed && revision == _revision) {
      _cachePath = path;
      _cacheStamp = _stamp(stat);
      _posts = posts;
    }
    return posts;
  }

  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async => (await _read(path))
      .map(
        (post) => RecentContext(
          provider: SessionProviderInfo.parse(post.provider),
          id: post.id,
          title: post.title,
          updatedAt: post.time,
          workDir: post.cwd,
        ),
      )
      .toList();

  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async {
    final post = (await _read(
      path,
    )).where((p) => p.id == session.id).firstOrNull;
    if (post == null) return const ResponseHistory([], null, false);
    return ResponseHistory(
      [
        SessionResponse(
          text: post.body,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            post.time,
            isUtc: true,
          ).toIso8601String(),
          turnId: post.id,
        ),
      ],
      post.cwd,
      false,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _posts = const [];
    _cacheStamp = null;
  }
}
