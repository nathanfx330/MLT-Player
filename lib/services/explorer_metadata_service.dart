// lib/services/explorer_metadata_service.dart

import 'dart:io';
import 'dart:ui' as ui;

import '../models/explorer_item.dart';
import '../models/explorer_metadata.dart';

class ExplorerMetadataService {
  final Map<String, _CachedMetadata> _cache = <String, _CachedMetadata>{};

  Future<ExplorerMetadata> metadataFor(ExplorerItem item) async {
    final isRedleafLink =
        item.isDirectory && item.path.toLowerCase().endsWith('.rlink');

    final entity = isRedleafLink
        ? File(item.path)
        : item.isDirectory
            ? Directory(item.path)
            : File(item.path);
    final stat = await entity.stat();

    if (stat.type == FileSystemEntityType.notFound) {
      throw FileSystemException('Item no longer exists.', item.path);
    }

    final cached = _cache[item.path];
    if (cached != null && cached.matches(stat)) {
      return cached.metadata;
    }

    int? pixelWidth;
    int? pixelHeight;

    if (item.kind == ExplorerItemKind.image && !item.isDirectory) {
      final dimensions = await _readImageDimensions(File(item.path));
      pixelWidth = dimensions?.width;
      pixelHeight = dimensions?.height;
    }

    final metadata = ExplorerMetadata(
      modified: stat.modified,
      byteSize: item.isDirectory ? null : stat.size,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );

    _cache[item.path] = _CachedMetadata(
      size: stat.size,
      modified: stat.modified,
      metadata: metadata,
    );

    return metadata;
  }

  Future<_ImageDimensions?> _readImageDimensions(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          return _ImageDimensions(
            frame.image.width,
            frame.image.height,
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      // Explorer metadata is advisory. A format Flutter cannot decode here
      // must remain browseable and can still be opened by the MLT Player.
      return null;
    }
  }

  void invalidate(String path) {
    _cache.remove(path);
  }

  void clear() {
    _cache.clear();
  }
}

class _CachedMetadata {
  const _CachedMetadata({
    required this.size,
    required this.modified,
    required this.metadata,
  });

  final int size;
  final DateTime modified;
  final ExplorerMetadata metadata;

  bool matches(FileStat stat) =>
      size == stat.size && modified == stat.modified;
}

class _ImageDimensions {
  const _ImageDimensions(this.width, this.height);

  final int width;
  final int height;
}
