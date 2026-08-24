// lib/services/explorer_sort_filter_service.dart

import '../models/explorer_item.dart';

enum ExplorerSortMode {
  name,
  modified,
  size,
  type,
}

extension ExplorerSortModeLabel on ExplorerSortMode {
  String get label => switch (this) {
        ExplorerSortMode.name => 'Name',
        ExplorerSortMode.modified => 'Modified',
        ExplorerSortMode.size => 'Size',
        ExplorerSortMode.type => 'Type',
      };
}

class ExplorerSortFilterService {
  List<ExplorerItem> apply(
    List<ExplorerItem> items, {
    String query = '',
    ExplorerSortMode sortMode = ExplorerSortMode.name,
    bool descending = false,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final visible = items
        .where(
          (item) => normalizedQuery.isEmpty ||
              item.name.toLowerCase().contains(normalizedQuery),
        )
        .toList(growable: false);

    final sorted = List<ExplorerItem>.of(visible);
    sorted.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }

      var comparison = switch (sortMode) {
        ExplorerSortMode.name => _compareName(a, b),
        ExplorerSortMode.modified => _compareModified(a, b),
        ExplorerSortMode.size => _compareSize(a, b),
        ExplorerSortMode.type => _compareType(a, b),
      };

      if (comparison == 0) {
        comparison = _compareName(a, b);
      }

      return descending ? -comparison : comparison;
    });

    return List<ExplorerItem>.unmodifiable(sorted);
  }

  static int _compareName(ExplorerItem a, ExplorerItem b) {
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  static int _compareModified(ExplorerItem a, ExplorerItem b) {
    final aValue = a.modified?.millisecondsSinceEpoch ?? 0;
    final bValue = b.modified?.millisecondsSinceEpoch ?? 0;
    return aValue.compareTo(bValue);
  }

  static int _compareSize(ExplorerItem a, ExplorerItem b) {
    if (a.isDirectory && b.isDirectory) {
      return _compareName(a, b);
    }

    final aValue = a.sizeBytes ?? 0;
    final bValue = b.sizeBytes ?? 0;
    return aValue.compareTo(bValue);
  }

  static int _compareType(ExplorerItem a, ExplorerItem b) {
    if (a.isDirectory && b.isDirectory) {
      return _compareName(a, b);
    }

    final typeComparison = _typeLabel(a).compareTo(_typeLabel(b));
    if (typeComparison != 0) {
      return typeComparison;
    }

    final extensionComparison = a.extension.compareTo(b.extension);
    if (extensionComparison != 0) {
      return extensionComparison;
    }

    return _compareName(a, b);
  }

  static String _typeLabel(ExplorerItem item) => switch (item.kind) {
        ExplorerItemKind.directory => 'folder',
        ExplorerItemKind.video => 'video',
        ExplorerItemKind.audio => 'audio',
        ExplorerItemKind.image => 'image',
        ExplorerItemKind.project => 'project',
      };
}
