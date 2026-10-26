import 'dart:async';
import 'dart:convert';

import 'package:rinf/rinf.dart';

import '../src/bindings/bindings.dart';

typedef CodexControlRequest =
    Future<Map<String, dynamic>> Function(
      String path,
      Map<String, dynamic> payload,
    );

/// One request-id namespace for model controls and Terminal recovery.
class CodexSessionControlClient {
  CodexSessionControlClient({CodexControlRequest? request})
    : _override = request;
  final CodexControlRequest? _override;
  StreamSubscription<RustSignalPack<CodexSessionControlResult>>? _subscription;
  final _pending = <Uint64, Completer<Map<String, dynamic>>>{};
  BigInt _serial = BigInt.one;
  bool _disposed = false;

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, dynamic> payload,
  ) async {
    if (_disposed) throw StateError('Codex control closed');
    if (_override != null) return _override(path, payload);
    _subscription ??= CodexSessionControlResult.rustSignalStream.listen((pack) {
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
    final id = Uint64(_serial);
    _serial += BigInt.one;
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    try {
      CodexSessionControl(
        requestId: id,
        sessionsMarkdownPath: path,
        payloadJson: jsonEncode(payload),
      ).sendSignalToRust();
      return await pending.future.timeout(const Duration(seconds: 20));
    } finally {
      _pending.remove(id);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription?.cancel());
    for (final pending in _pending.values) {
      pending.completeError(StateError('Codex control closed'));
    }
    _pending.clear();
  }
}
