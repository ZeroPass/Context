import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/models.dart';
import 'session_agent_picker.dart';

typedef SessionDraft = ({String name, String input, SessionProvider provider});

class AddSessionDialog extends StatefulWidget {
  const AddSessionDialog({
    super.key,
    required this.appState,
    this.initialInput,
    this.initialName,
    this.initialProvider = SessionProvider.codex,
  });

  final AppState appState;
  final String? initialInput;
  final String? initialName;
  final SessionProvider initialProvider;

  @override
  State<AddSessionDialog> createState() => _AddSessionDialogState();
}

class _AddSessionDialogState extends State<AddSessionDialog> {
  late final _command = TextEditingController(text: widget.initialInput ?? '');
  late final _name = TextEditingController(text: widget.initialName ?? '');
  late SessionProvider _provider = widget.initialProvider;

  @override
  void dispose() {
    _command.dispose();
    _name.dispose();
    super.dispose();
  }

  void _inputChanged(String value) {
    try {
      final parsed = widget.appState.parseSessionInput(
        value,
        fallback: _provider,
      );
      final lower = value.toLowerCase();
      if ([
            'codex ',
            'kimi ',
            'opencode ',
            'muse ',
            'qwen ',
          ].any(lower.contains) &&
          parsed.provider != _provider) {
        setState(() => _provider = parsed.provider);
      }
    } on FormatException {
      // Incomplete commands are expected while typing.
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add Session'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SessionAgentPicker(
              provider: _provider,
              prefilled: widget.initialInput != null,
              onChanged: (value) => setState(() => _provider = value),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Optional display name',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _command,
              onChanged: _inputChanged,
              decoration: InputDecoration(
                labelText: 'Session id or resume command',
                hintText: switch (_provider) {
                  SessionProvider.codex => 'codex resume <id>',
                  SessionProvider.kimi => 'kimi --session <id>',
                  SessionProvider.opencode => 'opencode --session <id>',
                  SessionProvider.qwen => 'qwen --resume <id>',
                  SessionProvider.muse => 'muse resume <id> --yolo',
                  SessionProvider.zcode => '<session id>',
                },
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop<SessionDraft>((
          name: _name.text,
          input: _command.text,
          provider: _provider,
        )),
        child: const Text('Add'),
      ),
    ],
  );
}
