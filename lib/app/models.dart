enum ConfigItemKind { group, session, groupEnd }

enum SessionProvider { codex, kimi, opencode, qwen }

extension SessionProviderInfo on SessionProvider {
  String get key => name;

  String get label => switch (this) {
    SessionProvider.codex => 'Codex',
    SessionProvider.kimi => 'Kimi',
    SessionProvider.opencode => 'OpenCode',
    SessionProvider.qwen => 'Qwen Code',
  };

  static SessionProvider parse(Object? value) {
    final normalized = (value ?? '').toString().trim().toLowerCase();
    if (normalized == SessionProvider.kimi.name) {
      return SessionProvider.kimi;
    }
    if (normalized == SessionProvider.opencode.name) {
      return SessionProvider.opencode;
    }
    if (normalized == SessionProvider.qwen.name ||
        normalized == 'qwen-code' ||
        normalized == 'qwen code') {
      return SessionProvider.qwen;
    }
    return SessionProvider.codex;
  }
}

class CodexAccount {
  static const defaultWeeklyWindowSeconds = 604800;

  const CodexAccount({
    required this.slot,
    required this.name,
    this.updatedAt,
    this.weeklyUsedPercent,
    this.weeklyResetAt,
    this.weeklyWindowSeconds,
    this.weeklyError,
  });

  factory CodexAccount.fromJson(Map<String, dynamic> json) {
    final slot =
        _optionalTrimmedString(json['slot']) ??
        _optionalTrimmedString(json['name']) ??
        _optionalTrimmedString(json['label']) ??
        '';
    final name =
        _optionalTrimmedString(json['name']) ??
        _optionalTrimmedString(json['label']) ??
        slot;
    return CodexAccount(
      slot: slot,
      name: name,
      updatedAt: _optionalInt(json['updated_at']),
      weeklyUsedPercent: _optionalPercent(json['weekly_used_percent']),
      weeklyResetAt: _optionalInt(json['weekly_reset_at']),
      weeklyWindowSeconds: _optionalInt(json['weekly_window_seconds']),
      weeklyError: _optionalTrimmedString(json['weekly_error']),
    );
  }

  final String slot;
  final String name;
  final int? updatedAt;
  final double? weeklyUsedPercent;
  final int? weeklyResetAt;
  final int? weeklyWindowSeconds;
  final String? weeklyError;

  String get displayName => name.trim().isEmpty ? slot : name.trim();

  String get identityKey => slot.trim().toLowerCase();

  int get effectiveWeeklyWindowSeconds =>
      weeklyWindowSeconds ?? defaultWeeklyWindowSeconds;

  bool get hasWeeklyUsage =>
      weeklyError == null &&
      weeklyUsedPercent != null &&
      weeklyResetAt != null &&
      effectiveWeeklyWindowSeconds > 0;
}

String? _optionalTrimmedString(Object? value) {
  final result = (value ?? '').toString().trim();
  return result.isEmpty ? null : result;
}

int? _optionalInt(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? '').toString().trim());
}

double? _optionalPercent(Object? value) {
  final result = value is num
      ? value.toDouble()
      : double.tryParse((value ?? '').toString().trim());
  if (result == null || !result.isFinite || result < 0 || result > 100) {
    return null;
  }
  return result;
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
    );
  }

  final ConfigItemKind kind;
  final String id;
  final String name;
  final String commandId;
  final String colorHex;
  final SessionProvider provider;

  bool get isGroup => kind == ConfigItemKind.group;

  bool get isSession => kind == ConfigItemKind.session;

  bool get isGroupEnd => kind == ConfigItemKind.groupEnd;

  bool get supportsFork =>
      isSession &&
      (provider == SessionProvider.codex ||
          provider == SessionProvider.opencode);

  String get identityKey => '${provider.key}:${commandId.trim().toLowerCase()}';

  String get displayName => name.trim().isEmpty ? shortId : name.trim();

  String get shortId =>
      _shortSessionId(commandId.trim().isEmpty ? id.trim() : commandId.trim());

  String get resumeCommand {
    if (provider == SessionProvider.kimi) {
      return 'kimi --session $commandId';
    }
    if (provider == SessionProvider.opencode) {
      return 'opencode --session $commandId';
    }
    if (provider == SessionProvider.qwen) {
      return 'qwen --resume $commandId';
    }
    return 'codex resume $commandId';
  }

  String? get forkCommand {
    if (!supportsFork) {
      return null;
    }
    if (provider == SessionProvider.opencode) {
      return 'opencode --session $commandId --fork';
    }
    return 'codex fork $commandId';
  }

  ConfigItem copyWith({
    ConfigItemKind? kind,
    String? id,
    String? name,
    String? commandId,
    String? colorHex,
    SessionProvider? provider,
  }) {
    return ConfigItem(
      kind: kind ?? this.kind,
      id: id ?? this.id,
      name: name ?? this.name,
      commandId: commandId ?? this.commandId,
      colorHex: colorHex ?? this.colorHex,
      provider: provider ?? this.provider,
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
  };
}

String _shortSessionId(String rawValue) {
  final value = rawValue.trim();
  if (value.isEmpty) {
    return '';
  }
  const visibleLength = 4;
  if (value.length <= visibleLength) {
    return value;
  }
  return value.substring(value.length - visibleLength);
}
