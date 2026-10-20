import 'package:context/app/wsl_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'batches and caches WSL paths, preserving distro and shell characters',
    () async {
      final requests = <(String, List<String>)>[];
      final resolver = WslPathResolver(
        lookup: (distro, paths) async {
          requests.add((distro, paths));
          return {for (final path in paths) path: '/mnt/c$path'};
        },
      );
      final paths = [
        r'\\wsl.localhost\Ubuntu-24.04\home\tester\clip.mp4',
        r"\\wsl.localhost\Ubuntu-24.04\home\tester\clip ' $(literal).mp4",
      ];
      final targets = await Future.wait(paths.map(resolver.resolve));
      expect(targets, [
        '/mnt/c/home/tester/clip.mp4',
        "/mnt/c/home/tester/clip ' \$(literal).mp4",
      ]);
      await resolver.resolve(paths.first);
      await resolver.resolve(paths.first.replaceAll('\\', '/'));
      expect(requests, hasLength(1));
      expect(requests.single.$1, 'Ubuntu-24.04');
      expect(requests.single.$2, hasLength(2));
    },
  );

  test('bounds batches and rejects non-WSL or oversized paths', () async {
    final batches = <List<String>>[];
    final resolver = WslPathResolver(
      lookup: (_, paths) async {
        batches.add(paths);
        return {};
      },
    );
    expect(await resolver.resolve(r'C:\clip.mp4'), isNull);
    expect(await resolver.resolve(r'\\server\share\clip.mp4'), isNull);
    expect(
      await resolver.resolve('\\\\wsl.localhost\\Ubuntu\\${'a' * 4097}'),
      isNull,
    );
    await Future.wait(
      List.generate(
        35,
        (n) => resolver.resolve('\\\\wsl.localhost\\Ubuntu\\home\\clip$n.mp4'),
      ),
    );
    expect(batches.map((batch) => batch.length), [16, 16, 3]);
  });

  test(
    'lookup failure does not block other distros or claim a target',
    () async {
      final resolver = WslPathResolver(
        lookup: (distro, paths) async {
          if (distro == 'Broken') throw StateError('Unavailable');
          return {paths.single: '/mnt/d/clip.mp4'};
        },
      );
      expect(
        await Future.wait([
          resolver.resolve(r'\\wsl.localhost\Broken\clip.mp4'),
          resolver.resolve(r'\\wsl$\Working\clip.mp4'),
        ]),
        [null, '/mnt/d/clip.mp4'],
      );
    },
  );
}
