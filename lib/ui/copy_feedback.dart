import 'package:flutter/material.dart';

import '../app/clipboard_writer.dart';

Future<void> copyWithFeedback(
  BuildContext context,
  String text,
  String successMessage,
) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.removeCurrentSnackBar();
  try {
    final copied = await clipboardWriter.copy(text);
    if (!context.mounted || !copied) return;
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(successMessage)));
  } on ClipboardCopyException catch (error) {
    if (!context.mounted) return;
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(error.toString())));
  }
}
