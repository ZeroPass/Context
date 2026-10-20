import 'package:context/app/file_references.dart';
import 'package:context/app/preview_gallery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'literal percentages and malformed escapes do not break path cleanup',
    () {
      for (final text in [
        'mean/94.92%worst',
        '96.78%/90.97%',
        '/reports/100%complete.png',
        '/reports/%FF.png',
        '/reports/%C3.png',
        'file:///reports/notes.md?unsupported-query',
      ]) {
        expect(FileReferenceResolver.clean(text), text);
      }
      expect(
        FileReferenceResolver.clean('/report%20dir/100%done/plot%20one.png:3'),
        '/report dir/100%done/plot one.png',
      );
      expect(
        FileReferenceResolver.clean('plots/%E2%82%AC%20gain.png'),
        'plots/\u20ac gain.png',
      );
    },
  );

  test(
    'numeric prose stays distinct from actual or explicitly linked paths',
    () {
      for (final text in [
        '0/106main',
        'have0/106main',
        'and0/106support',
        '113/74317',
        'mean/94.92%worst',
        '/90.97%',
      ]) {
        expect(isProseRatio(text), isTrue);
      }
      for (final text in [
        'images/50%.png',
        'images/100%done/plot.png',
        '2026/plot.md',
      ]) {
        expect(isProseRatio(text), isFalse);
      }
      expect(
        previewReferences(
          '97.54%mean/94.92%worst\n\n![Plot](images/50%25.png)',
        ),
        ['images/50%.png'],
      );
    },
  );
  test(
    'attachments follow document order and deduplicate links/thumbnails',
    () {
      expect(
        previewReferences('''
[first](<photos/one image.png>)
![one again](<photos/one image.png>)
[movie](clips/demo.mp4)
`notes/report.md:12`
photos/last.jpg.
![remote](https://example.com/remote.png)
[website](https://example.com)
[not previewable](notes/data.csv)
[reference][sheet]

[sheet]: photos/referenced.webp
'''),
        [
          'photos/one image.png',
          'clips/demo.mp4',
          'notes/report.md',
          'photos/last.jpg',
          'photos/referenced.webp',
        ],
      );
    },
  );

  test(
    'inline paths with spaces and encoded aliases resolve to one file',
    () async {
      final checks = <String>[];
      final resolver = FileReferenceResolver(
        markdownPath: '/workspace/board.md',
        roots: const ['/fallback'],
        workDir: '/workspace',
        windows: false,
        exists: (path) async {
          checks.add(path);
          return path == '/workspace/one image.png' ||
              path == '/workspace/clip.mp4';
        },
      );
      expect(
        await resolvePreviewGallery('''
`one image.png`
![encoded](one%20image.png)
[missing](missing.md)
[video](clip.mp4)
''', resolver),
        ['/workspace/one image.png', '/workspace/clip.mp4'],
      );
      expect(checks, isNot(contains('/fallback/clip.mp4')));
    },
  );

  test(
    'ambiguous and inaccessible paths do not block other attachments',
    () async {
      final resolver = FileReferenceResolver(
        markdownPath: '/board.md',
        roots: const ['/a', '/b'],
        windows: false,
        exists: (path) async {
          if (path.endsWith('broken.png')) throw StateError('Access denied');
          return path.endsWith('ambiguous.md') || path == '/a/ok.mp4';
        },
      );
      expect(
        await resolvePreviewGallery(
          '[ambiguous](ambiguous.md) [broken](broken.png) [ok](ok.mp4)',
          resolver,
        ),
        ['/a/ok.mp4'],
      );
    },
  );

  test('gallery resolution has a fixed per-document attachment bound', () {
    expect(
      previewReferences(List.generate(200, (i) => '[item]($i.png)').join('\n')),
      hasLength(128),
    );
  });
}
