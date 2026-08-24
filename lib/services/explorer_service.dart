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

    final items = <ExplorerItem>[];

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Directory) {
        items.add(ExplorerItem.directory(entity));
        continue;
      }

      if (entity is! File) {
        continue;
      }

      final kind = kindForPath(entity.path);
      if (kind == null) {
        continue;
      }

      items.add(ExplorerItem.media(entity, kind));
    }

    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return items;
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

  String extensionForPath(String path) {
    final name = ExplorerItem.basename(path);
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }
}
