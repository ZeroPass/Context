enum ConfigItemKind { group, session, groupEnd }

class RecentContext {
  const RecentContext({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.forkedFromId,
  });

  factory RecentContext.fromJson(Map<String, dynamic> json) {
    return RecentContext(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      forkedFromId: (json['forked_from_id'] ?? '').toString().trim().isEmpty
          ? null
          : (json['forked_from_id'] ?? '').toString().trim(),
    );
  }

  final String id;
  final String title;
  final int updatedAt;
  final String? forkedFromId;

  String get shortId {
    final value = id.trim();
    if (value.isEmpty) {
      return '';
    }
    final lastDash = value.lastIndexOf('-');
    final tail = lastDash == -1 ? value : value.substring(lastDash + 1).trim();
    return tail.isEmpty ? value : tail;
  }

  String get displayTitle => title.trim().isEmpty ? shortId : title.trim();

  bool get isForked => forkedFromId?.trim().isNotEmpty == true;
}

class LastAnswer {
  const LastAnswer({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.answerText,
    required this.sessionPath,
  });

  factory LastAnswer.fromJson(Map<String, dynamic> json) {
    return LastAnswer(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      answerText: (json['answer_text'] ?? '').toString(),
      sessionPath: (json['session_path'] ?? '').toString(),
    );
  }

  final String id;
  final String title;
  final int updatedAt;
  final String answerText;
  final String sessionPath;

  String get shortId {
    final value = id.trim();
    if (value.isEmpty) {
      return '';
    }
    final lastDash = value.lastIndexOf('-');
    final tail = lastDash == -1 ? value : value.substring(lastDash + 1).trim();
    return tail.isEmpty ? value : tail;
  }

  String get displayTitle => title.trim().isEmpty ? shortId : title.trim();

  String get resumeCommand => 'codex resume $id';

  String get forkCommand => 'codex fork $id';
}

class ConfigItem {
  const ConfigItem({
    required this.kind,
    required this.id,
    required this.name,
    required this.commandId,
    required this.colorHex,
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
      fast: false,
    );
  }

  factory ConfigItem.session({
    required String commandId,
    required String name,
  }) {
    return ConfigItem(
      kind: ConfigItemKind.session,
      id: commandId,
      name: name,
      commandId: commandId,
      colorHex: '',
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
      fast: false,
    );
  }

  final ConfigItemKind kind;
  final String id;
  final String name;
  final String commandId;
  final String colorHex;
  final bool fast;

  bool get isGroup => kind == ConfigItemKind.group;

  bool get isSession => kind == ConfigItemKind.session;

  bool get isGroupEnd => kind == ConfigItemKind.groupEnd;

  String get displayName => name.trim().isEmpty ? shortId : name.trim();

  String get shortId {
    final value = commandId.trim().isEmpty ? id.trim() : commandId.trim();
    if (value.isEmpty) {
      return '';
    }
    final lastDash = value.lastIndexOf('-');
    final tail = lastDash == -1 ? value : value.substring(lastDash + 1).trim();
    return tail.isEmpty ? value : tail;
  }

  String get resumeCommand =>
      fast ? 'codex resume $commandId --full-auto' : 'codex resume $commandId';

  String get forkCommand =>
      fast ? 'codex fork $commandId --full-auto' : 'codex fork $commandId';

  ConfigItem copyWith({
    ConfigItemKind? kind,
    String? id,
    String? name,
    String? commandId,
    String? colorHex,
    bool? fast,
  }) {
    return ConfigItem(
      kind: kind ?? this.kind,
      id: id ?? this.id,
      name: name ?? this.name,
      commandId: commandId ?? this.commandId,
      colorHex: colorHex ?? this.colorHex,
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
    'fast': fast,
  };
}
