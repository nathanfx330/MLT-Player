// lib/models/explorer_item.dart

import 'dart:io';

enum ExplorerItemKind {
  directory,
  video,
  audio,
  image,
  project,
}

class ExplorerItem {
  const ExplorerItem({
    required this.path,
    required this.name,
    required this.kind,
    this.sizeBytes,
    this.modified,
  });

  final String path;
  final String name;
  final ExplorerItemKind kind;
  final int? sizeBytes;
  final DateTime? modified;

  bool get isDirectory => kind == ExplorerItemKind.directory;

  String get extension {
    if (isDirectory) {
      return '';
    }
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  static String basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash == -1 ? normalized : normalized.substring(slash + 1);
  }

  static ExplorerItem directory(
    Directory directory, {
    FileStat? stat,
  }) {
    return ExplorerItem(
      path: directory.path,
      name: basename(directory.path),
      kind: ExplorerItemKind.directory,
      modified: stat?.modified,
    );
  }

  static ExplorerItem media(
    File file,
    ExplorerItemKind kind, {
    FileStat? stat,
  }) {
    return ExplorerItem(
      path: file.path,
      name: basename(file.path),
      kind: kind,
      sizeBytes: stat?.size,
      modified: stat?.modified,
    );
  }
}
