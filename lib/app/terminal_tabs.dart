import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:rinf/rinf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/bindings/bindings.dart';
import 'models.dart';

typedef TerminalSnapshotReader =
    Future<Map<String, dynamic>> Function(String path);

class TerminalSession {
  TerminalSession(Map<String, dynamic> data)
    : provider = SessionProviderInfo.parse(data['provider']),
      id = (data['launch_session_id'] ?? '').toString(),
      name = (data['name'] ?? '').toString(),
      cwd = (data['cwd'] ?? '').toString(),
      distro = (data['distro'] ?? 'WSL').toString(),
      pid = (data['pid'] ?? '').toString(),
      identity = '${data['pid']}:${data['start']}';
  final SessionProvider provider;
  final String id, name, cwd, distro, pid, identity;
  String get shortId =>
      id.isEmpty ? '?' : id.substring(id.length > 4 ? id.length - 4 : 0);
  String get reference => '$distro\u0000${provider.key}\u0000$id';
  bool get resumable =>
      provider != SessionProvider.zcode &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$').hasMatch(id) &&
      distro.isNotEmpty &&
      distro != 'WSL' &&
      distro.length <= 128 &&
      !distro.startsWith('-') &&
      !RegExp(r'[\x00-\x1f\x7f\\/]').hasMatch(distro) &&
      cwd.startsWith('/') &&
      !cwd.startsWith('//') &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(cwd);

  Map<String, dynamic> toJson() => {
    'provider': provider.key,
    'launch_session_id': id,
    'name': name,
    'cwd': cwd,
    'distro': distro,
    'pid': pid,
    'start': identity.substring(identity.indexOf(':') + 1),
  };
}

class TerminalWindow {
  TerminalWindow(Map<String, dynamic> data)
    : handle = '${data['hwnd'] ?? ''}',
      pid = '${data['pid'] ?? ''}',
      started = '${data['started'] ?? ''}';
  final String handle, pid, started;
  String get key => '$pid:$started:$handle';
  bool get valid => [
    handle,
    pid,
    started,
  ].every((v) => RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(v));
  Map<String, dynamic> toJson() => {
    'hwnd': handle,
    'pid': pid,
    'started': started,
  };
}

class TerminalTabGroup {
  const TerminalTabGroup({
    required this.id,
    required this.name,
    required this.sourcePath,
    required this.window,
    required this.members,
    this.closed = false,
    this.pending = const {},
  });
  final String id, name, sourcePath;
  final TerminalWindow window;
  final List<TerminalSession> members;
  final bool closed;
  final Set<String> pending;
  TerminalTabGroup copyWith({
    String? name,
    TerminalWindow? window,
    List<TerminalSession>? members,
    bool? closed,
    Set<String>? pending,
  }) => TerminalTabGroup(
    id: id,
    name: name ?? this.name,
    sourcePath: sourcePath,
    window: window ?? this.window,
    members: members ?? this.members,
    closed: closed ?? this.closed,
    pending: pending ?? this.pending,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source_path': sourcePath,
    'window': window.toJson(),
    'members': members.map((s) => s.toJson()).toList(),
    'closed': closed,
    'pending': pending.toList(),
  };
}

typedef TerminalGroupLauncher =
    Future<bool> Function(TerminalSession session, String window);

class TerminalTabs extends ChangeNotifier {
  TerminalTabs({
    TerminalSnapshotReader? reader,
    SharedPreferences? preferences,
    DateTime Function()? now,
    List<ConfigItem> Function()? savedSessions,
  }) : _preferences = preferences,
       _now = now ?? DateTime.now,
       _savedSessions = savedSessions ?? (() => const []) {
    _loadGroups();
    _reader = reader ?? _nativeRead;
    if (reader == null) {
      _subscription = TerminalTabsResult.rustSignalStream.listen((pack) {
        final pending = _pending.remove(pack.message.requestId);
        if (pending == null) return;
        try {
          if (pack.message.error != null) throw StateError(pack.message.error!);
          pending.complete(
            jsonDecode(pack.message.payloadJson) as Map<String, dynamic>,
          );
        } catch (error, stack) {
          pending.completeError(error, stack);
        }
      });
    }
  }
  late final TerminalSnapshotReader _reader;
  StreamSubscription<RustSignalPack<TerminalTabsResult>>? _subscription;
  final _pending = <Uint64, Completer<Map<String, dynamic>>>{};
  BigInt _nextId = BigInt.one;
  Timer? _timer;
  Timer? _followup;
  Timer? _settleTimer;
  Completer<void>? _reading;
  final SharedPreferences? _preferences;
  final DateTime Function() _now;
  final List<ConfigItem> Function() _savedSessions;
  static const groupsPreferenceKey = 'terminalWindowGroupsV1';
  List<TerminalTabGroup> groups = const [];
  List<TerminalWindow> windows = const [];
  String? groupsError;
  bool opening = false, _processesComplete = false, _windowsComplete = false;
  bool _storageInvalid = false;
  String? _lastWritten;
  Future<void> _writing = Future.value();
  final _pendingLaunches = <String, ({DateTime until, String? group})>{};
  final _closing = <String, DateTime>{};
  final _shrinking = <String, ({String members, DateTime since})>{};
  int _groupSequence = 0;
  bool _disposed = false, _active = false;
  String _path = '';
  int _generation = 0;
  DateTime? _checked;
  bool busy = false;
  String? error;
  List<TerminalSession> sessions = const [];
  List<Map<String, dynamic>> tabs = const [];

  Future<Map<String, dynamic>> _nativeRead(String path) async {
    final id = Uint64(_nextId);
    _nextId += BigInt.one;
    final completion = Completer<Map<String, dynamic>>();
    _pending[id] = completion;
    try {
      ReadTerminalTabs(
        requestId: id,
        sessionsMarkdownPath: path,
      ).sendSignalToRust();
      return await completion.future.timeout(const Duration(seconds: 20));
    } finally {
      _pending.remove(id);
    }
  }

  void follow(String path, {required bool active}) {
    if (_disposed) return;
    final changed = path != _path;
    final resumed = active && !_active;
    if (changed) {
      _generation++;
      _path = path;
      _checked = null;
      sessions = const [];
      tabs = const [];
      error = null;
      windows = const [];
      _processesComplete = _windowsComplete = false;
    }
    _active = active;
    if (!active) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(refresh()),
      );
      if (changed || resumed) unawaited(refresh());
    }
    if (changed) notifyListeners();
  }

  Future<void> refresh({bool force = false, bool evenInactive = false}) async {
    if (_disposed || (!_active && !evenInactive) || _path.isEmpty || busy) {
      return;
    }
    if (!force &&
        _checked != null &&
        _now().difference(_checked!) < const Duration(seconds: 3)) {
      return;
    }
    final generation = _generation;
    busy = true;
    final completed = _reading = Completer<void>();
    notifyListeners();
    try {
      final data = await _reader(_path);
      if (_disposed || generation != _generation) return;
      sessions = (data['sessions'] as List? ?? const [])
          .whereType<Map>()
          .where(
            (s) => SessionProvider.values.any((p) => p.key == s['provider']),
          )
          .map((s) => TerminalSession(Map<String, dynamic>.from(s)))
          .toList();
      tabs = [];
      windows = [];
      _processesComplete =
          data['sessions'] is List &&
          !(data['warnings'] as List? ?? []).any(
            (w) => !w.toString().startsWith('Session names unavailable:'),
          );
      _windowsComplete = data['windows'] is List && data['tab_error'] == null;
      final warnings = <String>[
        if (data['tab_error'] is String) data['tab_error'] as String,
        ...(data['warnings'] as List? ?? const []).map((v) => v.toString()),
      ];
      for (final window
          in (data['windows'] as List? ?? const []).whereType<Map>()) {
        final identity = TerminalWindow(Map<String, dynamic>.from(window));
        if (identity.valid) {
          windows.add(identity);
        } else {
          _windowsComplete = false;
        }
        var index = 0;
        for (final tab
            in (window['tabs'] as List? ?? const []).whereType<Map>()) {
          tabs.add({
            ...Map<String, dynamic>.from(tab),
            'number': ++index,
            'window': window['hwnd'],
            'window_key': identity.key,
          });
        }
        if (window['limited'] == true ||
            (window['errors'] as List? ?? []).isNotEmpty) {
          warnings.add('Tab selection unavailable for one Terminal window.');
          _windowsComplete = false;
        }
      }
      error = warnings.isEmpty ? null : warnings.join(' ');
      _checked = _now();
      if (_processesComplete && _windowsComplete) _syncGroups();
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = 'Refresh unavailable; previous snapshot retained. $e';
        _checked = _now();
        _processesComplete = _windowsComplete = false;
      }
    } finally {
      completed.complete();
      if (!_disposed) {
        busy = false;
        notifyListeners();
        if (generation != _generation && _active) unawaited(refresh());
      }
    }
  }

  Future<void> ensureFresh() async {
    if (_disposed || _path.isEmpty) {
      throw StateError('Terminal discovery is not ready.');
    }
    var freshReadCompleted = false;
    if (busy) {
      final generation = _generation;
      await _reading?.future;
      freshReadCompleted = generation == _generation && !busy;
    }
    if (!freshReadCompleted) await refresh(force: true, evenInactive: true);
    if (_disposed || !_processesComplete) {
      throw StateError(
        'Could not check open sessions. Refresh Terminal tabs before opening a group.',
      );
    }
  }

  bool isOpen(TerminalSession session) => sessions.any(
    (s) =>
        (s.id.isNotEmpty && s.reference == session.reference) ||
        (s.pid.isNotEmpty &&
            s.identity == session.identity &&
            s.distro == session.distro),
  );

  bool isActive(TerminalTabGroup group) =>
      !group.closed && windows.any((w) => w.key == group.window.key);

  List<TerminalSession> orderedSessions([Iterable<TerminalSession>? input]) {
    final values = (input ?? sessions).toList();
    final original = {
      for (var i = 0; i < values.length; i++) values[i].identity: i,
    };
    int position(TerminalSession s) {
      final live =
          sessions
              .where((v) => v.reference == s.reference && s.id.isNotEmpty)
              .firstOrNull ??
          s;
      final tab = tabFor(live);
      return tab == null
          ? tabs.length + (original[s.identity] ?? 0)
          : tabs.indexOf(tab);
    }

    values.sort((a, b) => position(a).compareTo(position(b)));
    return values;
  }

  List<TerminalSession> get ungroupedSessions {
    final assigned = groups
        .where(isActive)
        .expand((g) => g.members)
        .map((s) => s.identity)
        .toSet();
    return orderedSessions(
      sessions.where((s) => !assigned.contains(s.identity)),
    );
  }

  void _loadGroups() {
    final raw = _preferences?.getString(groupsPreferenceKey);
    if (raw == null) return;
    try {
      if (raw.length > 256 * 1024) {
        throw const FormatException('Group data too large');
      }
      final data = jsonDecode(raw) as Map;
      if (data['version'] != 1 || (data['groups'] as List).length > 32) {
        throw const FormatException('Unsupported group data');
      }
      groups = (data['groups'] as List).map((value) {
        final map = Map<String, dynamic>.from(value as Map);
        final members = map['members'] as List;
        if (members.length > 64 ||
            !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(map['id'] as String)) {
          throw const FormatException('Invalid group');
        }
        final window = TerminalWindow(
          Map<String, dynamic>.from(map['window'] as Map),
        );
        if (!window.valid) throw const FormatException('Invalid window');
        return TerminalTabGroup(
          id: map['id'] as String,
          name: map['name'] as String,
          sourcePath: map['source_path'] as String,
          window: window,
          closed: map['closed'] == true,
          pending: (map['pending'] as List? ?? const []).cast<String>().toSet(),
          members: members.map((s) {
            final item = Map<String, dynamic>.from(s as Map);
            if (!SessionProvider.values.any((p) => p.key == item['provider'])) {
              throw const FormatException('Unknown saved provider');
            }
            return TerminalSession(item);
          }).toList(),
        );
      }).toList();
      if (groups.map((g) => g.id).toSet().length != groups.length) {
        throw const FormatException('Duplicate group');
      }
      for (final group in groups) {
        if (group.pending.length > 64 ||
            !group.pending.every(
              (key) => group.members.any((s) => s.reference == key),
            )) {
          throw const FormatException('Invalid pending group members');
        }
      }
      _lastWritten = raw;
    } catch (_) {
      groups = const [];
      _storageInvalid = true;
      groupsError =
          'Saved Terminal groups could not be read. Existing data was not overwritten.';
    }
  }

  Future<void> flushGroups() => _writing;

  void _persistGroups() {
    if (_storageInvalid || _preferences == null) return;
    final raw = jsonEncode({
      'version': 1,
      'groups': groups.map((g) => g.toJson()).toList(),
    });
    if (raw == _lastWritten) return;
    if (raw.length > 256 * 1024) {
      groupsError = 'Terminal group storage is full. Remove an old group.';
      return;
    }
    _lastWritten = raw;
    _writing = _writing.then((_) async {
      try {
        if (!await _preferences.setString(groupsPreferenceKey, raw)) {
          throw StateError('Preferences write failed');
        }
      } catch (_) {
        _lastWritten = null;
        if (!_disposed) {
          groupsError = 'Could not save Terminal groups.';
          notifyListeners();
        }
      }
    });
  }

  void _syncGroups() {
    final now = _now();
    _pendingLaunches.removeWhere((_, v) => v.until.isBefore(now));
    _closing.removeWhere((_, until) => until.isBefore(now));
    final byWindow = <String, List<TerminalSession>>{
      for (final w in windows) w.key: [],
    };
    for (final session in sessions) {
      var key = tabFor(session)?['window_key'] as String?;
      key ??= groups
          .where(isActive)
          .where((g) => g.members.any((s) => s.identity == session.identity))
          .firstOrNull
          ?.window
          .key;
      if (key == null && windows.length == 1) key = windows.single.key;
      byWindow[key]?.add(session);
    }
    var next = [...groups];
    for (final window in windows) {
      var index = next.indexWhere(
        (g) => !g.closed && g.window.key == window.key,
      );
      var members = orderedSessions(byWindow[window.key]!);
      if (members.length > 64) {
        groupsError =
            'A Terminal window has too many sessions to remember safely.';
        continue;
      }
      if (index < 0 && members.isNotEmpty) {
        final restoring = members
            .map((s) => _pendingLaunches[s.reference]?.group)
            .whereType<String>()
            .toSet();
        if (restoring.length == 1) {
          index = next.indexWhere(
            (g) => g.id == restoring.single && !isActive(g),
          );
        }
        if (index < 0) {
          if (next.length >= 32) {
            groupsError =
                '32 Terminal groups are saved. Remove an old group to remember more.';
            continue;
          }
          var number = 1;
          while (next.any((g) => g.name == 'Terminal $number')) {
            number++;
          }
          next.add(
            TerminalTabGroup(
              id: 'g${now.microsecondsSinceEpoch}_${_groupSequence++}',
              name: 'Terminal $number',
              sourcePath: _path,
              window: window,
              members: members,
            ),
          );
          continue;
        }
      }
      if (index < 0 || _closing.containsKey(window.key)) continue;
      final previous = next[index];
      final outstanding = previous.pending.difference(
        members.map((s) => s.reference).toSet(),
      );
      // A failed or still-starting restore must not shrink the saved group.
      // Once observed, a tab is ordinary live membership and can be removed.
      members = [
        ...members,
        ...previous.members.where((s) => outstanding.contains(s.reference)),
      ];
      final removed = previous.members.any(
        (s) => !members.any(
          (m) =>
              m.identity == s.identity ||
              (s.id.isNotEmpty && s.reference == m.reference),
        ),
      );
      if (removed && previous.window.key == window.key) {
        final signature = members.map((s) => s.identity).join(',');
        final pending = _shrinking[window.key];
        if (pending == null || pending.members != signature) {
          _shrinking[window.key] = (members: signature, since: now);
          _settleTimer ??= Timer(const Duration(seconds: 2), () {
            _settleTimer = null;
            unawaited(refresh(force: true, evenInactive: true));
          });
          continue;
        }
        if (now.difference(pending.since) < const Duration(seconds: 2)) {
          continue;
        }
      }
      _shrinking.remove(window.key);
      next[index] = previous.copyWith(
        window: window,
        members: members,
        closed: false,
        pending: outstanding,
      );
    }
    _shrinking.removeWhere((key, _) => !byWindow.containsKey(key));
    groups = next
        .map(
          (g) =>
              byWindow.containsKey(g.window.key) ? g : g.copyWith(closed: true),
        )
        .map(
          (g) => g.closed
              ? g.copyWith(
                  pending: g.pending.difference(
                    sessions.map((s) => s.reference).toSet(),
                  ),
                )
              : g,
        )
        .toList();
    _closing.removeWhere((key, _) => !byWindow.containsKey(key));
    _pendingLaunches.removeWhere(
      (key, _) => sessions.any((s) => s.reference == key),
    );
    _persistGroups();
  }

  Future<void> renameGroup(String id, String name) async {
    final value = name.trim();
    if (value.isEmpty || value.length > 80) {
      throw ArgumentError('Use a group name of 1 to 80 characters.');
    }
    groups = groups
        .map((g) => g.id == id ? g.copyWith(name: value) : g)
        .toList();
    _persistGroups();
    notifyListeners();
    await flushGroups();
  }

  Future<void> deleteGroup(String id) async {
    if (opening) throw StateError('Wait for the group to finish opening.');
    await ensureFresh();
    if (!_windowsComplete) {
      throw StateError(
        'Could not check whether this Terminal window is still open.',
      );
    }
    if (groups.any((g) => g.id == id && isActive(g))) {
      throw StateError('Close the Terminal window before deleting its group.');
    }
    groups = groups.where((g) => g.id != id).toList();
    _persistGroups();
    notifyListeners();
    await flushGroups();
  }

  void closingWindow(TerminalWindow window) {
    _closing[window.key] = _now().add(const Duration(seconds: 20));
    _afterAction();
  }

  void _afterAction() {
    if (_disposed) return;
    _followup?.cancel();
    _followup = Timer(const Duration(seconds: 1), () async {
      await refresh(force: true, evenInactive: true);
      if (_disposed) return;
      _followup = Timer(const Duration(seconds: 3), () {
        unawaited(refresh(force: true, evenInactive: true));
      });
    });
  }

  Future<String> openGroup(
    TerminalTabGroup group,
    TerminalGroupLauncher launch, {
    TerminalSession? only,
  }) async {
    if (opening) return 'A Terminal group is already opening.';
    opening = true;
    notifyListeners();
    var opened = 0;
    try {
      await ensureFresh();
      final entries = only == null ? group.members : [only];
      final unique = {for (final s in entries) s.reference: s}.values;
      final now = _now();
      _pendingLaunches.removeWhere((_, v) => v.until.isBefore(now));
      final missing = unique
          .where(
            (s) => !isOpen(s) && !_pendingLaunches.containsKey(s.reference),
          )
          .toList();
      if (missing.isEmpty) return 'Already open in Terminal.';
      final scope =
          RegExp(
            r'^//wsl(?:\.localhost|\$)/([^/]+)/',
            caseSensitive: false,
          ).firstMatch(_path.replaceAll('\\', '/'))?.group(1) ??
          sessions.firstOrNull?.distro;
      for (final s in missing) {
        if (!s.resumable) {
          throw StateError(
            'This group contains a session without a supported resume ID.',
          );
        }
        if (scope != s.distro) {
          throw StateError(
            'Select a sessions file in ${s.distro} before restoring this group.',
          );
        }
        if (sessions.any((v) => v.provider == s.provider && v.id.isEmpty)) {
          throw StateError(
            'An open ${s.provider.label} tab has an unknown session ID. Cannot safely rule out a duplicate.',
          );
        }
      }
      if (only == null) {
        groups = groups
            .map(
              (g) => g.id == group.id
                  ? g.copyWith(
                      pending: {
                        ...g.pending,
                        ...missing.map((s) => s.reference),
                      },
                    )
                  : g,
            )
            .toList();
        _persistGroups();
      }
      final target = only == null && !unique.any(isOpen)
          ? 'context-${group.id}'
          : '0';
      for (final session in missing) {
        if (_disposed) break;
        _pendingLaunches[session.reference] = (
          until: _now().add(const Duration(seconds: 45)),
          group: target == '0' ? null : group.id,
        );
        try {
          if (!await launch(session, target)) {
            _pendingLaunches.remove(session.reference);
            return opened == 0
                ? 'Opening cancelled.'
                : 'Opened $opened; remaining tabs cancelled.';
          }
          opened++;
        } catch (_) {
          _pendingLaunches.remove(session.reference);
          rethrow;
        }
      }
      await refresh(force: true, evenInactive: true);
      final skipped = unique.length - missing.length;
      return 'Opened $opened tab${opened == 1 ? '' : 's'}${skipped == 0 ? '.' : '; $skipped already open.'}';
    } catch (error) {
      if (opened > 0) {
        throw StateError('Opened $opened tabs before stopping: $error');
      }
      rethrow;
    } finally {
      opening = false;
      if (opened > 0 && !_disposed) _afterAction();
      if (!_disposed) notifyListeners();
    }
  }

  Map<String, dynamic>? tabFor(TerminalSession session) {
    bool matches(TerminalSession candidate, Map<String, dynamic> tab) {
      var title = (tab['title'] ?? '').toString().trim();
      final suffix = ' | ${candidate.cwd.split('/').last}';
      if (title.endsWith(suffix)) {
        title = title.substring(0, title.length - suffix.length);
      }
      if (candidate.id.isNotEmpty && title == candidate.id) return true;
      final names = {
        candidate.name,
        for (final saved in _savedSessions())
          if (candidate.id.isNotEmpty &&
              saved.isSession &&
              saved.provider == candidate.provider &&
              saved.commandId == candidate.id)
            saved.displayName,
        for (final group in groups)
          for (final member in group.members)
            if (member.id.isNotEmpty && member.reference == candidate.reference)
              member.name,
      }..remove('');
      return names.any(
        (name) =>
            title.endsWith(name) &&
            !RegExp(
              r'[A-Za-z0-9]',
            ).hasMatch(title.substring(0, title.length - name.length)),
      );
    }

    final found = tabs.where((tab) => matches(session, tab)).toList();
    if (found.length != 1 ||
        sessions.where((s) => matches(s, found.single)).length != 1) {
      return null;
    }
    return found.single;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _followup?.cancel();
    _settleTimer?.cancel();
    _subscription?.cancel();
    for (final pending in _pending.values) {
      pending.completeError(StateError('Terminal discovery closed'));
    }
    _pending.clear();
    super.dispose();
  }
}
