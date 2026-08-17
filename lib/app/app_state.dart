import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:rinf/rinf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/bindings/bindings.dart';
import 'models.dart';

enum _PendingOpKind {
  load,
  save,
  codexAccountLoad,
  codexAccountSave,
  codexAccountSwitch,
  codexAccountRename,
  codexAccountDelete,
}

enum ThemeAppearance { light, sepia, dim, dark }

class _PendingOp {
  const _PendingOp({required this.kind, required this.completer});

  final _PendingOpKind kind;
  final Completer<void> completer;
}

class AppState extends ChangeNotifier with WidgetsBindingObserver {
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
  Timer? _recentRefreshTimer;
  bool _pendingRecentRefresh = true;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  static const _recentRefreshInterval = Duration(seconds: 30);

  BigInt _nextRequestId = BigInt.one;
  final Map<Uint64, _PendingOp> _pendingOps = <Uint64, _PendingOp>{};

  int themeSeedColorValue = themeSeedColors.first;
  String sessionsMarkdownPath = '';
  ThemeAppearance themeAppearance = ThemeAppearance.dark;
  bool busy = false;
  bool dirty = false;
  bool autosaveEnabled = true;
  bool recentBusy = false;
  SessionProvider recentProvider = SessionProvider.codex;
  String filterQuery = '';
  String? status;
  String? lastError;
  String? recentStatus;
  List<CodexAccount> codexAccounts = const <CodexAccount>[];
  String? codexActiveAccount;
  bool codexAccountBusy = false;
  String? codexAccountStatus;
  String? codexAccountError;

  List<ConfigItem> items = const <ConfigItem>[];
  List<String> warnings = const <String>[];
  List<RecentContext> recentCodex = const <RecentContext>[];
  List<RecentContext> recentKimi = const <RecentContext>[];
  List<RecentContext> recentOpencode = const <RecentContext>[];
  List<RecentContext> recentQwen = const <RecentContext>[];
  bool _codexAccountRequestInFlight = false;
  bool _codexAccountsLoaded = false;
  bool _codexAccountLoadAwaitingState = false;
  int _codexAccountsStateVersion = 0;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autosaveTimer?.cancel();
    _recentRefreshTimer?.cancel();
    _uiStateSub?.cancel();
    _opFinishedSub?.cancel();
    super.dispose();
  }

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
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
    recentProvider = SessionProviderInfo.parse(
      _prefs?.getString('recentProvider'),
    );
    codexActiveAccount = _normalizeCodexAccountSlot(
      _prefs?.getString('codexActiveAccount'),
    );

    InitApp(
      themeSeedColorValue: themeSeedColorValue,
      sessionsMarkdownPath: sessionsMarkdownPath,
    ).sendSignalToRust();
    unawaited(loadCodexAccounts());

    _startRecentRefreshTimer();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _refreshLiveData();
    }
  }

  void _startRecentRefreshTimer() {
    _recentRefreshTimer?.cancel();
    _recentRefreshTimer = Timer.periodic(
      _recentRefreshInterval,
      (_) => _refreshLiveData(),
    );
  }

  void _refreshLiveData() {
    unawaited(refreshRecent());
    if (recentProvider == SessionProvider.codex) {
      unawaited(loadCodexAccounts());
    }
  }

  int get sessionCount => items.where((item) => item.isSession).length;

  int get groupCount => items.where((item) => item.isGroup).length;

  List<ConfigItem> get groups =>
      items.where((item) => item.isGroup).toList(growable: false);

  List<RecentContext> get visibleRecent => switch (recentProvider) {
    SessionProvider.codex => recentCodex,
    SessionProvider.kimi => recentKimi,
    SessionProvider.opencode => recentOpencode,
    SessionProvider.qwen => recentQwen,
  };

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
        item.provider.label.toLowerCase(),
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

  void setRecentProvider(SessionProvider value) {
    if (recentProvider == value) {
      if (value == SessionProvider.codex) {
        unawaited(loadCodexAccounts());
      }
      return;
    }
    recentProvider = value;
    _prefs?.setString('recentProvider', value.key);
    notifyListeners();
    if (value == SessionProvider.codex) {
      unawaited(loadCodexAccounts());
    }
  }

  Future<void> loadCodexAccounts() async {
    if (_codexAccountRequestInFlight || sessionsMarkdownPath.trim().isEmpty) {
      return;
    }

    final stateVersionBeforeLoad = _codexAccountsStateVersion;
    _codexAccountsLoaded = false;
    _codexAccountLoadAwaitingState = false;
    try {
      await _runCodexAccountRequest(
        kind: _PendingOpKind.codexAccountLoad,
        status: 'Loading Codex accounts...',
        sender: (requestId) {
          LoadCodexAccounts(
            requestId: requestId,
            sessionsMarkdownPath: sessionsMarkdownPath,
          ).sendSignalToRust();
        },
      );
      if (_codexAccountsStateVersion != stateVersionBeforeLoad) {
        _codexAccountsLoaded = true;
        _reconcileCodexActiveAccount();
        notifyListeners();
      } else {
        _codexAccountLoadAwaitingState = true;
      }
    } catch (_) {
      _codexAccountLoadAwaitingState = false;
      // The account error is exposed through codexAccountError.
    }
  }

  Future<void> saveCodexAccount(String slot, [String? displayName]) async {
    final normalizedSlot = _normalizeCodexAccountSlot(slot);
    final normalizedDisplayName = _normalizeCodexAccountDisplayName(
      displayName ?? normalizedSlot,
    );
    if (normalizedSlot == null || !_isValidCodexAccountSlot(normalizedSlot)) {
      throw const FormatException(
        'Use a positive numeric account slot, such as 1 or 2.',
      );
    }
    if (normalizedDisplayName == null) {
      throw const FormatException('Enter a non-empty display name.');
    }

    await _runCodexAccountRequest(
      kind: _PendingOpKind.codexAccountSave,
      status: 'Saving current Codex account in slot $normalizedSlot...',
      sender: (requestId) {
        SaveCodexAccount(
          requestId: requestId,
          sessionsMarkdownPath: sessionsMarkdownPath,
          slot: normalizedSlot,
          displayName: normalizedDisplayName,
        ).sendSignalToRust();
      },
    );
    await loadCodexAccounts();
  }

  Future<void> switchCodexAccount(String slot) async {
    final targetSlot = _normalizeCodexAccountSlot(slot);
    if (targetSlot == null) {
      throw const FormatException('Choose a saved Codex account first.');
    }

    final currentSlot = codexActiveAccount ?? '';
    if (_sameCodexAccountSlot(currentSlot, targetSlot)) {
      return;
    }

    await _runCodexAccountRequest(
      kind: _PendingOpKind.codexAccountSwitch,
      status: 'Switching to Codex account slot $targetSlot...',
      sender: (requestId) {
        SwitchCodexAccount(
          requestId: requestId,
          sessionsMarkdownPath: sessionsMarkdownPath,
          currentSlot: currentSlot,
          targetSlot: targetSlot,
        ).sendSignalToRust();
      },
    );

    codexActiveAccount = targetSlot;
    await _prefs?.setString('codexActiveAccount', targetSlot);
    notifyListeners();
    await loadCodexAccounts();
  }

  Future<void> renameCodexAccount(String slot, String displayName) async {
    final normalizedSlot = _normalizeCodexAccountSlot(slot);
    final normalizedDisplayName = _normalizeCodexAccountDisplayName(
      displayName,
    );
    if (normalizedSlot == null) {
      throw const FormatException('Choose a saved Codex account first.');
    }
    if (normalizedDisplayName == null) {
      throw const FormatException('Enter a non-empty display name.');
    }

    await _runCodexAccountRequest(
      kind: _PendingOpKind.codexAccountRename,
      status: 'Renaming Codex account slot $normalizedSlot...',
      sender: (requestId) {
        RenameCodexAccount(
          requestId: requestId,
          sessionsMarkdownPath: sessionsMarkdownPath,
          slot: normalizedSlot,
          displayName: normalizedDisplayName,
        ).sendSignalToRust();
      },
    );
    await loadCodexAccounts();
  }

  Future<void> deleteCodexAccount(String slot) async {
    final normalizedSlot = _normalizeCodexAccountSlot(slot);
    if (normalizedSlot == null) {
      throw const FormatException('Choose a saved Codex account first.');
    }
    final deletingActive = _sameCodexAccountSlot(
      codexActiveAccount,
      normalizedSlot,
    );

    await _runCodexAccountRequest(
      kind: _PendingOpKind.codexAccountDelete,
      status: 'Deleting Codex account slot $normalizedSlot...',
      sender: (requestId) {
        DeleteCodexAccount(
          requestId: requestId,
          sessionsMarkdownPath: sessionsMarkdownPath,
          slot: normalizedSlot,
        ).sendSignalToRust();
      },
    );

    if (deletingActive) {
      codexActiveAccount = null;
      await _prefs?.remove('codexActiveAccount');
      notifyListeners();
    }
    await loadCodexAccounts();
  }

  Future<void> _runCodexAccountRequest({
    required _PendingOpKind kind,
    required String status,
    required void Function(Uint64 requestId) sender,
  }) async {
    if (_codexAccountRequestInFlight) {
      throw StateError('A Codex account operation is already running.');
    }
    if (sessionsMarkdownPath.trim().isEmpty) {
      throw StateError('Pick a sessions markdown file first.');
    }

    _codexAccountRequestInFlight = true;
    codexAccountBusy = true;
    codexAccountStatus = status;
    codexAccountError = null;
    notifyListeners();

    try {
      await _runOp(kind, sender);
    } catch (error) {
      codexAccountError = _accountErrorText(error);
      codexAccountStatus = 'Codex account operation failed.';
      notifyListeners();
      rethrow;
    } finally {
      _codexAccountRequestInFlight = false;
      codexAccountBusy = false;
      notifyListeners();
    }
  }

  String? _normalizeCodexAccountSlot(String? value) {
    final normalized = (value ?? '').trim();
    return normalized.isEmpty ? null : normalized;
  }

  String? _normalizeCodexAccountDisplayName(String? value) {
    final normalized = (value ?? '').trim();
    return normalized.isEmpty ? null : normalized;
  }

  bool _isValidCodexAccountSlot(String value) {
    return RegExp(r'^[1-9][0-9]*$').hasMatch(value);
  }

  bool _sameCodexAccountSlot(String? first, String? second) {
    final left = _normalizeCodexAccountSlot(first);
    final right = _normalizeCodexAccountSlot(second);
    return left != null &&
        right != null &&
        left.toLowerCase() == right.toLowerCase();
  }

  String _accountErrorText(Object error) {
    final text = error.toString().trim();
    return text.startsWith('Exception: ')
        ? text.substring('Exception: '.length)
        : text;
  }

  Future<void> loadConfig({String? markdownPath}) async {
    if (markdownPath != null) {
      final nextPath = markdownPath.trim();
      if (nextPath != sessionsMarkdownPath) {
        _codexAccountsLoaded = false;
        codexAccounts = const <CodexAccount>[];
      }
      sessionsMarkdownPath = nextPath;
      await _prefs?.setString('sessionsMarkdownPath', sessionsMarkdownPath);
    }

    _pendingRecentRefresh = true;
    notifyListeners();

    await _runOp(_PendingOpKind.load, (requestId) {
      LoadConfig(
        requestId: requestId,
        sessionsMarkdownPath: sessionsMarkdownPath,
      ).sendSignalToRust();
    });
    if (recentProvider == SessionProvider.codex) {
      unawaited(loadCodexAccounts());
    }
  }

  Future<void> refreshRecent({bool queueIfBusy = false}) async {
    if (_lifecycleState != AppLifecycleState.resumed ||
        sessionsMarkdownPath.trim().isEmpty) {
      return;
    }

    if (busy || recentBusy) {
      if (queueIfBusy) {
        _pendingRecentRefresh = true;
      }
      return;
    }

    _pendingRecentRefresh = false;

    RefreshRecent(
      requestId: Uint64.fromBigInt(BigInt.zero),
      sessionsMarkdownPath: sessionsMarkdownPath,
    ).sendSignalToRust();
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

  Future<String> createExampleMarkdownFile({String? markdownPath}) async {
    final targetPath = (markdownPath ?? sessionsMarkdownPath).trim();
    if (targetPath.isEmpty) {
      throw Exception('Pick a markdown path first.');
    }

    final file = File(targetPath);
    if (file.existsSync()) {
      throw Exception('Markdown file already exists: $targetPath');
    }

    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }

    await file.writeAsString(_buildExampleMarkdown());
    await loadConfig(markdownPath: targetPath);
    return targetPath;
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
    required SessionProvider provider,
    String? groupId,
  }) {
    final parsed = parseSessionInput(sessionInput, fallback: provider);
    final insertIndex = _insertIndexForGroup(groupId);
    final updated = List<ConfigItem>.from(items)
      ..insert(
        insertIndex,
        ConfigItem.session(
          commandId: parsed.id,
          name: title.trim(),
          provider: parsed.provider,
        ),
      );
    _applyItems(updated);
  }

  bool hasSession(SessionProvider provider, String sessionId) {
    final normalized = sessionId.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    return items.any(
      (item) =>
          item.isSession &&
          item.provider == provider &&
          item.commandId.trim().toLowerCase() == normalized,
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
    recentBusy = state.recentBusy;
    recentStatus = state.recentStatus;
    if (state.sessionsMarkdownPath != sessionsMarkdownPath) {
      _codexAccountsLoaded = false;
    }
    codexAccounts = _decodeCodexAccounts(state.codexAccountsJson);
    _codexAccountsStateVersion += 1;
    if (_codexAccountLoadAwaitingState) {
      _codexAccountLoadAwaitingState = false;
      _codexAccountsLoaded = true;
    }
    final nativeActiveAccount = _normalizeCodexAccountSlot(
      state.codexActiveAccount,
    );
    if (nativeActiveAccount != null) {
      codexActiveAccount = nativeActiveAccount;
      _prefs?.setString('codexActiveAccount', nativeActiveAccount);
    } else if (_codexAccountsLoaded) {
      _reconcileCodexActiveAccount();
    }
    codexAccountBusy = state.codexAccountBusy || _codexAccountRequestInFlight;
    codexAccountStatus = state.codexAccountStatus;
    codexAccountError = state.codexAccountError;
    sessionsMarkdownPath = state.sessionsMarkdownPath;
    items = _decodeItems(state.itemsJson);
    warnings = _decodeWarnings(state.warningsJson);
    recentCodex = _decodeRecentContexts(state.recentCodexJson);
    recentKimi = _decodeRecentContexts(state.recentKimiJson);
    recentOpencode = _decodeRecentContexts(state.recentOpencodeJson);
    recentQwen = _decodeRecentContexts(state.recentQwenJson);
    final shouldStartPendingRecentRefresh =
        _pendingRecentRefresh &&
        !busy &&
        lastError == null &&
        !recentBusy &&
        sessionsMarkdownPath.trim().isNotEmpty;
    if (shouldStartPendingRecentRefresh) {
      _pendingRecentRefresh = false;
      RefreshRecent(
        requestId: Uint64.fromBigInt(BigInt.zero),
        sessionsMarkdownPath: sessionsMarkdownPath,
      ).sendSignalToRust();
    }
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
        .map((item) => RecentContext.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  List<CodexAccount> _decodeCodexAccounts(String jsonText) {
    final decoded = jsonDecode(jsonText);
    final entries = decoded is List
        ? decoded
        : decoded is Map && decoded['accounts'] is List
        ? decoded['accounts'] as List
        : null;
    if (entries == null) {
      return const <CodexAccount>[];
    }

    final out = <CodexAccount>[];
    final seen = <String>{};
    for (final item in entries) {
      final account = switch (item) {
        Map() => CodexAccount.fromJson(Map<String, dynamic>.from(item)),
        String() => CodexAccount(slot: item.trim(), name: item.trim()),
        _ => null,
      };
      if (account == null ||
          account.slot.isEmpty ||
          account.displayName.isEmpty ||
          !seen.add(account.identityKey)) {
        continue;
      }
      out.add(account);
    }
    return out.toList(growable: false);
  }

  void _reconcileCodexActiveAccount() {
    final active = codexActiveAccount;
    if (active == null ||
        codexAccounts.any(
          (account) => _sameCodexAccountSlot(account.slot, active),
        )) {
      return;
    }
    codexActiveAccount = null;
    _prefs?.remove('codexActiveAccount');
  }

  ({SessionProvider provider, String id}) parseSessionInput(
    String input, {
    required SessionProvider fallback,
  }) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Enter a session id or resume command.');
    }

    final codexMatch = RegExp(
      r'(?:^|\s)codex(?:\.exe)?\s+(?:resume|fork)\s+([A-Za-z0-9._-]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (codexMatch != null) {
      return (
        provider: SessionProvider.codex,
        id: codexMatch.group(1)!.toLowerCase(),
      );
    }

    final kimiMatch = RegExp(
      r'(?:^|[\s&])kimi(?:\.exe)?\s+.*?(?:--session|--resume|-S|-r)(?:=|\s+)([A-Za-z0-9._-]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (kimiMatch != null) {
      return (provider: SessionProvider.kimi, id: kimiMatch.group(1)!);
    }

    final opencodeMatch = RegExp(
      r'(?:^|[\s&])opencode(?:\.exe)?\s+.*?(?:--session|-s)(?:=|\s+)([A-Za-z0-9._-]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (opencodeMatch != null) {
      return (provider: SessionProvider.opencode, id: opencodeMatch.group(1)!);
    }

    final qwenMatch = RegExp(
      r'(?:^|[\s&])qwen(?:\.exe)?\s+.*?(?:--resume|-r)(?:=|\s+)([A-Za-z0-9._-]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (qwenMatch != null) {
      return (provider: SessionProvider.qwen, id: qwenMatch.group(1)!);
    }

    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(trimmed)) {
      throw const FormatException(
        'Enter a session id, Codex resume command, Kimi session command, OpenCode session command, or Qwen resume command.',
      );
    }

    final normalized = trimmed.toLowerCase();
    final inferred = normalized.startsWith('session_')
        ? SessionProvider.kimi
        : normalized.startsWith('ses_')
        ? SessionProvider.opencode
        : fallback;
    return (provider: inferred, id: trimmed);
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

  String _buildExampleMarkdown() {
    return '''
<!-- context-group: starter|Starter|#83A598 -->

# Codex Work
codex resume 11111111-1111-1111-1111-111111111111

# Another Codex Work
codex resume 22222222-2222-2222-2222-222222222222

<!-- /context-group -->

# Kimi Work
kimi --session session_example_33333333
''';
  }
}
