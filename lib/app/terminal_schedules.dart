import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'codex_session_control.dart';
import 'models.dart';
import 'session_terminal.dart';
import 'terminal_tabs.dart';

typedef KeepAliveLauncher =
    Future<bool> Function(
      TerminalSession session,
      TerminalWindow window,
      String path,
    );

class TerminalKeepAliveJob {
  TerminalKeepAliveJob(this.group, this.nextCheck);
  TerminalTabGroup group;
  DateTime nextCheck;
  DateTime? lastCheck;
  bool enabled = true;
  String status = 'Checks every 15 min while Context is running.';
  Map<String, dynamic> toJson() => {
    'group': group.toJson(),
    'next': nextCheck.millisecondsSinceEpoch,
    'last': lastCheck?.millisecondsSinceEpoch,
    'enabled': enabled,
    'status': status,
  };
}

/// One deadline timer, no polling while off. Desired members are independent
/// of discovery's shrinking live group, so a disappeared tab stays protected.
class TerminalSchedules extends ChangeNotifier {
  TerminalSchedules({
    required this.monitor,
    required this.request,
    DateTime Function()? now,
    KeepAliveLauncher? launch,
  }) : _now = now ?? DateTime.now,
       _launch = launch ?? _launchChecked;
  static const preferenceKey = 'terminalKeepAliveV1';
  static const interval = Duration(minutes: 15);
  final TerminalTabs? Function() monitor;
  final CodexControlRequest request;
  final DateTime Function() _now;
  final KeepAliveLauncher _launch;
  final _jobs = <String, TerminalKeepAliveJob>{};
  final _claims = <String>{};
  SharedPreferences? _preferences;
  Timer? _timer;
  String _path = '';
  bool _disposed = false, checking = false;
  Future<void> _writes = Future.value();
  String? error;
  TerminalKeepAliveJob? jobFor(String id) => _jobs[id];

  static Future<bool> _launchChecked(
    TerminalSession session,
    TerminalWindow window,
    String path,
  ) async {
    const terminal = SessionTerminal();
    if (!await terminal.isElevated()) {
      throw StateError(
        'Administrator approval is needed. Re-enable Keep Alive.',
      );
    }
    await terminal.open(
      terminalSessionArguments(
        provider: session.provider,
        sessionId: session.id,
        title: session.name.isEmpty
            ? '${session.provider.label} ${session.shortId}'
            : session.name,
        markdownPath: path,
        workDir: '//wsl.localhost/${session.distro}${session.cwd}',
      ),
      requiredWindow: [window.handle, window.pid, window.started],
    );
    return true;
  }

  void restore(SharedPreferences preferences) {
    _preferences = preferences;
    try {
      final text = preferences.getString(preferenceKey);
      if (text == null) return;
      if (text.length > 512 * 1024) throw const FormatException();
      final data = jsonDecode(text) as Map<String, dynamic>;
      final jobs = data['jobs'] as List;
      final claims = List<String>.from(data['claims'] as List);
      if (jobs.length > 32 ||
          claims.length > 4096 ||
          claims.any((v) => v.length > 600)) {
        throw const FormatException();
      }
      for (final raw in jobs) {
        final value = raw as Map<String, dynamic>;
        final g = value['group'] as Map<String, dynamic>;
        final members = (g['members'] as List)
            .map((v) => TerminalSession(Map<String, dynamic>.from(v as Map)))
            .toList();
        final window = TerminalWindow(
          Map<String, dynamic>.from(g['window'] as Map),
        );
        if (!window.valid ||
            members.length > 64 ||
            members.any((s) => !s.resumable)) {
          throw const FormatException();
        }
        final group = TerminalTabGroup(
          id: g['id'] as String,
          name: g['name'] as String,
          sourcePath: g['source_path'] as String,
          window: window,
          members: members,
        );
        if (group.id.length > 100 || group.sourcePath.length > 4096) {
          throw const FormatException();
        }
        final job = TerminalKeepAliveJob(
          group,
          DateTime.fromMillisecondsSinceEpoch(value['next'] as int),
        );
        job.enabled = value['enabled'] == true;
        job.status = (value['status'] as String?) ?? job.status;
        if (value['last'] is int) {
          job.lastCheck = DateTime.fromMillisecondsSinceEpoch(
            value['last'] as int,
          );
        }
        _jobs[group.id] = job;
      }
      _claims.addAll(claims);
    } catch (_) {
      _jobs.clear();
      error =
          'Saved Keep Alive settings could not be read. Nothing was started.';
    }
    _schedule();
  }

  void follow(String path) {
    if (_path == path || _disposed) return;
    _path = path;
    _schedule();
  }

  Future<void> setEnabled(TerminalTabGroup group, bool enabled) async {
    if (_disposed) return;
    final tabs = monitor();
    if (enabled) {
      if (tabs == null || group.sourcePath != _path) {
        throw StateError('Terminal discovery is not ready.');
      }
      await tabs.ensureFresh();
      if (_disposed) return;
      if (!tabs.snapshotComplete ||
          !tabs.isActive(group) ||
          tabs.isClosing(group.window) ||
          group.members.isEmpty ||
          group.members.length > 64 ||
          group.members.any((s) => !s.resumable)) {
        throw StateError(
          'Keep Alive needs an open window and known resume IDs.',
        );
      }
      if (_jobs.length >= 32 && !_jobs.containsKey(group.id)) {
        throw StateError('Too many scheduled groups.');
      }
    }
    final previous = _jobs[group.id];
    final job = TerminalKeepAliveJob(group, _now().add(interval))
      ..enabled = enabled;
    if (!enabled) job.status = 'Keep Alive is off.';
    _jobs[group.id] = job;
    try {
      await _persist();
    } catch (_) {
      if (previous == null) {
        _jobs.remove(group.id);
      } else {
        _jobs[group.id] = previous;
      }
      rethrow;
    }
    if (_disposed) return;
    notifyListeners();
    _schedule();
  }

  Future<void> stop(String id) async {
    final job = _jobs[id];
    if (job != null && job.enabled) await setEnabled(job.group, false);
  }

  Future<void> _persist() {
    final text = jsonEncode({
      'jobs': _jobs.values.map((j) => j.toJson()).toList(),
      'claims': _claims.toList(),
    });
    if (text.length > 512 * 1024) {
      return Future.error(StateError('Keep Alive storage is full.'));
    }
    final write = _writes.catchError((Object _) {}).then((_) async {
      if (_preferences != null &&
          !await _preferences!.setString(preferenceKey, text)) {
        throw StateError('Could not save Keep Alive settings.');
      }
    });
    _writes = write;
    return write;
  }

  bool _current(TerminalKeepAliveJob job) =>
      !_disposed &&
      job.enabled &&
      identical(_jobs[job.group.id], job) &&
      job.group.sourcePath == _path;

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || checking || _path.isEmpty) return;
    final due = _jobs.values.where(_current).map((j) => j.nextCheck).toList()
      ..sort();
    if (due.isEmpty) return;
    final wait = due.first.difference(_now());
    _timer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(checkDue()),
    );
  }

  @visibleForTesting
  Future<void> checkDue() async {
    if (_disposed || checking) return;
    checking = true;
    notifyListeners();
    try {
      for (final job in _jobs.values.toList()) {
        if (!_current(job) || job.nextCheck.isAfter(_now())) continue;
        job.nextCheck = _now().add(interval);
        job.lastCheck = _now();
        // Persist the next deadline before any side effects. No catch-up bursts.
        await _persist();
        if (!_current(job)) continue;
        try {
          await _check(job);
        } catch (_) {
          job.status = 'Check unavailable; will try again in 15 min.';
        }
        await _persist();
      }
    } catch (_) {
      error = 'Could not save the schedule. Automatic checks are paused.';
      for (final job in _jobs.values) {
        job.enabled = false;
      }
    } finally {
      checking = false;
      if (!_disposed) {
        notifyListeners();
        _schedule();
      }
    }
  }

  Future<void> _check(TerminalKeepAliveJob job) async {
    final tabs = monitor();
    if (tabs == null || tabs.sourcePath != _path) return;
    await tabs.ensureFresh();
    if (!_current(job)) return;
    if (!tabs.snapshotComplete) {
      job.status = 'Discovery incomplete; nothing changed.';
      return;
    }
    if (!tabs.windows.any((w) => w.key == job.group.window.key) ||
        tabs.isClosing(job.group.window)) {
      job.enabled = false;
      job.status = 'Window closed; Keep Alive stopped.';
      return;
    }
    final observed = tabs.groups
        .where((g) => g.window.key == job.group.window.key)
        .firstOrNull;
    final desired = {for (final s in job.group.members) s.reference: s};
    for (final s in observed?.members ?? <TerminalSession>[]) {
      if (s.resumable) desired[s.reference] = s;
    }
    if (desired.length > 64) throw StateError('Too many tabs.');
    job.group = job.group.copyWith(members: desired.values.toList());
    final missing = job.group.members.where((s) => !tabs.isOpen(s)).toList();
    var restored = 0;
    if (missing.isNotEmpty) {
      if (tabs.windows.length != 1) {
        job.status =
            'Multiple Terminal windows; restore missing tabs manually.';
      } else {
        await tabs.openGroup(job.group, (s, _) async {
          if (!_current(job)) return false;
          final opened = await _launch(s, job.group.window, _path);
          if (opened) restored++;
          return opened;
        }, requiredWindow: job.group.window);
      }
    }
    if (!_current(job)) return;
    final live = <TerminalSession>[];
    for (final s in job.group.members.where(
      (s) => s.provider == SessionProvider.codex,
    )) {
      final matches = tabs.sessions
          .where((v) => v.reference == s.reference)
          .toList();
      if (matches.length == 1 &&
          tabs.groups.any(
            (g) =>
                g.window.key == job.group.window.key &&
                g.members.any((v) => v.reference == s.reference),
          )) {
        live.add(matches.single);
      }
    }
    var retried = 0, waiting = 0, attention = 0;
    if (live.isNotEmpty) {
      Map<String, dynamic> target(TerminalSession s) => {
        'id': s.id,
        'pid': s.pid,
        'start': s.toJson()['start'],
      };
      final result = await request(_path, {
        'action': 'status',
        'targets': live.map(target).toList(),
      });
      for (final row in (result['sessions'] as List? ?? const [])) {
        if (!_current(job)) return;
        if (row['state'] == 'waiting_usage') waiting++;
        if (row['state'] == 'attention' || row['state'] == 'unavailable') {
          attention++;
        }
        if (row['state'] != 'retryable' || row['turn_id'] is! String) continue;
        final session = live.where((s) => s.id == row['id']).firstOrNull;
        if (session == null) continue;
        final claim = '${session.reference}\u0000${row['turn_id']}';
        if (_claims.contains(claim)) {
          attention++;
          continue;
        }
        if (_claims.length >= 4096) {
          throw StateError('Recovery history is full.');
        }
        _claims.add(claim);
        await _persist();
        if (!_current(job)) return;
        final recovery = await request(_path, {
          'action': 'recover',
          'targets': [
            {...target(session), 'turn_id': row['turn_id']},
          ],
        });
        final state = (recovery['sessions'] as List?)?.firstOrNull?['state'];
        if (state == 'retried') {
          retried++;
        } else if (state == 'waiting_usage') {
          waiting++;
        } else if (state != 'changed' && state != 'untouched') {
          attention++;
        }
      }
    }
    final parts = <String>[
      if (restored > 0) '$restored restored',
      if (retried > 0) '$retried continued',
      if (waiting > 0) '$waiting waiting for usage',
      if (attention > 0) '$attention need attention',
      if (missing.isNotEmpty && tabs.windows.length != 1)
        'Restore missing tabs manually',
    ];
    job.status = parts.isEmpty
        ? 'Checked; running and completed turns left alone.'
        : '${parts.join(' · ')}.';
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
