enum ConfigItemKind { group, session, groupEnd }

class ConfigItem {
  const ConfigItem({
    required this.kind,
    required this.id,
    required this.name,
    required this.commandId,
    required this.colorHex,
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
    );
  }

  factory ConfigItem.groupEnd({required String id}) {
    return ConfigItem(
      kind: ConfigItemKind.groupEnd,
      id: id,
      name: '',
      commandId: '',
      colorHex: '',
    );
  }

  final ConfigItemKind kind;
  final String id;
  final String name;
  final String commandId;
  final String colorHex;

  bool get isGroup => kind == ConfigItemKind.group;

  bool get isSession => kind == ConfigItemKind.session;

  bool get isGroupEnd => kind == ConfigItemKind.groupEnd;

  String get displayName => name.trim().isEmpty ? shortId : name.trim();

  String get shortId {
    final value = commandId.trim().isEmpty ? id.trim() : commandId.trim();
    return value.length <= 8 ? value : value.substring(0, 8);
  }

  String get resumeCommand => 'codex resume $commandId';

  String get forkCommand => 'codex fork $commandId';

  ConfigItem copyWith({
    ConfigItemKind? kind,
    String? id,
    String? name,
    String? commandId,
    String? colorHex,
  }) {
    return ConfigItem(
      kind: kind ?? this.kind,
      id: id ?? this.id,
      name: name ?? this.name,
      commandId: commandId ?? this.commandId,
      colorHex: colorHex ?? this.colorHex,
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
  };
}
