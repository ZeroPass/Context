import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:rinf/rinf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/bindings/bindings.dart';
import 'models.dart';

typedef CodexControlRequest =
    Future<Map<String, dynamic>> Function(
      String path,
      Map<String, dynamic> payload,
    );

enum CodexDowngradeTrigger { reset, hours }

class CodexModelChoice {
  CodexModelChoice.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      efforts = List<String>.from(json['efforts'] as List),
      defaultEffort = json['default_effort'] as String;
  final String id, name, defaultEffort;
  final List<String> efforts;
}

class _Usage {
  const _Usage(this.used, this.reset, this.observed, this.accountKey);
  final double used;
  final int reset, observed;
  final String? accountKey;
  Map<String, dynamic> toJson() => {
    'used': used,
    'reset': reset,
    'observed': observed,
    'account_key': accountKey,
  };
  static _Usage? of(CodexAccount account) =>
      account.hasWeeklyUsage &&
          account.isWeeklyWindow &&
          account.usageObservedAt != null
      ? _Usage(
          account.weeklyUsedPercent!,
          account.weeklyResetAt!,
          account.usageObservedAt!,
          account.usageAccountKey,
        )
      : null;
}

/// Persistent one-shot policy. Reset mode uses existing account polling;
/// timed mode owns only a single deadline timer.
class CodexResetDowngrade extends ChangeNotifier {
  CodexResetDowngrade({CodexControlRequest? request, DateTime Function()? now})
    : _requestOverride = request,
      _now = now ?? DateTime.now;
  static const preferenceKey = 'codexResetDowngradeV1';
  static const defaultModel = 'gpt-6.1-sol';
  static const defaultHours = 2;
  static const maxHours = 24;
  final CodexControlRequest? _requestOverride;
  final DateTime Function() _now;
  SharedPreferences? _preferences;
  StreamSubscription<RustSignalPack<CodexSessionControlResult>>? _subscription;
  final _requests = <Uint64, Completer<Map<String, dynamic>>>{};
  BigInt _serial = BigInt.one;
  final _baseline = <String, _Usage>{};
  String model = defaultModel, effort = 'high', phase = 'off';
  String? status;
  String _path = '';
  int _armedAt = 0;
  CodexDowngradeTrigger trigger = CodexDowngradeTrigger.reset;
  int hours = defaultHours;
  int? _dueAt;
  String? _workspace;
  Timer? _deadlineTimer;
  bool _disposed = false, _changing = false;
  Future<void> _writes = Future.value();
  bool get armed => phase == 'armed';
  bool get running => phase == 'running';
  bool get busy => running || _changing;
  DateTime? get scheduledAt =>
      _dueAt == null ? null : DateTime.fromMillisecondsSinceEpoch(_dueAt!);

  String get _armedStatus => trigger == CodexDowngradeTrigger.reset
      ? "Armed for the active account's next reset."
      : 'Armed for $hours h after arming.';

  void restore(SharedPreferences preferences) {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _workspace = null;
    _baseline.clear();
    _preferences = preferences;
    try {
      final raw = preferences.getString(preferenceKey);
      if (raw == null || raw.length > 64 * 1024) return;
      final value = jsonDecode(raw) as Map<String, dynamic>;
      model = value['model'] as String;
      effort = value['effort'] as String;
      _path = value['path'] as String;
      _armedAt = value['armed_at'] as int;
      phase = value['phase'] as String;
      status = value['status'] as String?;
      trigger = switch (value['trigger']) {
        null || 'reset' => CodexDowngradeTrigger.reset,
        'hours' => CodexDowngradeTrigger.hours,
        _ => throw const FormatException('Invalid downgrade trigger'),
      };
      hours = (value['delay_hours'] as int?) ?? defaultHours;
      _dueAt = value['due_at'] as int?;
      if (hours < 1 ||
          hours > maxHours ||
          (armed &&
              trigger == CodexDowngradeTrigger.hours &&
              (_armedAt <= 0 ||
                  _dueAt !=
                      _armedAt + Duration(hours: hours).inMilliseconds))) {
        throw const FormatException('Invalid downgrade deadline');
      }
      final entries = value['baseline'] as Map<String, dynamic>;
      if (entries.length > 64 ||
          !['off', 'armed', 'running', 'done', 'failed'].contains(phase)) {
        throw const FormatException('Invalid downgrade state');
      }
      for (final entry in entries.entries) {
        final usage = entry.value as Map<String, dynamic>;
        _baseline[entry.key] = _Usage(
          (usage['used'] as num).toDouble(),
          usage['reset'] as int,
          usage['observed'] as int,
          usage['account_key'] as String?,
        );
      }
      if (running) {
        phase = 'failed';
        status =
            'Interrupted. Check the tabs and re-arm if needed; not retried automatically.';
      }
      if (armed) status = _armedStatus;
    } catch (_) {
      phase = 'off';
      _baseline.clear();
      _dueAt = null;
      trigger = CodexDowngradeTrigger.reset;
      hours = defaultHours;
      status = 'Could not restore the downgrade action. Re-arm to enable it.';
    }
    // Follow the current workspace before scheduling a restored deadline.
  }

  Future<void> _persist() {
    final data = jsonEncode({
      'model': model,
      'effort': effort,
      'path': _path,
      'armed_at': _armedAt,
      'phase': phase,
      'status': status,
      'trigger': trigger.name,
      'delay_hours': hours,
      'due_at': _dueAt,
      'baseline': _baseline.map(
        (slot, value) => MapEntry(slot, value.toJson()),
      ),
    });
    final next = _writes.catchError((Object _) {}).then((_) async {
      final prefs = _preferences;
      if (prefs == null || !await prefs.setString(preferenceKey, data)) {
        throw StateError(
          'Could not save the reset action. No automatic changes were sent.',
        );
      }
    });
    _writes = next;
    return next;
  }

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, dynamic> payload,
  ) async {
    if (_requestOverride != null) return _requestOverride(path, payload);
    _subscription ??= CodexSessionControlResult.rustSignalStream.listen((pack) {
      final pending = _requests.remove(pack.message.requestId);
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
    _requests[id] = pending;
    try {
      CodexSessionControl(
        requestId: id,
        sessionsMarkdownPath: path,
        payloadJson: jsonEncode(payload),
      ).sendSignalToRust();
      return await pending.future.timeout(const Duration(seconds: 20));
    } finally {
      _requests.remove(id);
    }
  }

  Future<List<CodexModelChoice>> models(String path) async {
    final result = await _request(path, {'action': 'models'});
    return (result['models'] as List)
        .map(
          (entry) => CodexModelChoice.fromJson(entry as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> arm(
    String path,
    CodexModelChoice choice,
    String thinking,
    List<CodexAccount> accounts, {
    CodexDowngradeTrigger trigger = CodexDowngradeTrigger.reset,
    int hours = defaultHours,
  }) async {
    if (busy) throw StateError('The downgrade action is busy.');
    if (hours < 1 || hours > maxHours) {
      throw ArgumentError('Choose 1 to $maxHours hours.');
    }
    if (path.trim().isEmpty) {
      throw ArgumentError('Choose a sessions file first.');
    }
    if (!choice.efforts.contains(thinking)) {
      throw StateError('Unsupported thinking level.');
    }
    _changing = true;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    model = choice.id;
    effort = thinking;
    _path = path;
    _workspace = path;
    _armedAt = _now().millisecondsSinceEpoch;
    this.trigger = trigger;
    this.hours = hours;
    _dueAt = trigger == CodexDowngradeTrigger.hours
        ? _armedAt + Duration(hours: hours).inMilliseconds
        : null;
    _baseline.clear();
    for (final account in accounts.take(64)) {
      final usage = _Usage.of(account);
      if (usage != null) _baseline[account.identityKey] = usage;
    }
    phase = 'armed';
    status = _armedStatus;
    try {
      await _persist();
    } catch (_) {
      phase = 'off';
      status = 'Not armed: could not save the downgrade action.';
      rethrow;
    } finally {
      _changing = false;
      checkDeadline();
      _notify();
    }
  }

  Future<void> disarm() async {
    if (busy) return;
    _changing = true;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    phase = 'off';
    status = null;
    try {
      await _persist();
    } finally {
      _changing = false;
      _notify();
    }
  }

  void observe(String path, List<CodexAccount> accounts, String? activeSlot) {
    if (!armed ||
        trigger != CodexDowngradeTrigger.reset ||
        _changing ||
        path != _path ||
        _disposed) {
      return;
    }
    var changed = false, resetDetected = false;
    for (final account in accounts.take(64)) {
      final usage = _Usage.of(account);
      if (usage == null || usage.observed <= _armedAt) continue;
      final previous = _baseline[account.identityKey];
      if (previous != null && usage.observed <= previous.observed) continue;
      if (account.identityKey == activeSlot?.trim().toLowerCase() &&
          previous != null &&
          usage.reset > usage.observed &&
          usage.used == 0 &&
          previous.accountKey == usage.accountKey &&
          (previous.used > 0 || usage.reset - previous.reset >= 60000)) {
        resetDetected = true;
      }
      _baseline[account.identityKey] = usage;
      changed = true;
    }
    if (resetDetected) {
      _begin('Reset detected');
    } else if (changed) {
      unawaited(
        _persist().catchError((Object _) {
          phase = 'failed';
          status = 'Could not save reset tracking. Re-arm to try again.';
          _notify();
        }),
      );
    }
  }

  void follow(String path) {
    if (_workspace != path) {
      _workspace = path;
      _deadlineTimer?.cancel();
      _deadlineTimer = null;
    }
    checkDeadline();
  }

  /// Also called on resume/focus and the existing refresh tick, so a clock
  /// change or sleep cannot defer an already-overdue action indefinitely.
  void checkDeadline() {
    if (_disposed ||
        !armed ||
        _changing ||
        trigger != CodexDowngradeTrigger.hours ||
        _workspace != _path ||
        _dueAt == null) {
      return;
    }
    final remaining = _dueAt! - _now().millisecondsSinceEpoch;
    if (remaining <= 0) {
      _begin('Timer elapsed');
    } else if (_deadlineTimer?.isActive != true) {
      _deadlineTimer = Timer(Duration(milliseconds: remaining), () {
        _deadlineTimer = null;
        checkDeadline();
      });
    }
  }

  void _begin(String reason) {
    if (_disposed || !armed || _changing) return;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    // Claim synchronously; _execute saves consumption before touching live tabs.
    phase = 'running';
    status = '$reason. Applying to active Codex tabs...';
    _notify();
    unawaited(_execute());
  }

  Future<void> _execute() async {
    try {
      await _persist();
      if (_disposed) return;
      final result = await _request(_path, {
        'action': 'apply',
        'model': model,
        'effort': effort,
      });
      final updated = (result['updated'] as List).length;
      final skipped = (result['skipped'] as List).length;
      final failed = (result['failed'] as List).length;
      final liveFailed = (result['live_failed'] as List? ?? const []).length;
      phase = failed == 0 && skipped == 0 && liveFailed == 0 && updated > 0
          ? 'done'
          : 'failed';
      status =
          'Downgrade used: $updated updated, $skipped skipped, $failed failed. '
          '${liveFailed > 0 ? '$liveFailed busy turns could not be changed yet; their future replies have the new settings. ' : ''}'
          '${phase == 'done' ? '' : 'Check the tabs; re-arm to try again.'}';
    } catch (error) {
      phase = 'failed';
      status =
          'Downgrade stopped: $error Not retried automatically; re-arm to try again.';
    }
    try {
      await _persist();
    } catch (_) {
      /* The durable running claim prevents a replay. */
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _deadlineTimer?.cancel();
    _subscription?.cancel();
    for (final pending in _requests.values) {
      pending.completeError(StateError('Codex control closed'));
    }
    _requests.clear();
    super.dispose();
  }
}
