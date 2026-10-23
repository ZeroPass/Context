import 'dart:convert';

import 'package:context/app/app_state.dart';
import 'package:context/app/models.dart';
import 'package:context/app/session_terminal.dart';
import 'package:context/app/terminal_profiles.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('group restore targets a validated named window', () {
    List<String> args(String window) => terminalSessionArguments(
      provider: SessionProvider.codex,
      sessionId: 'test-id',
      title: 'Work',
      markdownPath: r'\\wsl.localhost\Ubuntu-24.04\home\test\sessions.md',
      window: window,
    );
    expect(args('context-g123_1').take(3), ['-w', 'context-g123_1', 'new-tab']);
    expect(() => args('context-name;nt'), throwsArgumentError);
    expect(() => args('context-'), throwsArgumentError);
    expect(() => args('unrelated-window'), throwsArgumentError);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  const markdown =
      r'\\wsl.localhost\Ubuntu-24.04\home\luka\codex-out\Context\codex sessions.md';
  List<String> plan({
    SessionProvider provider = SessionProvider.codex,
    String id = 'session-1234',
    String path = markdown,
    String? directory,
    String title = 'My session',
  }) => terminalSessionArguments(
    provider: provider,
    sessionId: id,
    title: title,
    markdownPath: path,
    workDir: directory,
  );

  const ubuntuProfile = '{12345678-1234-1234-1234-123456789abc}';
  const otherProfile = '{11111111-1111-1111-1111-111111111111}';
  Map<String, Object> profile(String id, String name, {String? command}) => {
    'guid': id,
    'name': name,
    if (command != null)
      'commandline': command
    else
      'source': 'Windows.Terminal.Wsl',
  };
  String settings(List<Map<String, Object>> profiles, {String? defaultId}) =>
      jsonEncode({
        'defaultProfile': defaultId,
        'profiles': {'list': profiles},
      });

  test('matching Ubuntu profile is explicit even when CMD is the default', () {
    final text = settings([
      {'guid': otherProfile, 'name': 'Command Prompt'},
      {
        'guid': ubuntuProfile,
        'name': 'Ubuntu 24.04.1 LTS',
        'source': 'CanonicalGroupLimited.Ubuntu24.04LTS_79rhkp1fndgsc',
        'icon': 'ubuntu-round.png',
      },
    ], defaultId: otherProfile);
    expect(
      windowsTerminalProfile(text, distribution: 'Ubuntu-24.04'),
      ubuntuProfile,
    );
  });

  test('renamed profiles match their explicit WSL distribution', () {
    final text = settings([
      profile(otherProfile, 'Debian', command: 'wsl.exe -d Debian'),
      profile(
        ubuntuProfile,
        'My workspace',
        command: r'C:\Windows\System32\wsl.exe --distribution "Ubuntu-24.04"',
      ),
    ], defaultId: otherProfile);
    expect(
      windowsTerminalProfile(text, distribution: 'Ubuntu-24.04'),
      ubuntuProfile,
    );
    expect(windowsTerminalProfile(text, distribution: 'Debian'), otherProfile);
  });

  test(
    'hidden and unrelated profiles never replace the matching visible profile',
    () {
      final text = settings([
        {...profile(otherProfile, 'Ubuntu-24.04'), 'hidden': true},
        profile(ubuntuProfile, 'Ubuntu-24.04'),
      ], defaultId: otherProfile);
      expect(
        windowsTerminalProfile(text, distribution: 'Ubuntu-24.04'),
        ubuntuProfile,
      );
    },
  );

  test('no requested distribution prefers the configured WSL default', () {
    final text = settings([
      profile(otherProfile, 'Debian'),
      profile(ubuntuProfile, 'Ubuntu'),
    ], defaultId: ubuntuProfile);
    expect(windowsTerminalProfile(text), ubuntuProfile);
  });

  test(
    'JSONC comments, BOM, escaped paths and trailing commas are supported',
    () {
      final text =
          '\ufeff'
          r'''
    {
      // "defaultProfile": "{11111111-1111-1111-1111-111111111111}",
      "profiles": {"list": [
        /* a comment, not a profile */
        {"guid": "{12345678-1234-1234-1234-123456789abc}",
         "name": "Ubuntu-24.04",
         "commandline": "C:\\Windows\\System32\\wsl.exe -d Ubuntu-24.04",
         "icon": "https://example.invalid/icon.png?literal=,}",
        },
      ],},
    }
    ''';
      expect(
        windowsTerminalProfile(text, distribution: 'Ubuntu-24.04'),
        ubuntuProfile,
      );
    },
  );

  test('missing Linux profile and invalid/oversized settings fail clearly', () {
    expect(
      () => windowsTerminalProfile(
        settings([
          {'guid': otherProfile, 'name': 'Command Prompt'},
        ]),
        distribution: 'Ubuntu-24.04',
      ),
      throwsStateError,
    );
    for (final text in [
      '[]',
      '{"profiles":{}}',
      '/* unclosed',
      List.filled(1024 * 1024 + 1, ' ').join(),
    ]) {
      expect(() => windowsTerminalProfile(text), throwsFormatException);
    }
    expect(
      () => windowsTerminalProfile(
        settings(List.filled(513, profile(ubuntuProfile, 'Ubuntu'))),
      ),
      throwsFormatException,
    );
  });

  test(
    'WSL UNC is translated into separate distro and Linux cwd arguments',
    () {
      expect(plan(), [
        '-w',
        '0',
        'new-tab',
        '--title',
        'My session',
        'wsl.exe',
        '-d',
        'Ubuntu-24.04',
        '--cd',
        '/home/luka/codex-out',
        '--exec',
        'bash',
        '-lic',
        r'exec "$@"',
        'context-session',
        'codex',
        'resume',
        'session-1234',
      ]);
    },
  );

  test('real session cwd overrides the markdown fallback', () {
    final args = plan(directory: '/home/luka/a project');
    expect(args[args.indexOf('--cd') + 1], '/home/luka/a project');
    expect(args[args.indexOf('-d') + 1], 'Ubuntu-24.04');
    final other = plan(directory: r'\\wsl$\Debian\home\user\work');
    expect(other[other.indexOf('-d') + 1], 'Debian');
    expect(other[other.indexOf('--cd') + 1], '/home/user/work');
  });

  test('provider commands and special characters are passed as argv', () {
    final expected = {
      SessionProvider.codex: ['codex', 'resume'],
      SessionProvider.kimi: ['kimi', '--session'],
      SessionProvider.opencode: ['opencode', '--session'],
      SessionProvider.qwen: ['qwen', '--resume'],
      SessionProvider.muse: ['muse', 'resume'],
    };
    for (final entry in expected.entries) {
      final args = plan(
        provider: entry.key,
        title: 'a "quoted"; title\nnext',
        directory: '/home/user/a "quoted"; project',
      );
      expect(args[4], 'a "quoted"; title next');
      expect(args[args.indexOf('--cd') + 1], '/home/user/a "quoted"; project');
      expect(args.sublist(args.indexOf('context-session') + 1), [
        ...entry.value,
        'session-1234',
        if (entry.key == SessionProvider.muse) '--yolo',
      ]);
    }
  });

  test('Windows folders still open Ubuntu using their mounted Linux paths', () {
    final args = plan(directory: r"C:\user's files\project;literal");
    expect(args, contains('wsl.exe'));
    expect(args, isNot(contains('powershell.exe')));
    expect(
      args[args.indexOf('--cd') + 1],
      "/mnt/c/user's files/project;literal",
    );
    expect(args[args.indexOf('-d') + 1], 'Ubuntu-24.04');
    final local = plan(path: r'C:\Context\sessions.md');
    expect(local, contains('wsl.exe'));
    expect(local[local.indexOf('--cd') + 1], '/mnt/c/Context');
  });

  test('invalid IDs, missing cwd, and unsupported providers fail closed', () {
    for (final id in ['--help', 'a; echo bad', 'bad\nid', '', r'$(id)']) {
      expect(() => plan(id: id), throwsArgumentError);
    }
    expect(() => plan(path: ''), throwsArgumentError);
    expect(() => plan(directory: 'relative'), throwsArgumentError);
    expect(() => plan(directory: r'\\server\share'), throwsArgumentError);
    expect(() => plan(directory: '/home/user/\nbad'), throwsArgumentError);
    expect(canOpenSessionInTerminal(SessionProvider.zcode), isFalse);
    expect(() => plan(provider: SessionProvider.zcode), throwsArgumentError);
  });

  test('native channel requests and cancellation errors are preserved', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(sessionTerminalChannel, (call) async {
      calls.add(call);
      if (call.method == 'isElevated') return true;
      if (call.method == 'readSettings') {
        return '{"profiles":{"list":[{"guid":"{12345678-1234-1234-1234-123456789abc}",'
            '"name":"Ubuntu-24.04","source":"Windows.Terminal.Wsl"}]}}';
      }
      if (call.method == 'restartElevated') {
        throw PlatformException(
          code: 'cancelled',
          message: 'Approval cancelled',
        );
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(sessionTerminalChannel, null),
    );
    const terminal = SessionTerminal();
    expect(await terminal.isElevated(), isTrue);
    await terminal.open(plan());
    expect(calls.last.method, 'openTab');
    expect(calls.last.arguments, [
      ...plan().take(3),
      '--profile',
      '{12345678-1234-1234-1234-123456789abc}',
      ...plan().skip(3),
    ]);
    await expectLater(
      terminal.restartElevated(),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
  });

  test(
    'terminal mode is opt-in and persists independently of session data',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final state = AppState.forTesting(
        sendRequest: (_) {},
        preferences: prefs,
      );
      expect(state.openSessionsInTerminal, isFalse);
      await state.setOpenSessionsInTerminal(true);
      final next = AppState.forTesting(sendRequest: (_) {}, preferences: prefs);
      expect(next.openSessionsInTerminal, isTrue);
      await next.setOpenSessionsInTerminal(false);
      expect(prefs.getBool('openSessionsInTerminal'), isFalse);
      expect(next.dirty, isFalse);
      state.dispose();
      next.dispose();
    },
  );

  test(
    'missing Ubuntu profile never launches a generic Terminal tab',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(sessionTerminalChannel, (call) async {
        calls.add(call);
        return call.method == 'readSettings'
            ? settings([
                {'guid': otherProfile, 'name': 'Command Prompt'},
              ])
            : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(sessionTerminalChannel, null),
      );
      await expectLater(const SessionTerminal().open(plan()), throwsStateError);
      expect(calls.where((call) => call.method == 'openTab'), isEmpty);
    },
  );
}
