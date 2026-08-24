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
  });

  final String path;
  final String name;
  final ExplorerItemKind kind;

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

  static ExplorerItem directory(Directory directory) {
    return ExplorerItem(
      path: directory.path,
      name: basename(directory.path),
      kind: ExplorerItemKind.directory,
    );
  }

  static ExplorerItem media(File file, ExplorerItemKind kind) {
    return ExplorerItem(
      path: file.path,
      name: basename(file.path),
      kind: kind,
    );
  }
}
