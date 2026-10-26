import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/whiteboard.dart';
import 'package:context/app/whiteboard_file.dart';
import 'package:context/app/whiteboard_publications.dart';
import 'package:context/ui/widgets/whiteboard_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RecentContext post(String id, {String? title}) => RecentContext(
  provider: SessionProvider.codex,
  id: id,
  title: title ?? id,
  updatedAt: 1,
);

class PublicationReader extends FileWhiteboardReader {
  final events = StreamController<void>.broadcast();
  List<RecentContext> posts = [post('old')];
  Completer<List<RecentContext>>? pending;
  bool fail = false;
  bool closed = false;
  int reads = 0;
  int watches = 0;
  int? lastLimit;

  @override
  Stream<void> changes(String markdownPath) {
    watches++;
    return events.stream;
  }

  @override
  Future<List<RecentContext>> recent(
    String path,
    SessionProvider provider,
    int limit,
  ) async {
    reads++;
    lastLimit = limit;
    if (fail) throw const FileSystemException('fixture unavailable');
    return pending?.future ?? posts.take(limit).toList();
  }

  @override
  Future<ResponseHistory> history(
    String path,
    RecentContext session,
    int limit,
  ) async => ResponseHistory(
    [
      SessionResponse(
        text: 'Body ${session.id}',
        timestamp: '',
        turnId: session.id,
      ),
    ],
    null,
    false,
  );

  @override
  void dispose() {
    closed = true;
    unawaited(events.close());
    super.dispose();
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

String framed(String id) {
  final body = 'Body $id';
  final metadata = jsonEncode({
    'id': id,
    'title': 'Title $id',
    'provider': 'codex',
    'cwd': '/work',
    'published_at_ms': 1,
    'body_chars': body.length,
  });
  return '<!-- context:whiteboard:entry $metadata -->\n$body\n'
      '<!-- context:whiteboard:end $id -->\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'publication monitor requests and delivers all six retained slots',
    () async {
      final reader = PublicationReader();
      final delivered = <String>[];
      final monitor = WhiteboardPublications(
        reader: reader,
        notify: (item) async => delivered.add(item.id),
      );
      addTearDown(monitor.dispose);
      monitor.follow('/work/sessions.md');
      await settle();
      reader.posts = List.generate(6, (i) => post('new-$i'));
      reader.events.add(null);
      await settle();
      expect(reader.lastLimit, whiteboardSlotCount);
      expect(delivered, ['new-5', 'new-4', 'new-3', 'new-2', 'new-1', 'new-0']);
    },
  );

  test(
    'local drops are silent while adjacent agent outputs still notify',
    () async {
      final reader = PublicationReader();
      final delivered = <String>[];
      final monitor = WhiteboardPublications(
        reader: reader,
        notify: (item) async => delivered.add(item.id),
      );
      addTearDown(monitor.dispose);
      monitor.follow('/work/sessions.md');
      await settle();
      reader.posts = [
        post('answer'),
        const RecentContext(
          provider: SessionProvider.codex,
          id: 'drop',
          title: 'Image',
          updatedAt: 2,
          localDrop: true,
          agentPrompt: 'Read `/drop/README.md`.',
        ),
        post('old'),
      ];
      reader.events.add(null);
      await settle();
      expect(delivered, ['answer']);
    },
  );

  test(
    'startup is silent; new IDs notify once, independent of timestamp',
    () async {
      final reader = PublicationReader();
      final delivered = <String>[];
      final monitor = WhiteboardPublications(
        reader: reader,
        notify: (item) async => delivered.add(item.id),
      );
      addTearDown(monitor.dispose);
      monitor.follow('/work/sessions.md');
      await settle();
      expect(delivered, isEmpty);
      reader.posts = [post('new'), post('old')];
      reader.events.add(null);
      await settle();
      expect(delivered, ['new']);
      reader.posts = [post('new', title: 'Renamed'), post('old')];
      reader.events.add(null);
      await settle();
      reader.posts = [];
      reader.events.add(null);
      await settle();
      reader.posts = [post('new'), post('old')];
      reader.events.add(null);
      await settle();
      expect(delivered, ['new']);
      expect(reader.watches, 1);
    },
  );

  test(
    'disabled notifications advance baseline without replaying alerts',
    () async {
      final reader = PublicationReader();
      final delivered = <String>[];
      final monitor = WhiteboardPublications(
        reader: reader,
        notify: (item) async => delivered.add(item.id),
      );
      addTearDown(monitor.dispose);
      monitor.follow('/work/sessions.md');
      await settle();
      monitor.notificationsEnabled = false;
      reader.posts = [post('muted'), post('old')];
      reader.events.add(null);
      await settle();
      monitor.notificationsEnabled = true;
      reader.events.add(null);
      await settle();
      expect(delivered, isEmpty);
      reader.posts = [post('next'), post('muted'), post('old')];
      reader.events.add(null);
      await settle();
      expect(delivered, ['next']);
    },
  );

  test(
    'path changes discard stale inflight results and baseline the new board',
    () async {
      final reader = PublicationReader();
      final delivered = <String>[];
      final monitor = WhiteboardPublications(
        reader: reader,
        notify: (item) async => delivered.add(item.id),
      );
      addTearDown(monitor.dispose);
      monitor.follow('/one/sessions.md');
      await settle();
      final pending = reader.pending = Completer<List<RecentContext>>();
      reader.events.add(null);
      await settle();
      reader.pending = null;
      reader.posts = [post('other-old')];
      monitor.follow('/two/sessions.md');
      await settle();
      pending.complete([post('stale-new')]);
      await settle();
      expect(delivered, isEmpty);
      reader.posts = [post('other-new'), post('other-old')];
      reader.events.add(null);
      await settle();
      expect(delivered, ['other-new']);
    },
  );

  test('event bursts coalesce while a read is pending', () async {
    final reader = PublicationReader();
    final delivered = <String>[];
    final monitor = WhiteboardPublications(
      reader: reader,
      notify: (item) async => delivered.add(item.id),
    );
    addTearDown(monitor.dispose);
    monitor.follow('/work/sessions.md');
    await settle();
    final pending = reader.pending = Completer<List<RecentContext>>();
    for (var i = 0; i < 50; i++) {
      reader.events.add(null);
    }
    await settle();
    expect(reader.reads, 2);
    reader.pending = null;
    reader.posts = [post('new')];
    pending.complete([post('new')]);
    await settle();
    expect(reader.reads, 3);
    expect(delivered, ['new']);
  });

  test(
    'read failures recover silently; disposal cancels the watcher',
    () async {
      final reader = PublicationReader()..fail = true;
      final delivered = <String>[];
      final monitor = WhiteboardPublications(
        reader: reader,
        notify: (item) async => delivered.add(item.id),
      );
      monitor.follow('/work/sessions.md');
      await settle();
      reader.fail = false;
      reader.events.add(null);
      await settle();
      expect(delivered, isEmpty);
      reader.fail = true;
      reader.events.add(null);
      await settle();
      reader.fail = false;
      reader.posts = [post('new')];
      reader.events.add(null);
      await settle();
      expect(delivered, ['new']);
      monitor.dispose();
      await settle();
      expect(reader.closed, isTrue);
      expect(reader.events.hasListener, isFalse);
    },
  );

  testWidgets('idle monitor has no timer; notification preference persists', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final reader = PublicationReader();
    final monitor = WhiteboardPublications(
      reader: reader,
      notify: (_) async {},
    );
    final state = AppState.forTesting(
      sendRequest: (_) {},
      preferences: prefs,
      publications: monitor,
    );
    monitor.follow('/work/sessions.md');
    await tester.pump();
    expect(reader.reads, 1);
    await tester.pump(const Duration(hours: 1));
    expect(reader.reads, 1);
    state.setWhiteboardNotificationsEnabled(false);
    expect(monitor.notificationsEnabled, isFalse);
    expect(prefs.getBool('whiteboardNotificationsEnabled'), isFalse);
    state.dispose();
    await tester.pump();
  });

  testWidgets('pane shares the monitor watch; hidden pane still notifies', (
    tester,
  ) async {
    final reader = PublicationReader();
    final delivered = <String>[];
    final monitor = WhiteboardPublications(
      reader: reader,
      notify: (item) async => delivered.add(item.id),
    )..follow('/work/sessions.md');
    final state = AppState.forTesting(
      sendRequest: (_) {},
      publications: monitor,
    )..sessionsMarkdownPath = '/work/sessions.md';
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WhiteboardPane(appState: state)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(reader.watches, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(reader.closed, isFalse);
    state.didChangeAppLifecycleState(AppLifecycleState.hidden);
    reader.posts = [post('background')];
    reader.events.add(null);
    await tester.pump();
    expect(delivered, ['background']);
    state.dispose();
    await tester.pump();
    expect(reader.closed, isTrue);
  });

  test(
    'native channel sends bounded metadata, never the answer body',
    () async {
      if (!Platform.isWindows) return;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(whiteboardNotificationChannel, (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(whiteboardNotificationChannel, null),
      );
      await notifyWhiteboardPublication(post('id', title: 'Title <&>'));
      expect(calls.single.method, 'whiteboardPublished');
      expect(calls.single.arguments, {
        'title': 'Title <&>',
        'provider': 'Codex',
      });
      await notifyWhiteboardPublication(
        post('long', title: List.filled(400, 'x').join()),
      );
      expect((calls.last.arguments['title'] as String).length, 200);
    },
  );

  test(
    'atomic publish notifies; partial frames and startup stay silent',
    () async {
      final root = await Directory.systemTemp.createTemp('context-notify-');
      final board = File('${root.path}/whiteboard.md');
      await board.writeAsString(framed('old'));
      final delivered = <String>[];
      final monitor = WhiteboardPublications(
        notify: (item) async => delivered.add(item.id),
      );
      final baseline = monitor.changes.first;
      monitor.follow('${root.path}/sessions.md');
      await baseline.timeout(const Duration(seconds: 5));
      expect(delivered, isEmpty);
      Future<void> replace(String text) async {
        final changed = monitor.changes.first;
        final temp = File('${root.path}/.whiteboard.next.tmp');
        await temp.writeAsString(text);
        await temp.rename(board.path);
        await changed.timeout(const Duration(seconds: 5));
      }

      try {
        await replace(
          '${framed('old')}<!-- context:whiteboard:entry incomplete -->',
        );
        expect(delivered, isEmpty);
        await replace(framed('old') + framed('new'));
        expect(delivered, ['new']);
        await replace(framed('old') + framed('new'));
        expect(delivered, ['new']);
      } finally {
        monitor.dispose();
        await settle();
        await root.delete(recursive: true);
      }
    },
  );
}
