enum ConfigItemKind { group, session, groupEnd }

enum SessionProvider { codex, kimi }

extension SessionProviderInfo on SessionProvider {
  String get key => name;

  String get label => switch (this) {
    SessionProvider.codex => 'Codex',
    SessionProvider.kimi => 'Kimi',
  };

  static SessionProvider parse(Object? value) {
    final normalized = (value ?? '').toString().trim().toLowerCase();
    return normalized == SessionProvider.kimi.name
        ? SessionProvider.kimi
        : SessionProvider.codex;
  }
}

class RecentContext {
  const RecentContext({
    required this.provider,
    required this.id,
    required this.title,
    required this.updatedAt,
    this.forkedFromId,
    this.workDir,
  });

  factory RecentContext.fromJson(Map<String, dynamic> json) {
    return RecentContext(
      provider: SessionProviderInfo.parse(json['provider']),
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      forkedFromId: (json['forked_from_id'] ?? '').toString().trim().isEmpty
          ? null
          : (json['forked_from_id'] ?? '').toString().trim(),
      workDir: (json['work_dir'] ?? '').toString().trim().isEmpty
          ? null
          : (json['work_dir'] ?? '').toString().trim(),
    );
  }

  final SessionProvider provider;
  final String id;
  final String title;
  final int updatedAt;
  final String? forkedFromId;
  final String? workDir;

  String get identityKey => '${provider.key}:${id.trim().toLowerCase()}';

  String get shortId => _shortSessionId(id);

  String get displayTitle => title.trim().isEmpty ? shortId : title.trim();

  bool get isForked => forkedFromId?.trim().isNotEmpty == true;
}

class ConfigItem {
  const ConfigItem({
    required this.kind,
    required this.id,
    required this.name,
    required this.commandId,
    required this.colorHex,
    required this.provider,
    required this.fast,
  });

  factory ConfigItem.fromJson(Map<String, dynamic> json) {
    final kindText = (json['kind'] ?? '').toString().trim().toLowerCase();
    return ConfigItem(
      kind: switch (kindText) {
        'group' => ConfigItemKind.group,
        'group_end' => ConfigItemKind.groupEnd,
        _ => ConfigItemKind.session,
      },
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      commandId: (json['command_id'] ?? '').toString(),
      colorHex: (json['color_hex'] ?? '').toString(),
      provider: SessionProviderInfo.parse(json['provider']),
      fast: json['fast'] == true,
    );
  }

  factory ConfigItem.group({
    required String id,
    required String name,
    required String colorHex,
  }) {
    return ConfigItem(
      kind: ConfigItemKind.group,
      id: id,
      name: name,
      commandId: '',
      colorHex: colorHex,
      provider: SessionProvider.codex,
      fast: false,
    );
  }

  factory ConfigItem.session({
    required String commandId,
    required String name,
    required SessionProvider provider,
  }) {
    return ConfigItem(
      kind: ConfigItemKind.session,
      id: commandId,
      name: name,
      commandId: commandId,
      colorHex: '',
      provider: provider,
      fast: false,
    );
  }

  factory ConfigItem.groupEnd({required String id}) {
    return ConfigItem(
      kind: ConfigItemKind.groupEnd,
      id: id,
      name: '',
      commandId: '',
      colorHex: '',
      provider: SessionProvider.codex,
      fast: false,
    );
  }

  final ConfigItemKind kind;
  final String id;
  final String name;
  final String commandId;
  final String colorHex;
  final SessionProvider provider;
  final bool fast;

  bool get isGroup => kind == ConfigItemKind.group;

  bool get isSession => kind == ConfigItemKind.session;

  bool get isGroupEnd => kind == ConfigItemKind.groupEnd;

  bool get supportsFast => isSession && provider == SessionProvider.codex;

  bool get supportsFork => isSession && provider == SessionProvider.codex;

  String get identityKey => '${provider.key}:${commandId.trim().toLowerCase()}';

  String get displayName => name.trim().isEmpty ? shortId : name.trim();

  String get shortId =>
      _shortSessionId(commandId.trim().isEmpty ? id.trim() : commandId.trim());

  String get resumeCommand {
    if (provider == SessionProvider.kimi) {
      return 'kimi --session $commandId';
    }
    final base = 'codex resume $commandId';
    return fast ? '$base -c \'service_tier="fast"\'' : base;
  }

  String? get forkCommand {
    if (!supportsFork) {
      return null;
    }
    final base = 'codex fork $commandId';
    return fast ? '$base -c \'service_tier="fast"\'' : base;
  }

  ConfigItem copyWith({
    ConfigItemKind? kind,
    String? id,
    String? name,
    String? commandId,
    String? colorHex,
    SessionProvider? provider,
    bool? fast,
  }) {
    return ConfigItem(
      kind: kind ?? this.kind,
      id: id ?? this.id,
      name: name ?? this.name,
      commandId: commandId ?? this.commandId,
      colorHex: colorHex ?? this.colorHex,
      provider: provider ?? this.provider,
      fast: fast ?? this.fast,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': switch (kind) {
      ConfigItemKind.group => 'group',
      ConfigItemKind.groupEnd => 'group_end',
      ConfigItemKind.session => 'session',
    },
    'id': id,
    'name': name,
    'command_id': commandId,
    'color_hex': colorHex,
    'provider': provider.key,
    'fast': supportsFast && fast,
  };
}

String _shortSessionId(String rawValue) {
  final value = rawValue.trim();
  if (value.isEmpty) {
    return '';
  }
  final lastDash = value.lastIndexOf('-');
  final tail = lastDash == -1 ? value : value.substring(lastDash + 1).trim();
  return tail.isEmpty ? value : tail;
}
