// lib/services/explorer_service.dart

import 'dart:io';

import '../models/explorer_item.dart';

class ExplorerService {
  static const List<String> supportedExtensions = <String>[
    'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'mxf', 'mpg', 'mpeg',
    'wmv', 'ts', 'm2ts', 'dv', 'flv', 'ogv',
    'mp3', 'wav', 'flac', 'aac', 'ogg', 'opus', 'm4a',
    'png', 'jpg', 'jpeg', 'bmp', 'tif', 'tiff', 'exr', 'webp',
    'mlt', 'xml',
  ];

  static const String redleafLinkExtension = 'rlink';

  static const Set<String> _videoExtensions = <String>{
    'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'mxf', 'mpg', 'mpeg',
    'wmv', 'ts', 'm2ts', 'dv', 'flv', 'ogv',
  };

  static const Set<String> _audioExtensions = <String>{
    'mp3', 'wav', 'flac', 'aac', 'ogg', 'opus', 'm4a',
  };

  static const Set<String> _imageExtensions = <String>{
    'png', 'jpg', 'jpeg', 'bmp', 'tif', 'tiff', 'exr', 'webp',
  };

  static const Set<String> _projectExtensions = <String>{'mlt', 'xml'};

  Future<List<ExplorerItem>> scanDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw FileSystemException('Directory does not exist.', path);
    }

    final entities = await directory.list(followLinks: false).toList();
    final items = await Future.wait(entities.map(_itemForEntity));

    final supported = items.whereType<ExplorerItem>().toList();
    supported.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return supported;
  }

  Future<ExplorerItem?> _itemForEntity(FileSystemEntity entity) async {
    if (entity is Directory) {
      FileStat? stat;
      try {
        stat = await entity.stat();
      } on FileSystemException {
        // The directory can still be browsed even if metadata raced away.
      }
      return ExplorerItem.directory(entity, stat: stat);
    }

    if (entity is! File) {
      return null;
    }

    final extension = extensionForPath(entity.path);

    // Redleaf .rlink files are virtual folders. Keep the link file itself as
    // the Explorer item's path; ExplorerPage resolves it only when activated.
    // This lets disconnected links remain visible just like Redleaf does.
    if (extension == redleafLinkExtension) {
      FileStat? stat;
      try {
        stat = await entity.stat();
      } on FileSystemException {
        // Keep the virtual folder visible even if stat information raced away.
      }

      return ExplorerItem(
        path: entity.path,
        name: ExplorerItem.basename(entity.path),
        kind: ExplorerItemKind.directory,
        modified: stat?.modified,
      );
    }

    final kind = kindForPath(entity.path);
    if (kind == null) {
      return null;
    }

    FileStat? stat;
    try {
      stat = await entity.stat();
    } on FileSystemException {
      // Keep the media visible; metadata-backed sorts safely fall back.
    }

    return ExplorerItem.media(entity, kind, stat: stat);
  }

  ExplorerItemKind? kindForPath(String path) {
    final extension = extensionForPath(path);
    if (_videoExtensions.contains(extension)) {
      return ExplorerItemKind.video;
    }
    if (_audioExtensions.contains(extension)) {
      return ExplorerItemKind.audio;
    }
    if (_imageExtensions.contains(extension)) {
      return ExplorerItemKind.image;
    }
    if (_projectExtensions.contains(extension)) {
      return ExplorerItemKind.project;
    }
    return null;
  }

  bool isSupportedMediaPath(String path) => kindForPath(path) != null;

  bool isRedleafLinkPath(String path) =>
      extensionForPath(path) == redleafLinkExtension;

  String extensionForPath(String path) {
    final name = ExplorerItem.basename(path);
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }
}
