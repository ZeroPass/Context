import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'whiteboard_file.dart';
import 'workspace_paths.dart';

const whiteboardNotificationChannel = MethodChannel('context/notifications');

Future<void> notifyWhiteboardPublication(RecentContext post) async {
  if (!Platform.isWindows) return;
  final title = post.title.trim();
  await whiteboardNotificationChannel
      .invokeMethod<void>('whiteboardPublished', {
        'title': title.isEmpty
            ? 'New publication'
            : String.fromCharCodes(title.runes.take(200)),
        'provider': post.provider.label,
      });
}

// One app-owned watch/read cache, shared by the visible pane and notifications.
class WhiteboardPublications {
  WhiteboardPublications({
    FileWhiteboardReader? reader,
    Future<void> Function(RecentContext)? notify,
    this.notificationsEnabled = true,
  }) : reader = reader ?? FileWhiteboardReader(),
       _notify = notify ?? notifyWhiteboardPublication;

  final FileWhiteboardReader reader;
  final Future<void> Function(RecentContext) _notify;
  final _changes = StreamController<void>.broadcast();
  final _seen = <String>{};
  StreamSubscription<void>? _watch;
  String _path = '';
  String _board = '';
  int _generation = 0;
  int? _reading;
  bool _repeat = false;
  bool _baselined = false;
  bool _disposed = false;
  bool notificationsEnabled;

  Stream<void> get changes => _changes.stream;

  void follow(String path) {
    if (_disposed) return;
    final board = path.trim().isEmpty ? '' : whiteboardFilePath(path);
    if (board == _board) return;
    final generation = ++_generation;
    _path = path;
    _board = board;
    _seen.clear();
    _baselined = false;
    _repeat = false;
    unawaited(_watch?.cancel());
    _watch = null;
    if (board.isEmpty) return;
    // Subscribe before reading so an atomic publish during startup is not lost.
    _watch = reader.changes(path).listen((_) {
      if (generation == _generation) unawaited(_refresh(generation));
    });
    unawaited(_refresh(generation));
  }

  Future<void> _refresh(int generation) async {
    if (_disposed || generation != _generation) return;
    if (_reading == generation) {
      _repeat = true;
      return;
    }
    _reading = generation;
    try {
      do {
        _repeat = false;
        final posts = await reader.recent(
          _path,
          SessionProvider.codex,
          whiteboardSlotCount,
        );
        if (_disposed || generation != _generation) return;
        final fresh = posts.where((post) => !_seen.contains(post.id)).toList();
        for (final post in posts.reversed) {
          _seen.add(post.id);
        }
        // Bounded deduplication also covers removals and immediate restorations.
        while (_seen.length > 256) {
          _seen.remove(_seen.first);
        }
        if (_baselined && notificationsEnabled) {
          for (final post in fresh.reversed) {
            if (!post.localDrop) unawaited(_deliver(post));
          }
        }
        _baselined = true;
        _changes.add(null);
      } while (_repeat && !_disposed && generation == _generation);
    } on Object {
      // Missing, unreadable or partial writes are retried on the next file event.
      // Never mark them as delivered or surface a modal while the app is idle.
    } finally {
      if (_reading == generation) _reading = null;
    }
  }

  Future<void> _deliver(RecentContext post) async {
    try {
      await _notify(post);
    } on Object catch (error) {
      debugPrint('Whiteboard notification unavailable: ${error.runtimeType}');
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_watch?.cancel());
    unawaited(_changes.close());
    reader.dispose();
  }
}
