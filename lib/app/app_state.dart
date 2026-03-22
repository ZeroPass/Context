import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:rinf/rinf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/bindings/bindings.dart';
import 'models.dart';

enum _PendingOpKind { load, save }

enum ThemeAppearance { light, sepia, dim, dark }

class _PendingOp {
  const _PendingOp({required this.kind, required this.completer});

  final _PendingOpKind kind;
  final Completer<void> completer;
}

class AppState extends ChangeNotifier {
  static const themeSeedColors = <int>[
    0xFFFABD2F,
    0xFFFE8019,
    0xFFFB4934,
    0xFFB8BB26,
    0xFF83A598,
    0xFFD3869B,
  ];

  static const groupPalette = <String>[
    '#FB4934',
    '#FE8019',
    '#FABD2F',
    '#B8BB26',
    '#8EC07C',
    '#83A598',
    '#458588',
    '#D3869B',
  ];
  static const groupColorHexes = groupPalette;

  SharedPreferences? _prefs;
  StreamSubscription<RustSignalPack<UiState>>? _uiStateSub;
  StreamSubscription<RustSignalPack<OpFinished>>? _opFinishedSub;
  Timer? _autosaveTimer;

  BigInt _nextRequestId = BigInt.one;
  final Map<Uint64, _PendingOp> _pendingOps = <Uint64, _PendingOp>{};

  int themeSeedColorValue = themeSeedColors.first;
  String sessionsMarkdownPath = '';
  ThemeAppearance themeAppearance = ThemeAppearance.dark;
  bool busy = false;
  bool dirty = false;
  bool autosaveEnabled = true;
  String filterQuery = '';
  String? status;
  String? lastError;

  List<ConfigItem> items = const <ConfigItem>[];
  List<String> warnings = const <String>[];
  List<RecentContext> recentContexts = const <RecentContext>[];

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _uiStateSub?.cancel();
    _opFinishedSub?.cancel();
    super.dispose();
  }

  Future<void> init() async {
    _uiStateSub?.cancel();
    _opFinishedSub?.cancel();

    _uiStateSub = UiState.rustSignalStream.listen(_onUiState);
    _opFinishedSub = OpFinished.rustSignalStream.listen(_onOpFinished);

    _prefs = await SharedPreferences.getInstance();
    themeSeedColorValue =
        _prefs?.getInt('themeSeedColorValue') ?? themeSeedColorValue;
    themeAppearance = _loadThemeAppearance();
    autosaveEnabled = _prefs?.getBool('autosaveEnabled') ?? true;
    sessionsMarkdownPath = _resolveInitialMarkdownPath(
      _prefs?.getString('sessionsMarkdownPath'),
    );

    InitApp(
      themeSeedColorValue: themeSeedColorValue,
      sessionsMarkdownPath: sessionsMarkdownPath,
    ).sendSignalToRust();

    notifyListeners();
  }

  int get sessionCount => items.where((item) => item.isSession).length;

  int get groupCount => items.where((item) => item.isGroup).length;

  List<ConfigItem> get groups =>
      items.where((item) => item.isGroup).toList(growable: false);

  bool get hasFilter => filterQuery.trim().isNotEmpty;

  List<int> get filteredSessionIndices {
    final query = filterQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return const <int>[];
    }

    final out = <int>[];
    for (var index = 0; index < items.length; index += 1) {
      final item = items[index];
      if (!item.isSession) {
        continue;
      }
      final haystacks = <String>[
        item.displayName.toLowerCase(),
        item.commandId.toLowerCase(),
        item.shortId.toLowerCase(),
      ];
      if (haystacks.any((value) => value.contains(query))) {
        out.add(index);
      }
    }
    return out;
  }

  String _resolveInitialMarkdownPath(String? savedPath) {
    final saved = (savedPath ?? '').trim();
    if (_fileExists(saved)) {
      return saved;
    }
    return _defaultMarkdownPath();
  }

  String _defaultMarkdownPath() {
    final candidates = <String>[];
    final seen = <String>{};

    void addCandidate(String path) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        return;
      }
      candidates.add(trimmed);
    }

    for (final candidate in _preferredCodexOutCandidates()) {
      addCandidate(candidate);
    }

    if (Platform.isWindows) {
      final discovered = _discoverWindowsCodexOutMarkdown();
      if (discovered != null) {
        return discovered;
      }
    }

    if (Platform.isLinux || Platform.isMacOS) {
      final home = (Platform.environment['HOME'] ?? '').trim();
      if (home.isNotEmpty) {
        addCandidate(p.join(home, 'codex-out', 'codex sessions.md'));
      }
    }

    addCandidate(p.join(Directory.current.path, 'codex sessions.md'));
    addCandidate(
      p.normalize(p.join(Directory.current.path, '..', 'codex sessions.md')),
    );

    for (final candidate in candidates) {
      if (_fileExists(candidate)) {
        return candidate;
      }
    }

    return candidates.isEmpty ? '' : candidates.first;
  }

  List<String> _preferredCodexOutCandidates() {
    final candidates = <String>[];

    if (Platform.isWindows) {
      const distros = <String>['Ubuntu-24.04', 'Ubuntu'];
      const linuxUsers = <String>['luka'];

      for (final distro in distros) {
        for (final user in linuxUsers) {
          candidates.add(
            '\\\\wsl.localhost\\$distro\\home\\$user\\codex-out\\codex sessions.md',
          );
          candidates.add(
            '\\\\wsl\$\\$distro\\home\\$user\\codex-out\\codex sessions.md',
          );
        }
      }
    }

    if (Platform.isLinux || Platform.isMacOS) {
      final home = (Platform.environment['HOME'] ?? '').trim();
      if (home.isNotEmpty) {
        candidates.add(p.join(home, 'codex-out', 'codex sessions.md'));
      }
    }

    return candidates;
  }

  String? _discoverWindowsCodexOutMarkdown() {
    for (final root in const <String>[r'\\wsl.localhost', r'\\wsl$']) {
      try {
        final rootDir = Directory(root);
        if (!rootDir.existsSync()) {
          continue;
        }

        for (final distro in rootDir.listSync().whereType<Directory>()) {
          final homeDir = Directory(p.join(distro.path, 'home'));
          if (!homeDir.existsSync()) {
            continue;
          }

          for (final userDir in homeDir.listSync().whereType<Directory>()) {
            final candidate = p.join(
              userDir.path,
              'codex-out',
              'codex sessions.md',
            );
            if (_fileExists(candidate)) {
              return candidate;
            }
          }
        }
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  bool _fileExists(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    try {
      return File(trimmed).existsSync();
    } catch (_) {
      return false;
    }
  }

  void setThemeSeedColor(int value) {
    themeSeedColorValue = value;
    _prefs?.setInt('themeSeedColorValue', themeSeedColorValue);
    SetThemeSeed(value: themeSeedColorValue).sendSignalToRust();
    notifyListeners();
  }

  void setThemeAppearance(ThemeAppearance value) {
    if (themeAppearance == value) {
      return;
    }
    themeAppearance = value;
    _prefs?.setString('themeAppearance', themeAppearance.name);
    notifyListeners();
  }

  ThemeAppearance _loadThemeAppearance() {
    final stored = (_prefs?.getString('themeAppearance') ?? '').trim();
    for (final appearance in ThemeAppearance.values) {
      if (appearance.name == stored) {
        return appearance;
      }
    }

    final legacyDarkMode = _prefs?.getBool('darkModeEnabled');
    if (legacyDarkMode != null) {
      return legacyDarkMode ? ThemeAppearance.dark : ThemeAppearance.light;
    }

    return ThemeAppearance.dark;
  }

  void setAutosaveEnabled(bool value) {
    if (autosaveEnabled == value) {
      return;
    }
    autosaveEnabled = value;
    _prefs?.setBool('autosaveEnabled', autosaveEnabled);
    notifyListeners();
    if (autosaveEnabled) {
      _scheduleAutosave();
    } else {
      _autosaveTimer?.cancel();
    }
  }

  void setFilterQuery(String value) {
    if (filterQuery == value) {
      return;
    }
    filterQuery = value;
    notifyListeners();
  }

  Future<void> loadConfig({String? markdownPath}) async {
    if (markdownPath != null) {
      sessionsMarkdownPath = markdownPath.trim();
      await _prefs?.setString('sessionsMarkdownPath', sessionsMarkdownPath);
    }

    await _runOp(_PendingOpKind.load, (requestId) {
      LoadConfig(
        requestId: requestId,
        sessionsMarkdownPath: sessionsMarkdownPath,
      ).sendSignalToRust();
    });
  }

  Future<void> saveConfig() async {
    _autosaveTimer?.cancel();
    await _runOp(_PendingOpKind.save, (requestId) {
      SaveConfig(
        requestId: requestId,
        sessionsMarkdownPath: sessionsMarkdownPath,
        itemsJson: jsonEncode(
          items.map((item) => item.toJson()).toList(growable: false),
        ),
      ).sendSignalToRust();
    });
  }

  void moveItemToIndex(int itemIndex, int insertIndex) {
    if (itemIndex < 0 ||
        itemIndex >= items.length ||
        items[itemIndex].isGroupEnd) {
      return;
    }

    if (items[itemIndex].isGroup) {
      _moveGroupBlock(itemIndex, insertIndex);
      return;
    }

    final updated = List<ConfigItem>.from(items);
    final item = updated.removeAt(itemIndex);
    var target = insertIndex;
    if (target > itemIndex) {
      target -= 1;
    }
    target = target.clamp(0, updated.length);
    updated.insert(target, item);
    _applyItems(updated);
  }

  void moveItemIntoGroup(int itemIndex, int groupIndex) {
    if (itemIndex < 0 ||
        itemIndex >= items.length ||
        groupIndex < 0 ||
        groupIndex >= items.length ||
        !items[groupIndex].isGroup ||
        !items[itemIndex].isSession) {
      return;
    }

    final endIndex = groupEndIndexForGroup(groupIndex);
    if (endIndex == null) {
      return;
    }

    moveItemToIndex(itemIndex, endIndex);
  }

  void reorderItems(int oldIndex, int newIndex) {
    moveItemToIndex(oldIndex, newIndex);
  }

  void reorderItem(int oldIndex, int newIndex) =>
      reorderItems(oldIndex, newIndex);

  void renameItem(int index, String name) {
    if (index < 0 || index >= items.length) {
      return;
    }

    final item = items[index];
    final normalized = name.trim();
    final fallback = item.isGroup ? 'Group' : '';
    final nextName = normalized.isEmpty ? fallback : normalized;

    if (item.name.trim() == nextName.trim()) {
      return;
    }

    final updated = List<ConfigItem>.from(items);
    updated[index] = item.copyWith(name: nextName);
    _applyItems(updated);
  }

  void renameSession(int index, String title) => renameItem(index, title);

  void toggleSessionFast(int index) {
    if (index < 0 || index >= items.length || !items[index].isSession) {
      return;
    }

    final updated = List<ConfigItem>.from(items);
    final item = updated[index];
    updated[index] = item.copyWith(fast: !item.fast);
    _applyItems(updated);
  }

  void updateGroup(
    int index, {
    required String name,
    required String colorHex,
  }) {
    if (index < 0 || index >= items.length || !items[index].isGroup) {
      return;
    }

    final updated = List<ConfigItem>.from(items);
    updated[index] = updated[index].copyWith(
      name: name.trim().isEmpty ? 'Group' : name.trim(),
      colorHex: _normalizeColorHex(colorHex),
    );
    _applyItems(updated);
  }

  void addGroup({required String name, required String colorHex}) {
    final normalizedName = name.trim().isEmpty ? 'Group' : name.trim();
    final groupId = _makeUniqueGroupId(normalizedName);
    final updated = List<ConfigItem>.from(items)
      ..add(
        ConfigItem.group(
          id: groupId,
          name: normalizedName,
          colorHex: _normalizeColorHex(colorHex),
        ),
      )
      ..add(ConfigItem.groupEnd(id: groupId));
    _applyItems(updated);
  }

  void addSession({
    required String sessionInput,
    required String title,
    String? groupId,
    bool fast = false,
  }) {
    final commandId = _extractCommandId(sessionInput);
    final insertIndex = _insertIndexForGroup(groupId);
    final updated = List<ConfigItem>.from(items)
      ..insert(
        insertIndex,
        ConfigItem.session(commandId: commandId, name: title.trim()).copyWith(
          fast: fast,
        ),
      );
    _applyItems(updated);
  }

  bool hasSessionId(String sessionId) {
    final normalized = sessionId.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    return items.any(
      (item) => item.isSession && item.commandId.trim().toLowerCase() == normalized,
    );
  }

  int _insertIndexForGroup(String? groupId) {
    final normalized = (groupId ?? '').trim();
    if (normalized.isEmpty) {
      final firstGroupIndex = items.indexWhere((item) => item.isGroup);
      return firstGroupIndex == -1 ? items.length : firstGroupIndex;
    }

    final groupIndex = items.indexWhere(
      (item) => item.isGroup && item.id == normalized,
    );
    if (groupIndex == -1) {
      return items.length;
    }

    return groupEndIndexForGroup(groupIndex) ?? items.length;
  }

  String colorHexForItem(int index) {
    if (index < 0 || index >= items.length) {
      return groupPalette[0];
    }

    final item = items[index];
    if (item.isGroup) {
      return _normalizeColorHex(item.colorHex);
    }

    final group = groupForItem(index);
    if (group != null) {
      return _normalizeColorHex(group.colorHex);
    }

    return '#7C6F64';
  }

  bool hasGroupColor(int index) {
    if (index < 0 || index >= items.length) {
      return false;
    }
    if (items[index].isGroup) {
      return true;
    }
    return groupForItem(index) != null;
  }

  int? groupIndexForItem(int index) {
    if (index < 0 || index >= items.length) {
      return null;
    }

    final item = items[index];
    if (item.isGroup) {
      return index;
    }

    for (var cursor = index - 1; cursor >= 0; cursor -= 1) {
      if (items[cursor].isGroupEnd) {
        return null;
      }
      if (items[cursor].isGroup) {
        return cursor;
      }
    }

    return null;
  }

  ConfigItem? groupForItem(int index) {
    final groupIndex = groupIndexForItem(index);
    if (groupIndex == null) {
      return null;
    }
    final candidate = items[groupIndex];
    return candidate.isGroup ? candidate : null;
  }

  bool isGroupedSession(int index) {
    if (index < 0 || index >= items.length) {
      return false;
    }
    return items[index].isSession && groupForItem(index) != null;
  }

  bool groupHasMembers(int index) {
    if (index < 0 || index >= items.length || !items[index].isGroup) {
      return false;
    }
    return memberIndicesForGroup(index).isNotEmpty;
  }

  List<int> memberIndicesForGroup(int index) {
    if (index < 0 || index >= items.length || !items[index].isGroup) {
      return const <int>[];
    }

    final out = <int>[];
    for (var cursor = index + 1; cursor < items.length; cursor += 1) {
      if (items[cursor].isGroupEnd) {
        break;
      }
      if (items[cursor].isSession) {
        out.add(cursor);
      }
    }
    return out;
  }

  bool isFirstSessionInGroup(int index) {
    final groupIndex = groupIndexForItem(index);
    if (groupIndex == null || !isGroupedSession(index)) {
      return false;
    }
    final members = memberIndicesForGroup(groupIndex);
    return members.isNotEmpty && members.first == index;
  }

  bool isLastSessionInGroup(int index) {
    final groupIndex = groupIndexForItem(index);
    if (groupIndex == null || !isGroupedSession(index)) {
      return false;
    }
    final members = memberIndicesForGroup(groupIndex);
    return members.isNotEmpty && members.last == index;
  }

  int? groupEndIndexForGroup(int groupIndex) {
    if (groupIndex < 0 ||
        groupIndex >= items.length ||
        !items[groupIndex].isGroup) {
      return null;
    }

    for (var cursor = groupIndex + 1; cursor < items.length; cursor += 1) {
      if (items[cursor].isGroupEnd) {
        return cursor;
      }
    }

    return null;
  }

  void deleteGroup(int groupIndex, {required bool deleteMembers}) {
    final endIndex = groupEndIndexForGroup(groupIndex);
    if (endIndex == null) {
      return;
    }

    final updated = List<ConfigItem>.from(items);
    if (deleteMembers) {
      updated.removeRange(groupIndex, endIndex + 1);
    } else {
      updated.removeAt(endIndex);
      updated.removeAt(groupIndex);
    }
    _applyItems(updated);
  }

  void deleteSession(int index) {
    if (index < 0 || index >= items.length || !items[index].isSession) {
      return;
    }

    final updated = List<ConfigItem>.from(items)..removeAt(index);
    _applyItems(updated);
  }

  void _moveGroupBlock(int groupIndex, int insertIndex) {
    final endIndex = groupEndIndexForGroup(groupIndex);
    if (endIndex == null) {
      return;
    }

    if (insertIndex > groupIndex && insertIndex <= endIndex + 1) {
      return;
    }

    final updated = List<ConfigItem>.from(items);
    final block = updated.sublist(groupIndex, endIndex + 1);
    updated.removeRange(groupIndex, endIndex + 1);

    var target = insertIndex;
    if (target > groupIndex) {
      target -= (endIndex - groupIndex);
    }
    target = _snapGroupInsertIndex(updated, target.clamp(0, updated.length));

    updated.insertAll(target, block);
    _applyItems(updated);
  }

  int _snapGroupInsertIndex(List<ConfigItem> updated, int insertIndex) {
    var target = insertIndex.clamp(0, updated.length);
    for (var cursor = 0; cursor < updated.length; cursor += 1) {
      if (!updated[cursor].isGroup) {
        continue;
      }
      final end = _groupEndIndexInList(updated, cursor);
      if (end == null) {
        continue;
      }
      if (target > cursor && target <= end) {
        target = end + 1;
      }
      if (cursor >= end) {
        cursor = end;
      }
    }
    return target.clamp(0, updated.length);
  }

  int? _groupEndIndexInList(List<ConfigItem> source, int groupIndex) {
    if (groupIndex < 0 ||
        groupIndex >= source.length ||
        !source[groupIndex].isGroup) {
      return null;
    }

    for (var cursor = groupIndex + 1; cursor < source.length; cursor += 1) {
      if (source[cursor].isGroupEnd) {
        return cursor;
      }
    }

    return null;
  }

  void _applyItems(List<ConfigItem> updated) {
    items = updated;
    dirty = true;
    notifyListeners();
    _scheduleAutosave();
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    if (!autosaveEnabled || !dirty || sessionsMarkdownPath.trim().isEmpty) {
      return;
    }

    _autosaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_runAutosave());
    });
  }

  Future<void> _runAutosave() async {
    if (!autosaveEnabled ||
        !dirty ||
        busy ||
        sessionsMarkdownPath.trim().isEmpty) {
      return;
    }

    try {
      await saveConfig();
    } catch (_) {
      // Save failures are already surfaced through the Rust signal state.
    }
  }

  Future<void> _runOp(
    _PendingOpKind kind,
    void Function(Uint64 requestId) sender,
  ) async {
    final requestId = Uint64.fromBigInt(_nextRequestId);
    _nextRequestId += BigInt.one;

    final completer = Completer<void>();
    _pendingOps[requestId] = _PendingOp(kind: kind, completer: completer);
    sender(requestId);
    await completer.future;
  }

  void _onUiState(RustSignalPack<UiState> signalPack) {
    final state = signalPack.message;
    themeSeedColorValue = state.themeSeedColorValue;
    busy = state.busy;
    status = state.status;
    lastError = state.lastError;
    sessionsMarkdownPath = state.sessionsMarkdownPath;
    items = _decodeItems(state.itemsJson);
    warnings = _decodeWarnings(state.warningsJson);
    recentContexts = _decodeRecentContexts(state.recentContextsJson);
    notifyListeners();
  }

  void _onOpFinished(RustSignalPack<OpFinished> signalPack) {
    final msg = signalPack.message;
    final pending = _pendingOps.remove(msg.requestId);
    if (pending == null) {
      return;
    }

    if (msg.ok) {
      if (pending.kind == _PendingOpKind.load ||
          pending.kind == _PendingOpKind.save) {
        dirty = false;
      }
      pending.completer.complete();
    } else {
      pending.completer.completeError(
        Exception(msg.error ?? 'Operation failed.'),
      );
    }

    notifyListeners();
  }

  List<ConfigItem> _decodeItems(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! List) {
      return const <ConfigItem>[];
    }
    return decoded
        .whereType<Map>()
        .map((item) => ConfigItem.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  List<String> _decodeWarnings(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! List) {
      return const <String>[];
    }
    return decoded.map((item) => item.toString()).toList(growable: false);
  }

  List<RecentContext> _decodeRecentContexts(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! List) {
      return const <RecentContext>[];
    }
    return decoded
        .whereType<Map>()
        .map(
          (item) => RecentContext.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  String _extractCommandId(String input) {
    final trimmed = input.trim();
    final match = RegExp(
      r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
    ).firstMatch(trimmed);
    final id = match?.group(1)?.toLowerCase();
    if (id == null || id.isEmpty) {
      throw FormatException('Enter a full session id or a codex command.');
    }
    return id;
  }

  String _makeUniqueGroupId(String name) {
    final base = _slugify(name);
    final used = items
        .where((item) => item.isGroup)
        .map((item) => item.id.trim().toLowerCase())
        .toSet();

    var candidate = base;
    var suffix = 2;
    while (used.contains(candidate)) {
      candidate = '$base-$suffix';
      suffix += 1;
    }
    return candidate;
  }

  String _slugify(String value) {
    final buffer = StringBuffer();
    for (final rune in value.trim().toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      final isAlphaNum = RegExp(r'[a-z0-9]').hasMatch(ch);
      if (isAlphaNum) {
        buffer.write(ch);
      } else if (buffer.isNotEmpty && !buffer.toString().endsWith('-')) {
        buffer.write('-');
      }
    }

    final out = buffer.toString().replaceAll(RegExp(r'-+'), '-');
    final trimmed = out.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'group' : trimmed;
  }

  String _normalizeColorHex(String colorHex) {
    final normalized = colorHex.trim().toUpperCase();
    if (RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalized)) {
      return normalized;
    }
    return groupPalette.first;
  }
}
