import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'codex_downgrade.dart';
import 'codex_session_control.dart';
import 'models.dart';

class ClaudeAccount {
  const ClaudeAccount({
    required this.key,
    required this.name,
    this.tier,
    this.weeklyUsed,
    this.weeklyReset,
    this.fiveHourUsed,
    this.fiveHourReset,
    this.observedAt,
    this.error,
  });
  factory ClaudeAccount.fromJson(Map<String, dynamic> value) {
    double? used(Object? window) {
      final n = window is Map ? window['used_percent'] : null;
      return n is num && n.isFinite && n >= 0 && n <= 100 ? n.toDouble() : null;
    }

    int? reset(Object? window) => window is Map && window['reset_at'] is int
        ? window['reset_at'] as int
        : null;
    final key = value['account_key'];
    if (key is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const FormatException('Invalid Claude account identity');
    }
    return ClaudeAccount(
      key: key,
      name: value['name'] as String,
      tier: value['tier'] as String?,
      weeklyUsed: used(value['weekly']),
      weeklyReset: reset(value['weekly']),
      fiveHourUsed: used(value['five_hour']),
      fiveHourReset: reset(value['five_hour']),
      observedAt: value['observed_at'] as int?,
      error: value['usage_error'] as String?,
    );
  }
  final String key, name;
  final String? tier, error;
  final double? weeklyUsed, fiveHourUsed;
  final int? weeklyReset, fiveHourReset, observedAt;
  CodexAccount get pacing => CodexAccount(
    slot: key,
    name: name,
    weeklyUsedPercent: weeklyUsed,
    weeklyResetAt: weeklyReset,
    weeklyWindowSeconds: 604800,
    usageObservedAt: observedAt,
    usageAccountKey: key,
  );
  Map<String, dynamic> toJson() => {
    'account_key': key,
    'name': name,
    'tier': tier,
    'observed_at': observedAt,
    'weekly': weeklyUsed == null
        ? null
        : {'used_percent': weeklyUsed, 'reset_at': weeklyReset},
    'five_hour': fiveHourUsed == null
        ? null
        : {'used_percent': fiveHourUsed, 'reset_at': fiveHourReset},
    'usage_error': error,
  };
  ClaudeAccount stale(String message) => ClaudeAccount(
    key: key,
    name: name,
    tier: tier,
    weeklyUsed: weeklyUsed,
    weeklyReset: weeklyReset,
    fiveHourUsed: fiveHourUsed,
    fiveHourReset: fiveHourReset,
    observedAt: observedAt,
    error: message,
  );
}

/// One live login for now. Records and overrides are keyed by account identity,
/// not slot order, so future account switching can reuse the same model.
class ClaudeAccounts extends ChangeNotifier {
  ClaudeAccounts({CodexControlRequest? request, DateTime Function()? now})
    : _client = CodexSessionControlClient(request: request),
      _now = now ?? DateTime.now {
    downgrade = CodexResetDowngrade(
      request: _request,
      now: _now,
      storageKey: 'claudeDowngradeV1',
      initialModel: 'claude-sonnet-5-5',
      providerLabel: 'Claude',
      defaultsOnly: true,
    );
  }
  static const preferenceKey = 'claudeAccountsV1';
  final CodexSessionControlClient _client;
  final DateTime Function() _now;
  late final CodexResetDowngrade downgrade;
  SharedPreferences? _preferences;
  List<ClaudeAccount> accounts = const [];
  ClaudeAccount? get current => accounts.firstOrNull;
  final _overrides = <String, int>{};
  String _path = '';
  bool busy = false, _disposed = false;
  String? error;
  int revision = 0;
  DateTime? _attempted;
  int _generation = 0;
  int _manualGeneration = 0;
  Future<void>? _inflight;
  Future<void> _writes = Future.value();
  int? get manualResetAt {
    final value = _overrides[current?.key];
    return value != null && value > _now().millisecondsSinceEpoch
        ? value
        : null;
  }

  List<CodexAccount> get pacingAccounts =>
      accounts.map((a) => a.pacing).toList();

  void restore(SharedPreferences prefs) {
    _preferences = prefs;
    downgrade.restore(prefs);
    try {
      final raw = prefs.getString(preferenceKey);
      if (raw == null || raw.length > 64 * 1024) return;
      final data = jsonDecode(raw) as Map;
      _path = data['path'] as String;
      accounts = (data['accounts'] as List)
          .take(1)
          .map(
            (a) => ClaudeAccount.fromJson(
              Map<String, dynamic>.from(a as Map),
            ).stale('Refresh to update.'),
          )
          .toList();
      for (final entry in (data['manual_resets'] as Map).entries.take(64)) {
        if (entry.key is String &&
            entry.value is int &&
            entry.value > _now().millisecondsSinceEpoch) {
          _overrides[entry.key as String] = entry.value as int;
        }
      }
    } catch (_) {
      accounts = const [];
      _overrides.clear();
    }
  }

  Future<void> _persist() {
    final data = jsonEncode({
      'path': _path,
      'accounts': accounts.map((a) => a.toJson()).toList(),
      'manual_resets': _overrides,
    });
    final next = _writes.catchError((Object _) {}).then((_) async {
      final prefs = _preferences;
      if (prefs == null) return;
      if (!await prefs.setString(preferenceKey, data)) {
        throw StateError('Could not save Claude account preferences.');
      }
    });
    _writes = next;
    return next;
  }

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, dynamic> payload,
  ) => _client.request(path, {...payload, 'provider': 'claude'});

  void follow(String path, {bool active = false}) {
    if (path != _path) {
      _path = path;
      _generation++;
      accounts = const [];
      error = null;
      busy = false;
      _attempted = null;
      _inflight = null;
      _notify();
    }
    downgrade.follow(path);
    final expired = _overrides.keys
        .where((key) => _overrides[key]! <= _now().millisecondsSinceEpoch)
        .toList();
    if (expired.isNotEmpty) {
      for (final key in expired) {
        _overrides.remove(key);
      }
      unawaited(_persist().catchError((Object _) {}));
      _notify();
    }
    if (path.isNotEmpty &&
        (active || (downgrade.armed && downgrade.appliesTo(path)))) {
      unawaited(refresh());
    }
  }

  Future<void> refresh({bool force = false}) {
    if (_disposed || _path.isEmpty) return Future.value();
    if (_inflight != null) return _inflight!;
    final interval = force
        ? const Duration(seconds: 60)
        : const Duration(minutes: 5);
    if (_attempted != null && _now().difference(_attempted!) < interval) {
      return Future.value();
    }
    final path = _path, generation = _generation;
    _attempted = _now();
    busy = true;
    revision++;
    _notify();
    final operation = _refresh(path, generation);
    _inflight = operation;
    return operation;
  }

  Future<void> _refresh(String path, int generation) async {
    try {
      final data = await _request(path, {'action': 'account'});
      if (_disposed || generation != _generation) return;
      final next = (data['accounts'] as List)
          .take(1)
          .map(
            (a) => ClaudeAccount.fromJson(Map<String, dynamic>.from(a as Map)),
          )
          .toList();
      if (next.isEmpty) {
        throw StateError('No Claude subscription account found.');
      }
      final account = next.single, previous = current;
      accounts = account.error != null && previous?.key == account.key
          ? [previous!.stale(account.error!)]
          : next;
      error = account.error;
      if (account.error == null) {
        downgrade.observe(path, [account.pacing], account.key);
      }
      await _persist();
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = '$failure';
        accounts = accounts.map((a) => a.stale(error!)).toList();
      }
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        _inflight = null;
        _notify();
      }
    }
  }

  Future<void> setManualReset(DateTime? reset) async {
    final ticket = ++_manualGeneration;
    final account = current;
    if (account == null) throw StateError('Load a Claude account first.');
    if (reset != null &&
        (!reset.isAfter(_now()) ||
            reset.isAfter(_now().add(const Duration(days: 7))))) {
      throw ArgumentError('Choose a reset within the next seven days.');
    }
    final before = _overrides[account.key];
    if (reset == null) {
      _overrides.remove(account.key);
    } else {
      _overrides[account.key] = reset.millisecondsSinceEpoch;
    }
    try {
      await _persist();
    } catch (_) {
      if (ticket != _manualGeneration) rethrow;
      if (before == null) {
        _overrides.remove(account.key);
      } else {
        _overrides[account.key] = before;
      }
      rethrow;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    downgrade.dispose();
    _client.dispose();
    super.dispose();
  }
}
