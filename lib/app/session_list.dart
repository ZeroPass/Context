import 'models.dart';

/// A view over original indices, never a truncated or rewritten config.
class SessionListView {
  SessionListView(
    List<ConfigItem> items, {
    required bool expanded,
    List<int>? matches,
  }) {
    total = matches?.length ?? items.where((item) => item.isSession).length;
    if (matches != null) {
      indices = expanded ? matches : matches.take(10).toList();
      return;
    }
    if (expanded || total <= 10) {
      indices = List.generate(items.length, (index) => index);
      return;
    }
    var sessions = 0;
    int? group;
    final visible = <int>[];
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      visible.add(index);
      if (item.isGroup) group = index;
      if (item.isGroupEnd) group = null;
      if (item.isSession && ++sessions == 10) {
        // Keep the real closing row: dropping below it stays outside the group,
        // even when its remaining members are hidden by the compact view.
        if (group != null) {
          for (var end = index + 1; end < items.length; end++) {
            if (items[end].isGroupEnd) {
              visible.add(end);
              break;
            }
            if (items[end].isGroup) break;
          }
        }
        break;
      }
    }
    indices = visible;
  }
  late final List<int> indices;
  late final int total;
  bool get canExpand => total > 10;

  int insertionIndex(int oldIndex, int adjustedIndex) {
    final beforeRemoval = adjustedIndex >= oldIndex
        ? adjustedIndex + 1
        : adjustedIndex;
    return beforeRemoval < indices.length
        ? indices[beforeRemoval]
        : indices.last + 1;
  }
}
