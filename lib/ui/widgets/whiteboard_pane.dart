import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../app/app_state.dart';
import '../../app/file_references.dart';
import '../../app/models.dart';
import '../../app/whiteboard.dart';
import '../../app/whiteboard_file.dart';
import '../copy_feedback.dart';
import 'passive_tooltip.dart';
import 'recent_sessions.dart';
import 'file_preview.dart';
import 'file_location_button.dart';
import 'video_preview.dart';

class WhiteboardPane extends StatefulWidget {
  const WhiteboardPane({
    super.key,
    required this.appState,
    this.reader,
    this.videoFactory = NativePreviewVideoSession.new,
    this.openFile = openReference,
  });
  final AppState appState;
  final WhiteboardReader? reader;
  final PreviewVideoSession Function() videoFactory;
  final ReferenceOpener openFile;
  @override
  State<WhiteboardPane> createState() => _WhiteboardPaneState();
}

class _WhiteboardPaneState extends State<WhiteboardPane>
    with WidgetsBindingObserver {
  late final WhiteboardReader _reader;
  late final WhiteboardPreviewController _previewController;
  final _paneScroll = ScrollController();
  Timer? _timer;
  StreamSubscription<void>? _fileChanges;
  bool get _pushMode => _reader is FileWhiteboardReader;
  final _historyCache = <String, ResponseHistory>{};
  List<RecentContext> _recent = const [];
  RecentContext? _selected;
  ResponseHistory? _history;
  FileReferenceResolver? _resolver;
  String? _preview;
  String? _recentError;
  String? _responseError;
  String _path = '';
  String _rootsKey = '';
  List<ConfigItem>? _savedItems;
  bool _moreSessions = false;
  bool _moreResponses = false;
  bool _recentBusy = false;
  bool _responseBusy = false;
  bool _recentReading = false;
  bool _recentAttempted = false;
  bool _responseReading = false;
  bool _repeatRecent = false;
  bool _repeatHistory = false;
  bool _followLatest = true;
  bool _visible = true;
  int _listGeneration = 0;
  int _responseGeneration = 0;
  SessionProvider _provider = SessionProvider.codex;

  @override
  void initState() {
    super.initState();
    _reader = widget.reader ?? FileWhiteboardReader();
    _previewController = WhiteboardPreviewController(
      resolverFor: (file) => FileReferenceResolver(
        markdownPath: file,
        roots: widget.appState.effectiveWhiteboardRoots,
        workDir: file.substring(0, file.lastIndexOf(RegExp(r'[/\\]'))),
      ),
      videoFactory: widget.videoFactory,
    );
    widget.appState.addListener(_appChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _appChanged());
  }

  bool get _canPoll =>
      _visible &&
      widget.appState.sessionWindowActive &&
      widget.appState.sessionsReady &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasVisible = _visible;
    _visible = TickerMode.valuesOf(context).enabled;
    _schedulePolling();
    if (_visible && !wasVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _poll();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _schedulePolling();
    if (state == AppLifecycleState.resumed) _poll();
  }

  void _schedulePolling() {
    if (_pushMode) {
      _timer?.cancel();
      _timer = null;
      if (!_canPoll || _path.isEmpty) {
        unawaited(_fileChanges?.cancel());
        _fileChanges = null;
      } else {
        _fileChanges ??= (_reader as FileWhiteboardReader)
            .changes(_path)
            .listen((_) => _poll());
      }
      return;
    }
    if (_canPoll && _timer != null) return;
    _timer?.cancel();
    _timer = null;
    if (_canPoll) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    }
  }

  void _poll() {
    if (!mounted || !_canPoll || _path.isEmpty) return;
    if (!_recentReading) {
      unawaited(_refresh(background: _recentAttempted));
    } else if (_pushMode) {
      _repeatRecent = true;
    }
    if (_selected != null && !_responseReading) {
      unawaited(_loadHistory(background: true));
    } else if (_pushMode && _responseReading) {
      _repeatHistory = true;
    }
  }

  void _appChanged() {
    if (!mounted) return;
    final wasPolling = _timer != null || _fileChanges != null;
    _schedulePolling();
    final path = widget.appState.sessionsMarkdownPath;
    final roots = widget.appState.effectiveWhiteboardRoots.join('\n');
    final changed =
        path != _path ||
        roots != _rootsKey ||
        !identical(_savedItems, widget.appState.items);
    if (!changed) {
      if (_canPoll && !wasPolling) _poll();
      return;
    }
    _savedItems = widget.appState.items;
    if (path != _path) {
      unawaited(_fileChanges?.cancel());
      _fileChanges = null;
      _path = path;
      _listGeneration++;
      _responseGeneration++;
      _recentBusy = false;
      _responseBusy = false;
      _recentReading = false;
      _recentAttempted = false;
      _responseReading = false;
      _repeatRecent = false;
      _repeatHistory = false;
      _followLatest = true;
      _historyCache.clear();
      _recent = const [];
      _selected = null;
      _history = null;
      _preview = null;
      _previewController.close();
      _schedulePolling();
      if (_canPoll) unawaited(_refresh());
    }
    if (roots != _rootsKey) {
      _rootsKey = roots;
      _makeResolver();
    }
    setState(() {});
  }

  void _makeResolver() {
    _resolver = FileReferenceResolver(
      markdownPath: _path,
      roots: widget.appState.effectiveWhiteboardRoots,
      workDir: _history?.workDir ?? _selected?.workDir,
    );
  }

  bool _sameRecent(List<RecentContext> items) {
    if (items.length != _recent.length) return false;
    for (var i = 0; i < items.length; i++) {
      final a = items[i];
      final b = _recent[i];
      if (a.identityKey != b.identityKey ||
          a.updatedAt != b.updatedAt ||
          a.title != b.title ||
          a.workDir != b.workDir) {
        return false;
      }
    }
    return true;
  }

  Future<void> _refresh({bool background = false}) async {
    if (_path.isEmpty) return;
    if (_recentReading) {
      if (!background) _repeatRecent = true;
      return;
    }
    final generation = ++_listGeneration;
    _recentReading = true;
    _recentAttempted = true;
    if (!background) {
      setState(() {
        _recentBusy = true;
        _recentError = null;
      });
    }
    try {
      final items = await _reader.recent(
        _path,
        _provider,
        _moreSessions ? 10 : 3,
      );
      if (!mounted || generation != _listGeneration) return;
      if (!_sameRecent(items) || _recentError != null) {
        setState(() {
          _recent = items;
          _recentError = null;
        });
      }
      if (_selected == null && items.isNotEmpty) {
        _select(items.first, userInitiated: false);
      } else if ((_followLatest ||
              (_pushMode &&
                  !items.any(
                    (s) => s.identityKey == _selected?.identityKey,
                  ))) &&
          items.isNotEmpty &&
          items.first.identityKey != _selected?.identityKey) {
        _select(items.first, userInitiated: false);
      } else if (_selected != null) {
        final updated = items
            .where((s) => s.identityKey == _selected!.identityKey)
            .firstOrNull;
        if (updated != null) _selected = updated;
      }
      if (_pushMode) {
        final retained = items.map((s) => s.identityKey).toSet();
        _historyCache.removeWhere((key, _) => !retained.contains(key));
        if (items.isEmpty && _selected != null) {
          _previewController.close();
          setState(() {
            _selected = null;
            _history = null;
            _preview = null;
          });
        }
      }
    } catch (error) {
      if (mounted && generation == _listGeneration) {
        setState(() => _recentError = '$error');
      }
    } finally {
      if (mounted && generation == _listGeneration) {
        _recentReading = false;
        if (_recentBusy) setState(() => _recentBusy = false);
        if (_repeatRecent) {
          _repeatRecent = false;
          unawaited(_refresh(background: _pushMode));
        }
      }
    }
  }

  void _select(RecentContext session, {bool userInitiated = true}) {
    if (userInitiated) _previewController.close();
    final cached = _historyCache.remove(session.identityKey);
    if (cached != null) _historyCache[session.identityKey] = cached;
    setState(() {
      if (userInitiated) {
        _followLatest = _recent.firstOrNull?.identityKey == session.identityKey;
        _preview = null;
        _moreResponses = false;
      }
      _selected = session;
      _history = cached;
      _responseError = null;
      _responseReading = false;
      _responseBusy = false;
      _repeatHistory = false;
    });
    _makeResolver();
    if (userInitiated && _paneScroll.hasClients) _paneScroll.jumpTo(0);
    unawaited(_loadHistory(background: cached != null));
  }

  bool _sameHistory(ResponseHistory result) {
    final previous = _history;
    if (previous == null ||
        previous.workDir != result.workDir ||
        previous.bounded != result.bounded ||
        previous.responses.length != result.responses.length) {
      return false;
    }
    for (var i = 0; i < result.responses.length; i++) {
      final a = previous.responses[i];
      final b = result.responses[i];
      if (a.turnId != b.turnId ||
          a.timestamp != b.timestamp ||
          a.text != b.text) {
        return false;
      }
    }
    return true;
  }

  void _cacheHistory(String key, ResponseHistory history) {
    _historyCache.remove(key);
    _historyCache[key] = history;
    int bytes() => _historyCache.values.fold(
      0,
      (sum, value) =>
          sum + value.responses.fold(0, (n, r) => n + r.text.length * 2),
    );
    while (_historyCache.length > 10 || bytes() > 8 * 1024 * 1024) {
      _historyCache.remove(_historyCache.keys.first);
    }
  }

  Future<void> _loadHistory({bool background = false}) async {
    final session = _selected;
    if (session == null) return;
    if (_responseReading) {
      if (!background) _repeatHistory = true;
      return;
    }
    final generation = ++_responseGeneration;
    final limit = _moreResponses ? 3 : 1;
    _responseReading = true;
    if (!background) {
      setState(() {
        _responseBusy = true;
        _responseError = null;
      });
    }
    try {
      final result = await _reader.history(_path, session, limit);
      if (!mounted || generation != _responseGeneration) return;
      _cacheHistory(session.identityKey, result);
      if (!background || !_sameHistory(result) || _responseError != null) {
        setState(() {
          _history = result;
          _responseError = null;
          _makeResolver();
        });
      }
    } catch (error) {
      if (mounted && generation == _responseGeneration) {
        setState(() => _responseError = '$error');
      }
    } finally {
      if (mounted && generation == _responseGeneration) {
        _responseReading = false;
        if (_responseBusy) setState(() => _responseBusy = false);
        if (_repeatHistory) {
          _repeatHistory = false;
          unawaited(_loadHistory(background: _pushMode));
        }
      }
    }
  }

  String _title(RecentContext session) {
    final saved = widget.appState.items
        .where(
          (item) =>
              item.isSession &&
              item.provider == session.provider &&
              item.commandId.trim() == session.id,
        )
        .firstOrNull;
    return saved?.name ?? session.displayTitle;
  }

  @override
  void dispose() {
    widget.appState.removeListener(_appChanged);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_fileChanges?.cancel());
    _paneScroll.dispose();
    _previewController.dispose();
    if (widget.reader == null) _reader.dispose();
    super.dispose();
  }

  Future<void> _activate(
    String reference, {
    bool external = false,
    bool reveal = false,
    FileReferenceResolver? resolver,
  }) async {
    try {
      final uri = Uri.tryParse(reference);
      if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
        await widget.openFile(reference);
        return;
      }
      final resolved = await (resolver ?? _resolver!).resolve(reference);
      if (!mounted) return;
      if (resolved.missing) {
        _message('File not found. Add a search location in Settings.');
        return;
      }
      String? path = resolved.paths.first;
      if (resolved.paths.length > 1) {
        path = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Choose file location'),
            children: resolved.paths
                .map(
                  (path) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, path),
                    child: Text(path),
                  ),
                )
                .toList(),
          ),
        );
      }
      if (path == null || !mounted) return;
      if (!external && !reveal) {
        if (isWhiteboardPreview(path)) {
          setState(() => _preview = path);
          unawaited(_previewController.open(path));
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _paneScroll.hasClients) _paneScroll.jumpTo(0);
          });
        }
        // External opening must be requested explicitly through the folder menu.
        return;
      }
      if (!reveal && isRunnableFile(path)) {
        final allowed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Open executable file?'),
            content: Text('This file may run code:\n$path'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Open'),
              ),
            ],
          ),
        );
        if (allowed != true) return;
      }
      await widget.openFile(path, reveal: reveal);
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  void _message(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Widget _icon(String tip, IconData icon, VoidCallback? onPressed) =>
      PassiveTooltip(
        message: tip,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, size: 17),
          visualDensity: VisualDensity.compact,
        ),
      );

  Widget _reference(
    String label,
    String source, {
    FileReferenceResolver? resolver,
  }) {
    final fileResolver = resolver ?? _resolver!;
    final scheme = Theme.of(context).colorScheme;
    final visibleLabel = fileReferenceLabel(label, source);
    final uri = Uri.tryParse(source);
    if (uri?.scheme == 'https' || uri?.scheme == 'http') {
      return PassiveTooltip(
        message: 'Open in browser',
        child: InkWell(
          onTap: () => _activate(source),
          child: Text(
            visibleLabel,
            style: TextStyle(
              color: scheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      );
    }
    return FutureBuilder<ResolvedReference>(
      future: fileResolver.resolve(source),
      builder: (context, snapshot) {
        final missing = snapshot.hasError || snapshot.data?.missing == true;
        final path = snapshot.data?.paths.firstOrNull;
        final preview = path != null && isWhiteboardPreview(path);
        final text = Text(
          visibleLabel,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: preview
                ? scheme.primary
                : missing
                ? scheme.onSurfaceVariant
                : scheme.onSurface,
            decoration: preview
                ? TextDecoration.underline
                : TextDecoration.none,
          ),
        );
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          children: [
            PassiveTooltip(
              message: missing
                  ? 'File not found. Add a search location.'
                  : path == null
                  ? 'Checking file location...'
                  : preview
                  ? 'Open in Context'
                  : 'Right-click folder to open in default app',
              child: preview
                  ? InkWell(
                      onTap: () => _activate(source, resolver: fileResolver),
                      child: text,
                    )
                  : text,
            ),
            if (missing)
              TextButton(
                onPressed: () =>
                    showWhiteboardLocations(context, widget.appState),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                  textStyle: Theme.of(context).textTheme.bodySmall,
                ),
                child: const Text('Not found · add location'),
              )
            else if (snapshot.hasData) ...[
              FileLocationButton(
                onReveal: () =>
                    _activate(source, reveal: true, resolver: fileResolver),
                onOpenExternal: () =>
                    _activate(source, external: true, resolver: fileResolver),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _markdown(String text, FileReferenceResolver resolver) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MarkdownBody(
      key: ObjectKey(resolver),
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: theme.textTheme.bodySmall?.copyWith(height: 1.6),
        h1: theme.textTheme.titleMedium,
        h2: theme.textTheme.titleSmall,
        h3: theme.textTheme.bodyMedium,
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: scheme.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        blockSpacing: 12,
      ),
      inlineSyntaxes: [_FileSyntax()],
      builders: {
        'a': _ReferenceBuilder(
          (label, source) => _reference(label, source, resolver: resolver),
        ),
        'code': _CodeReferenceBuilder(
          (label, source) => _reference(label, source, resolver: resolver),
        ),
      },
      onTapLink: (text, href, title) {
        if (href != null) _activate(href, resolver: resolver);
      },
      imageBuilder: (uri, title, alt) => _ResponseImage(
        source: uri.toString(),
        resolver: resolver,
        onTap: () => _activate(uri.toString(), resolver: resolver),
        fallback: _reference(
          alt?.isNotEmpty == true ? alt! : uri.toString(),
          uri.toString(),
          resolver: resolver,
        ),
        actions: FileLocationButton(
          onReveal: () =>
              _activate(uri.toString(), reveal: true, resolver: resolver),
          onOpenExternal: () =>
              _activate(uri.toString(), external: true, resolver: resolver),
        ),
      ),
    );
  }

  Widget _historyToggle() => PassiveTooltip(
    message: _moreResponses
        ? 'Show only the last response'
        : 'Load the last three completed responses',
    child: TextButton(
      key: const ValueKey('whiteboard-history-toggle'),
      onPressed: () {
        setState(() => _moreResponses = !_moreResponses);
        if (_moreResponses) unawaited(_loadHistory());
        if (_paneScroll.hasClients) _paneScroll.jumpTo(0);
      },
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 30),
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.bodySmall,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Last 3'),
          Icon(
            _moreResponses
                ? Icons.expand_less_rounded
                : Icons.expand_more_rounded,
            size: 16,
          ),
        ],
      ),
    ),
  );

  void _toggleLatest() {
    setState(() => _followLatest = !_followLatest);
    if (_followLatest && _recent.isNotEmpty) {
      if (_selected?.identityKey != _recent.first.identityKey) {
        _select(_recent.first, userInitiated: false);
      } else {
        unawaited(_loadHistory());
      }
    }
  }

  Widget _latestToggle({bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final icon = AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      child: Icon(
        _followLatest ? Icons.dynamic_feed_rounded : Icons.push_pin_outlined,
        key: ValueKey(_followLatest),
        size: 14,
      ),
    );
    return PassiveTooltip(
      message: _followLatest
          ? (_pushMode
                ? 'Following the newest published entry.'
                : 'Following the newest session. Click to keep this session.')
          : (_pushMode
                ? 'Keep this entry selected. Click to follow the newest.'
                : 'Keep this session selected. Click to follow the newest.'),
      child: compact
          ? IconButton(
              key: const ValueKey('whiteboard-follow-latest'),
              isSelected: _followLatest,
              onPressed: _toggleLatest,
              visualDensity: VisualDensity.compact,
              icon: icon,
              style: IconButton.styleFrom(
                foregroundColor: _followLatest
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
                backgroundColor: _followLatest
                    ? scheme.primary.withValues(alpha: 0.07)
                    : Colors.transparent,
              ),
            )
          : TextButton.icon(
              key: const ValueKey('whiteboard-follow-latest'),
              onPressed: _toggleLatest,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 30),
                visualDensity: VisualDensity.compact,
                foregroundColor: _followLatest
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
                backgroundColor: _followLatest
                    ? scheme.primary.withValues(alpha: 0.07)
                    : Colors.transparent,
                textStyle: Theme.of(context).textTheme.bodySmall,
              ),
              icon: icon,
              label: Text(_followLatest ? 'Latest' : 'Pinned'),
            ),
    );
  }

  Widget _answerHeader({SessionResponse? response, bool latest = true}) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Text(
              _pushMode
                  ? 'Published output'
                  : latest
                  ? 'Last response'
                  : 'Earlier response',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (latest) ...[
            _latestToggle(compact: constraints.maxWidth < 320),
            PassiveTooltip(
              message: 'Refresh this response',
              child: IconButton(
                key: const ValueKey('whiteboard-response-refresh'),
                onPressed: () => unawaited(_loadHistory()),
                visualDensity: VisualDensity.compact,
                icon: _responseBusy
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : const Icon(Icons.refresh_rounded, size: 17),
              ),
            ),
          ],
          if (response != null)
            _icon('Copy response', Icons.content_copy_rounded, () {
              unawaited(
                copyWithFeedback(context, response.text, 'Response copied'),
              );
            }),
          if (latest && !_pushMode) _historyToggle(),
        ],
      ),
    );
  }

  Widget _answer(SessionResponse response, int index) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('whiteboard-arrival-${response.turnId}'),
      tween: Tween(
        begin: MediaQuery.disableAnimationsOf(context) ? 1 : 0.45,
        end: 1,
      ),
      duration: const Duration(milliseconds: 180),
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: Padding(
        key: ValueKey('whiteboard-answer-${response.turnId}'),
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _answerHeader(response: response, latest: index == 0),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _markdown(response.text, _resolver!),
            ),
            if (_responseTime(response.timestamp).isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _responseTime(response.timestamp),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _responseTime(String timestamp) {
    final time = DateTime.tryParse(timestamp)?.toLocal();
    if (time == null) return '';
    return '${time.day}/${time.month} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _viewer() {
    if (_selected == null) return const SizedBox.shrink();
    final responses = _history?.responses ?? const <SessionResponse>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 2,
          child: _responseBusy
              ? const LinearProgressIndicator(minHeight: 2)
              : null,
        ),
        ...responses
            .take(_moreResponses ? 3 : 1)
            .indexed
            .toList()
            .reversed
            .map((entry) => _answer(entry.$2, entry.$1)),
        if (responses.isEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 0),
            child: _answerHeader(),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              _responseError ??
                  (_responseBusy
                      ? 'Reading last response...'
                      : _history?.bounded == true
                      ? 'No completed response in the recent log window.'
                      : 'No completed response found yet.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (_responseError != null && responses.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(_responseError!),
          ),
        if (_moreResponses && _history?.bounded == true && responses.length < 3)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'Only responses in the recent log window are available.',
            ),
          ),
      ],
    );
  }

  Widget _filePreview() => WhiteboardFilePreview(
    key: const ValueKey('whiteboard-file-preview'),
    embedded: true,
    controller: _previewController,
    markdownBuilder: _markdown,
    onClose: () {
      _previewController.close();
      setState(() => _preview = null);
    },
    onOpenExternal: () {
      final file = _previewController.path;
      if (file != null) unawaited(_activate(file, external: true));
    },
    onReveal: () {
      final file = _previewController.path;
      if (file != null) unawaited(_activate(file, reveal: true));
    },
  );

  Widget _sessions() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const ValueKey('whiteboard-recent-section'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_pushMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Row(
                  children: [
                    for (final provider in _reader.providers)
                      Expanded(
                        child: RecentProviderTab(
                          provider: provider,
                          count: _provider == provider ? _recent.length : 0,
                          selected: _provider == provider,
                          color: scheme.primary,
                          onTap: () {
                            if (_provider == provider) return;
                            setState(() {
                              _provider = provider;
                              _selected = null;
                              _history = null;
                              _preview = null;
                            });
                            _responseGeneration++;
                            _previewController.close();
                            unawaited(_refresh());
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          RecentSectionHeader(
            title: _pushMode ? 'Published entries' : 'Recent sessions',
            color: scheme.primary,
            subtitle: _recentBusy
                ? 'Refreshing...'
                : _recentError != null
                ? 'Refresh unavailable'
                : '${_recent.length} ${_pushMode ? 'published' : 'loaded'}',
            busy: _recentBusy,
            refreshTip: _pushMode
                ? 'Refresh whiteboard.md'
                : 'Refresh recent sessions',
            onRefresh: () => _refresh(),
            action: _pushMode
                ? null
                : PassiveTooltip(
                    message: _moreSessions
                        ? 'Show the three most recent sessions'
                        : 'Load up to ten recent sessions',
                    child: IconButton(
                      key: const ValueKey('whiteboard-recent-toggle'),
                      onPressed: () {
                        setState(() => _moreSessions = !_moreSessions);
                        unawaited(_refresh());
                      },
                      icon: Icon(
                        _moreSessions
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_recentError != null || _recent.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest.withValues(
                        alpha: 0.42,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _recentError ??
                          (_recentBusy
                              ? (_pushMode
                                    ? 'Reading whiteboard.md...'
                                    : 'Reading recent sessions...')
                              : _path.isEmpty
                              ? 'Choose a sessions markdown file in Settings.'
                              : _pushMode
                              ? 'No published entries yet. Ask an agent: wb.md'
                              : 'No recent sessions found.'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final session in _recent.take(_moreSessions ? 10 : 3))
                  RecentSessionCard(
                    key: ValueKey('whiteboard-session-${session.id}'),
                    session: session,
                    badgeLabel: _pushMode ? 'WB' : null,
                    title: _title(session),
                    color: scheme.primary,
                    selected: _selected?.identityKey == session.identityKey,
                    tip: _pushMode
                        ? 'Click to view this published output'
                        : 'Click card to view the last response',
                    onTap: () => _select(session),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Scrollbar(
      controller: _paneScroll,
      child: SingleChildScrollView(
        key: const ValueKey('whiteboard-scroll'),
        controller: _paneScroll,
        primary: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_preview != null)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: constraints.maxWidth),
                  child: _filePreview(),
                ),
              _viewer(),
              Divider(
                height: 1,
                thickness: 0.7,
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.65),
              ),
              _sessions(),
            ],
          ),
        ),
      ),
    ),
  );
}

class _FileSyntax extends md.InlineSyntax {
  _FileSyntax() : super(fileReferencePattern.pattern, caseSensitive: false);
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final source = match[0]!.replaceFirst(RegExp(r'[.,;!?\)\]]+$'), '');
    parser.addNode(
      md.Element('a', [md.Text(source)])..attributes['href'] = source,
    );
    final remainder = match[0]!.substring(source.length);
    if (remainder.isNotEmpty) parser.addNode(md.Text(remainder));
    return true;
  }
}

class _ReferenceBuilder extends MarkdownElementBuilder {
  _ReferenceBuilder(this.buildReference);
  final Widget Function(String, String) buildReference;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final href = element.attributes['href'];
    if (href == null) return null;
    return buildReference(element.textContent, href);
  }
}

class _CodeReferenceBuilder extends MarkdownElementBuilder {
  _CodeReferenceBuilder(this.buildReference);
  final Widget Function(String, String) buildReference;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    if (!fileReferencePattern.hasMatch(text)) return null;
    if (!text.contains('\n') &&
        !text.contains('=') &&
        RegExp(r'\.[a-zA-Z0-9]{1,8}(?::\d+(?::\d+)?|#L\d+)?$').hasMatch(text) &&
        !RegExp(
          r'^(?:cd|cat|ls|rg|python|cargo|git|npm|echo)\s',
        ).hasMatch(text)) {
      return buildReference(text, text);
    }
    final widgets = <Widget>[];
    var offset = 0;
    for (final match in fileReferencePattern.allMatches(text)) {
      if (match.start > offset) {
        widgets.add(
          Text(text.substring(offset, match.start), style: preferredStyle),
        );
      }
      widgets.add(buildReference(match[0]!, match[0]!));
      offset = match.end;
    }
    if (offset < text.length) {
      widgets.add(Text(text.substring(offset), style: preferredStyle));
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: widgets,
    );
  }
}

class _ResponseImage extends StatelessWidget {
  const _ResponseImage({
    required this.source,
    required this.resolver,
    required this.onTap,
    required this.fallback,
    required this.actions,
  });
  final String source;
  final FileReferenceResolver resolver;
  final VoidCallback onTap;
  final Widget fallback;
  final Widget actions;
  @override
  Widget build(BuildContext context) => FutureBuilder<ResolvedReference>(
    future: resolver.resolve(source),
    builder: (context, snapshot) {
      final paths = snapshot.data?.paths ?? const <String>[];
      if (paths.length != 1 || !isPreviewImage(paths.first)) return fallback;
      return LayoutBuilder(
        builder: (context, constraints) => Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                key: const ValueKey('whiteboard-response-thumbnail'),
                constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(paths.first),
                    height: 90,
                    fit: BoxFit.contain,
                    cacheWidth: 400,
                    errorBuilder: (_, _, _) => fallback,
                  ),
                ),
              ),
            ),
            actions,
          ],
        ),
      );
    },
  );
}

Future<void> showWhiteboardLocations(
  BuildContext context,
  AppState state,
) async {
  final controller = TextEditingController(
    text: state.effectiveWhiteboardRoots.join('\n'),
  );
  try {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('File search locations'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'One folder per line. The session working directory is checked first; these folders are fallbacks. No recursive searching.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Folders',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      state.setWhiteboardSearchRoots(controller.text.split('\n'));
    }
  } finally {
    controller.dispose();
  }
}
