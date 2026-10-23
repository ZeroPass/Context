import 'dart:convert';

// Windows Terminal accepts JSON comments and trailing commas.
Object? _decodeSettings(String source) {
  final clean = StringBuffer();
  var quoted = false;
  var escaped = false;
  for (var i = source.startsWith('\ufeff') ? 1 : 0; i < source.length; i++) {
    final c = source[i];
    if (quoted) {
      clean.write(c);
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
      clean.write(c);
    } else if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      while (i + 1 < source.length && source[i + 1] != '\n') {
        i++;
      }
      clean.write(' ');
    } else if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final end = source.indexOf('*/', i + 2);
      if (end < 0) throw const FormatException('Unclosed settings comment.');
      i = end + 1;
      clean.write(' ');
    } else {
      clean.write(c);
    }
  }
  final text = clean.toString();
  final json = StringBuffer();
  quoted = false;
  escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (!quoted && c == ',') {
      var next = i + 1;
      while (next < text.length && text[next].trim().isEmpty) {
        next++;
      }
      if (next < text.length && (text[next] == ']' || text[next] == '}')) {
        continue;
      }
    }
    json.write(c);
    if (escaped) {
      escaped = false;
    } else if (quoted && c == r'\') {
      escaped = true;
    } else if (c == '"') {
      quoted = !quoted;
    }
  }
  return jsonDecode(json.toString());
}

String windowsTerminalProfile(String settings, {String? distribution}) {
  if (settings.length > 1024 * 1024) {
    throw const FormatException('Windows Terminal settings are too large.');
  }
  final root = _decodeSettings(settings);
  if (root is! Map) throw const FormatException('Invalid Terminal settings.');
  final profiles = root['profiles'];
  final list = profiles is Map ? profiles['list'] : profiles;
  if (list is! List || list.length > 512) {
    throw const FormatException('Invalid Terminal profile list.');
  }
  String normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  final distro = normalize(distribution ?? '');
  final candidates = <({String id, int score})>[];
  for (final profile in list.whereType<Map>()) {
    final id = profile['guid']?.toString() ?? '';
    if (profile['hidden'] == true ||
        !RegExp(
          r'^\{[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}\}$',
        ).hasMatch(id)) {
      continue;
    }
    final name = normalize(profile['name']?.toString() ?? '');
    final source = normalize(profile['source']?.toString() ?? '');
    final command = profile['commandline']?.toString() ?? '';
    final wsl = RegExp(
      r'\bwsl(?:\.exe)?\b',
      caseSensitive: false,
    ).hasMatch(command);
    if (!wsl &&
        !source.contains('ubuntu') &&
        source != 'windowsterminalwsl' &&
        !name.startsWith('ubuntu')) {
      continue;
    }
    final target = RegExp(
      r'''(?:^|\s)(?:-d|--distribution)(?:\s+|=)(?:"([^"]+)"|([^\s"]+))''',
      caseSensitive: false,
    ).firstMatch(command);
    final explicit = normalize(target?.group(1) ?? target?.group(2) ?? '');
    if (distro.isNotEmpty && explicit.isNotEmpty && explicit != distro) {
      continue;
    }
    var score = distro.isEmpty ? 1 : 0;
    if (distro.isNotEmpty) {
      if (explicit == distro || name == distro) {
        score = 100;
      } else if (name.startsWith(distro) || source.contains(distro)) {
        score = 80;
      } else if (name == 'wsl' ||
          (wsl &&
              explicit.isEmpty &&
              source.isEmpty &&
              !name.startsWith('ubuntu'))) {
        score = 10;
      } else if (distro.startsWith('ubuntu') && name == 'ubuntu') {
        score = 20;
      }
    }
    if (score == 0) continue;
    if (id.toLowerCase() == root['defaultProfile']?.toString().toLowerCase()) {
      score++;
    }
    candidates.add((id: id, score: score));
  }
  if (candidates.isEmpty) {
    throw StateError(
      'No matching Ubuntu/WSL profile in Windows Terminal. '
      'Add ${distribution ?? 'your Linux distribution'} to Terminal profiles.',
    );
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  return candidates.first.id;
}
