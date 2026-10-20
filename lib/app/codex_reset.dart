import 'models.dart';

DateTime? codexManualResetBase(
  Iterable<CodexAccount> accounts, {
  required DateTime now,
}) {
  final horizon = now.add(
    const Duration(seconds: CodexAccount.defaultWeeklyWindowSeconds),
  );
  DateTime? latest;
  var hasAccounts = false;
  for (final account in accounts) {
    hasAccounts = true;
    final timestamp = account.weeklyResetAt;
    if (!account.isWeeklyWindow ||
        timestamp == null ||
        timestamp <= now.millisecondsSinceEpoch ||
        timestamp > horizon.millisecondsSinceEpoch) {
      continue;
    }
    final reset = DateTime.fromMillisecondsSinceEpoch(timestamp);
    if (latest == null || reset.isAfter(latest)) {
      latest = reset;
    }
  }
  // Monthly quotas and stale timestamps must not strand the seven-day picker.
  return latest ?? (hasAccounts ? horizon : null);
}
