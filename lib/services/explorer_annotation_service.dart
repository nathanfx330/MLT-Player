// lib/services/explorer_annotation_service.dart

import 'dart:convert';
import 'dart:io';

import '../models/explorer_asset_annotation.dart';

class ExplorerAnnotationService {
  ExplorerAnnotationService({Directory? configDirectory})
      : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  final Directory _configDirectory;
  final Map<String, ExplorerAssetAnnotation> _annotations =
      <String, ExplorerAssetAnnotation>{};
  Future<void> _writeTail = Future<void>.value();

  ExplorerAssetAnnotation annotationFor(String path) {
    return _annotations[path] ?? ExplorerAssetAnnotation.empty;
  }

  int ratingFor(String path) => annotationFor(path).rating;

  List<String> tagsFor(String path) => annotationFor(path).tags;

  bool matchesFilters(
    String path, {
    int minimumRating = 0,
    String? tag,
  }) {
    final annotation = annotationFor(path);
    final normalizedMinimum = minimumRating.clamp(0, 5).toInt();
    if (annotation.rating < normalizedMinimum) {
      return false;
    }

    final normalizedTag = tag?.trim().toLowerCase();
    if (normalizedTag == null || normalizedTag.isEmpty) {
      return true;
    }

    return annotation.tags.any(
      (value) => value.toLowerCase() == normalizedTag,
    );
  }

  List<String> tagsForPaths(Iterable<String> paths) {
    final tagsByKey = <String, String>{};

    for (final path in paths) {
      for (final tag in tagsFor(path)) {
        final key = tag.toLowerCase();
        tagsByKey.putIfAbsent(key, () => tag);
      }
    }

    final tags = tagsByKey.values.toList(growable: false);
    tags.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return List<String>.unmodifiable(tags);
  }

  void setRating(String path, int rating) {
    final normalizedRating = rating.clamp(0, 5).toInt();
    final current = annotationFor(path);
    _store(
      path,
      ExplorerAssetAnnotation(
        rating: normalizedRating,
        tags: current.tags,
      ),
    );
  }

  void setTags(String path, Iterable<String> tags) {
    final current = annotationFor(path);
    _store(
      path,
      ExplorerAssetAnnotation(
        rating: current.rating,
        tags: normalizeTags(tags),
      ),
    );
  }

  void addTag(String path, String tag) {
    final current = annotationFor(path);
    setTags(path, <String>[...current.tags, tag]);
  }

  void removeTag(String path, String tag) {
    final normalized = tag.trim().toLowerCase();
    if (normalized.isEmpty) {
      return;
    }

    final current = annotationFor(path);
    setTags(
      path,
      current.tags.where((value) => value.toLowerCase() != normalized),
    );
  }

  Future<void> load() async {
    final file = _stateFile;
    if (!await file.exists()) {
      return;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final assets = decoded['assets'];
      if (assets is! Map<String, dynamic>) {
        return;
      }

      final restored = <String, ExplorerAssetAnnotation>{};
      for (final entry in assets.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          continue;
        }

        final rawRating = value['rating'];
        final rating = rawRating is int ? rawRating.clamp(0, 5).toInt() : 0;

        final rawTags = value['tags'];
        final tags = rawTags is List
            ? normalizeTags(rawTags.whereType<String>())
            : const <String>[];

        final annotation = ExplorerAssetAnnotation(
          rating: rating,
          tags: tags,
        );
        if (!annotation.isEmpty) {
          restored[entry.key] = annotation;
        }
      }

      _annotations
        ..clear()
        ..addAll(restored);
    } catch (_) {
      _annotations.clear();
    }
  }

  Future<void> save() {
    final assets = <String, Object>{};
    final paths = _annotations.keys.toList()..sort();

    for (final path in paths) {
      final annotation = _annotations[path]!;
      assets[path] = <String, Object>{
        'rating': annotation.rating,
        'tags': annotation.tags,
      };
    }

    final contents = jsonEncode(<String, Object>{
      'version': 1,
      'assets': assets,
    });

    final previousWrite = _writeTail;
    _writeTail = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later save should still run after an earlier I/O failure.
      }

      await _configDirectory.create(recursive: true);
      await _stateFile.writeAsString(contents, flush: true);
    }();

    return _writeTail;
  }

  static List<String> normalizeTags(Iterable<String> tags) {
    final normalized = <String>[];
    final seen = <String>{};

    for (final rawTag in tags) {
      final tag = rawTag.trim();
      if (tag.isEmpty) {
        continue;
      }

      final key = tag.toLowerCase();
      if (seen.add(key)) {
        normalized.add(tag);
      }
    }

    return List<String>.unmodifiable(normalized);
  }

  void _store(String path, ExplorerAssetAnnotation annotation) {
    if (annotation.isEmpty) {
      _annotations.remove(path);
    } else {
      _annotations[path] = annotation;
    }
  }

  File get _stateFile => File('${_configDirectory.path}/explorer_annotations.json');

  static Directory _defaultConfigDirectory() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.trim().isNotEmpty) {
      return Directory('${xdg.trim()}/mlt_player');
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return Directory('${home.trim()}/.config/mlt_player');
    }

    return Directory('${Directory.systemTemp.path}/mlt_player');
  }
}
