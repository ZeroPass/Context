import 'dart:async';
import 'dart:convert';

import 'package:rinf/rinf.dart';

import '../src/bindings/bindings.dart';
import 'models.dart';

BigInt _nextWhiteboardId = BigInt.one;
Uint64 nextWhiteboardRequestId() {
  final id = Uint64(_nextWhiteboardId);
  _nextWhiteboardId += BigInt.one;
  return id;
}

class SessionResponse {
  const SessionResponse({
    required this.text,
    required this.timestamp,
    required this.turnId,
  });
  factory SessionResponse.fromJson(Map<String, dynamic> json) =>
      SessionResponse(
        text: (json['text'] ?? '').toString(),
        timestamp: (json['timestamp'] ?? '').toString(),
        turnId: (json['turn_id'] ?? '').toString(),
      );
  final String text;
  final String timestamp;
  final String turnId;
}

class ResponseHistory {
  const ResponseHistory(this.responses, this.workDir, this.bounded);
  final List<SessionResponse> responses;
  final String? workDir;
  final bool bounded;
}

abstract class WhiteboardReader {
  // Other provider tabs remain hidden until their readers are registered here.
  List<SessionProvider> get providers;
  Future<List<RecentContext>> recent(
    String markdownPath,
    SessionProvider provider,
    int limit,
  );
  Future<ResponseHistory> history(
    String markdownPath,
    RecentContext session,
    int limit,
  );
  void dispose();
}

class LocalWhiteboardReader implements WhiteboardReader {
  static final _recentReads = <String, Future<List<RecentContext>>>{};
  LocalWhiteboardReader() {
    _subscription = WhiteboardResult.rustSignalStream.listen((pack) {
      final pending = _pending.remove(pack.message.requestId);
      if (pending == null) return;
      if (pack.message.error != null) {
        pending.completeError(StateError(pack.message.error!));
      } else {
        try {
          pending.complete(
            jsonDecode(pack.message.payloadJson) as Map<String, dynamic>,
          );
        } catch (error, stack) {
          pending.completeError(error, stack);
        }
      }
    });
  }
  final _pending = <Uint64, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<RustSignalPack<WhiteboardResult>> _subscription;
  bool _disposed = false;

  @override
  List<SessionProvider> get providers => const [SessionProvider.codex];

  Future<Map<String, dynamic>> _read(
    String path,
    SessionProvider provider,
    String id,
    int limit,
  ) async {
    if (_disposed) throw StateError('Whiteboard reader closed');
    final request = nextWhiteboardRequestId();
    final completer = Completer<Map<String, dynamic>>();
    _pending[request] = completer;
    try {
      ReadWhiteboard(
        requestId: request,
        sessionsMarkdownPath: path,
        provider: provider.key,
        sessionId: id,
        limit: limit,
      ).sendSignalToRust();
      return await completer.future.timeout(const Duration(seconds: 20));
    } finally {
      _pending.remove(request);
    }
  }

  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async {
    final key = '$path\u0000${provider.key}\u0000$limit';
    final existing = _recentReads[key];
    if (existing != null) return existing;
    final pending = _readRecent(path, provider, limit);
    _recentReads[key] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_recentReads[key], pending)) _recentReads.remove(key);
    }
  }

  Future<List<RecentContext>> _readRecent(
    String path,
    SessionProvider provider,
    int limit,
  ) async {
    final result = await _read(path, provider, '', limit);
    return (result['sessions'] as List? ?? [])
        .map((v) => RecentContext.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async {
    final result = await _read(path, session.provider, session.id, limit);
    return ResponseHistory(
      (result['responses'] as List? ?? [])
          .map((v) => SessionResponse.fromJson(v as Map<String, dynamic>))
          .toList(),
      result['work_dir'] as String?,
      result['bounded_history'] == true,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    for (final pending in _pending.values) {
      pending.completeError(StateError('Whiteboard reader closed'));
    }
    _pending.clear();
  }
}
