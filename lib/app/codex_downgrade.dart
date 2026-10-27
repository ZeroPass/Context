import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'codex_session_control.dart';
import 'models.dart';

export 'codex_session_control.dart' show CodexControlRequest;

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
  CodexResetDowngrade({
    CodexControlRequest? request,
    DateTime Function()? now,
    String storageKey = preferenceKey,
    String initialModel = defaultModel,
    this.providerLabel = 'Codex',
    this.defaultsOnly = false,
  }) : control = CodexSessionControlClient(request: request),
       _now = now ?? DateTime.now,
       _storageKey = storageKey,
       model = initialModel;
  static const preferenceKey = 'codexResetDowngradeV1';
  static const defaultModel = 'gpt-6.1-sol';
  static const defaultHours = 2;
  static const maxHours = 24;
  final CodexSessionControlClient control;
  final DateTime Function() _now;
  final String _storageKey, providerLabel;
  final bool defaultsOnly;
  String get scopeLabel => defaultsOnly
      ? 'Defaults for new/resumed $providerLabel sessions. Running tabs need the commands below.'
      : 'All active $providerLabel tabs.';
  String get resetLabel => defaultsOnly
      ? 'When weekly quota returns to 100% left.'
      : 'When the active account returns to 100% left.';
  List<String> commands = const [];
  SharedPreferences? _preferences;
  final _baseline = <String, _Usage>{};
  String model, effort = 'high', phase = 'off';
  String? status;
  String _path = '';
  int _armedAt = 0;
  CodexDowngradeTrigger trigger = CodexDowngradeTrigger.reset;
  int hours = defaultHours;
  int? _dueAt;
  String? _accountKey;
  String? _workspace;
  Timer? _deadlineTimer;
  bool _disposed = false, _changing = false;
  Future<void> _writes = Future.value();
  bool get armed => phase == 'armed';
  bool get running => phase == 'running';
  bool get busy => running || _changing;
  bool appliesTo(String path) => _path == path && (armed || running);
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
      final raw = preferences.getString(_storageKey);
      if (raw == null || raw.length > 64 * 1024) return;
      final value = jsonDecode(raw) as Map<String, dynamic>;
      model = value['model'] as String;
      effort = value['effort'] as String;
      _path = value['path'] as String;
      _armedAt = value['armed_at'] as int;
      phase = value['phase'] as String;
      status = value['status'] as String?;
      commands = List<String>.from(value['commands'] as List? ?? const []);
      trigger = switch (value['trigger']) {
        null || 'reset' => CodexDowngradeTrigger.reset,
        'hours' => CodexDowngradeTrigger.hours,
        _ => throw const FormatException('Invalid downgrade trigger'),
      };
      hours = (value['delay_hours'] as int?) ?? defaultHours;
      _dueAt = value['due_at'] as int?;
      _accountKey = value['account_key'] as String?;
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
      'commands': commands,
      'account_key': _accountKey,
    });
    final next = _writes.catchError((Object _) {}).then((_) async {
      final prefs = _preferences;
      if (prefs == null || !await prefs.setString(_storageKey, data)) {
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
  ) => control.request(path, payload);

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
    if (defaultsOnly && accounts.isEmpty) {
      throw StateError('Load a Claude account first.');
    }
    if (defaultsOnly &&
        trigger == CodexDowngradeTrigger.reset &&
        !accounts.any((a) => a.hasWeeklyUsage)) {
      throw StateError('Wait for a weekly quota reading, or choose Hours.');
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
    _accountKey = accounts.firstOrNull?.usageAccountKey;
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
          (previous.used > 0 ||
              (usage.reset - previous.reset >= 60000 &&
                  (!defaultsOnly || previous.reset <= usage.observed)))) {
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
    status = defaultsOnly
        ? '$reason. Saving $providerLabel defaults...'
        : '$reason. Applying to active $providerLabel tabs...';
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
        if (defaultsOnly) 'account_key': _accountKey,
      });
      if (defaultsOnly) {
        if (result['defaults_saved'] != true) {
          throw StateError('Defaults were not saved.');
        }
        commands = List<String>.from(result['commands'] as List);
        phase = 'done';
        status =
            'Defaults saved for new/resumed $providerLabel sessions. Running tabs are unchanged; use the commands below.';
      } else {
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
      }
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
    control.dispose();
    super.dispose();
  }
}
