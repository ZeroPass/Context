import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_terminal.dart';

/// Decide elevation while the native window is hidden and before Rust workers
/// or the application widget tree can read sessions or start background work.
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
        // The hidden parent closes; only its elevated replacement loads the app.
        return false;
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
