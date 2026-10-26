import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_terminal.dart';

/// Approve only the Terminal helper while the normal-rights UI is hidden.
Future<bool> startContext({
  required Future<void> Function() initializeBackend,
  required VoidCallback showApplication,
  bool? windows,
  SharedPreferences? preferences,
  SessionTerminal terminal = const SessionTerminal(),
}) async {
  final onWindows = windows ?? Platform.isWindows;
  if (onWindows) {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      final requestAdmin = prefs.getBool('askTerminalAdminAtStartup') ?? true;
      if (requestAdmin && !await terminal.isElevated()) {
        await terminal.restartElevated();
        // The helper stays elevated; this same normal-rights process loads UI.
      }
    } on PlatformException catch (error) {
      if (error.code != 'cancelled') {
        debugPrint('Startup administrator approval unavailable: ${error.code}');
      }
    } catch (_) {
      debugPrint('Could not read the startup administrator preference.');
    }
  }
  await initializeBackend();
  showApplication();
  if (onWindows) await terminal.finishStartup();
  return true;
}
