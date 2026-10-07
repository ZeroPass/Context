import 'package:flutter/material.dart';

import '../../app/models.dart';

class SessionAgentPicker extends StatefulWidget {
  const SessionAgentPicker({
    super.key,
    required this.provider,
    required this.onChanged,
    this.prefilled = false,
  });

  final SessionProvider provider;
  final ValueChanged<SessionProvider> onChanged;
  final bool prefilled;

  @override
  State<SessionAgentPicker> createState() => _SessionAgentPickerState();
}

class _SessionAgentPickerState extends State<SessionAgentPicker> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    if (widget.prefilled && !_editing) {
      return Row(
        children: [
          const Icon(Icons.terminal_rounded, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.provider.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            key: const ValueKey('session-agent-change'),
            onPressed: () => setState(() => _editing = true),
            child: const Text('Change'),
          ),
        ],
      );
    }
    return DropdownButtonFormField<SessionProvider>(
      key: ValueKey('session-agent-${widget.provider.key}'),
      initialValue: widget.provider,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Coding agent'),
      items: [
        for (final provider in SessionProvider.values.where(
          (p) => p != SessionProvider.zcode,
        ))
          DropdownMenuItem(
            value: provider,
            child: Text(
              provider.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null) widget.onChanged(value);
      },
    );
  }
}
