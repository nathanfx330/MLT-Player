// lib/services/project_media_metadata_service.dart

import 'dart:convert';
import 'dart:io';

import '../models/project_media_metadata.dart';

class ProjectMediaMetadataService {
  ProjectMediaMetadataService({Directory? configDirectory})
      : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  static const int storageVersion = 1;
  static final RegExp _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

  final Directory _configDirectory;
  final Map<String, Map<String, ProjectMediaMetadata>> _projects =
      <String, Map<String, ProjectMediaMetadata>>{};
  Future<void> _writeTail = Future<void>.value();

  bool _loaded = false;
  bool _didMigrateLegacyData = false;

  bool get loaded => _loaded;
  bool get didMigrateLegacyData => _didMigrateLegacyData;

  ProjectMediaMetadata metadataFor(
    String projectId,
    String mediaPath,
  ) {
    _requireProjectId(projectId);
    final path = _normalizeMediaPath(mediaPath);
    return _projects[projectId]?[path] ?? ProjectMediaMetadata.empty;
  }

  int ratingFor(String projectId, String mediaPath) =>
      metadataFor(projectId, mediaPath).rating;

  List<String> tagsFor(String projectId, String mediaPath) =>
      metadataFor(projectId, mediaPath).tags;

  String? colorHexFor(String projectId, String mediaPath) =>
      metadataFor(projectId, mediaPath).colorHex;

  List<int> bookmarkFramesFor(String projectId, String mediaPath) =>
      metadataFor(projectId, mediaPath).bookmarkFrames;

  bool containsBookmark(
    String projectId,
    String mediaPath,
    int sourceFrame,
  ) =>
      bookmarkFramesFor(projectId, mediaPath).contains(sourceFrame);

  bool matchesFilters(
    String projectId,
    String mediaPath, {
    int minimumRating = 0,
    int? exactRating,
    String? tag,
    String? colorHex,
  }) {
    final metadata = metadataFor(projectId, mediaPath);
    final normalizedMinimum = minimumRating.clamp(0, 5).toInt();
    final normalizedExact = exactRating?.clamp(0, 5).toInt();

    if (normalizedExact != null) {
      if (metadata.rating != normalizedExact) {
        return false;
      }
    } else if (metadata.rating < normalizedMinimum) {
      return false;
    }

    final normalizedColor = normalizeColorHex(colorHex);
    if (normalizedColor != null && metadata.colorHex != normalizedColor) {
      return false;
    }

    final normalizedTag = tag?.trim().toLowerCase();
    if (normalizedTag == null || normalizedTag.isEmpty) {
      return true;
    }

    return metadata.tags.any(
      (value) => value.toLowerCase() == normalizedTag,
    );
  }

  List<String> tagsForPaths(
    String projectId,
    Iterable<String> mediaPaths,
  ) {
    final tagsByKey = <String, String>{};

    for (final mediaPath in mediaPaths) {
      for (final tag in tagsFor(projectId, mediaPath)) {
        tagsByKey.putIfAbsent(tag.toLowerCase(), () => tag);
      }
    }

    final tags = tagsByKey.values.toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return List<String>.unmodifiable(tags);
  }

  void setRating(
    String projectId,
    String mediaPath,
    int rating,
  ) {
    final current = metadataFor(projectId, mediaPath);
    _store(
      projectId,
      mediaPath,
      current.copyWith(rating: rating.clamp(0, 5).toInt()),
    );
  }

  void setTags(
    String projectId,
    String mediaPath,
    Iterable<String> tags,
  ) {
    final current = metadataFor(projectId, mediaPath);
    _store(
      projectId,
      mediaPath,
      current.copyWith(tags: normalizeTags(tags)),
    );
  }

  void addTag(
    String projectId,
    String mediaPath,
    String tag,
  ) {
    final current = metadataFor(projectId, mediaPath);
    setTags(
      projectId,
      mediaPath,
      <String>[...current.tags, tag],
    );
  }

  void removeTag(
    String projectId,
    String mediaPath,
    String tag,
  ) {
    final normalized = tag.trim().toLowerCase();
    if (normalized.isEmpty) {
      return;
    }

    final current = metadataFor(projectId, mediaPath);
    setTags(
      projectId,
      mediaPath,
      current.tags.where(
        (value) => value.toLowerCase() != normalized,
      ),
    );
  }

  void setColorHex(
    String projectId,
    String mediaPath,
    String? colorHex,
  ) {
    final current = metadataFor(projectId, mediaPath);
    final normalized = normalizeColorHex(colorHex);

    _store(
      projectId,
      mediaPath,
      current.copyWith(
        colorHex: normalized,
        clearColor: normalized == null,
      ),
    );
  }

  bool addBookmark(
    String projectId,
    String mediaPath,
    int sourceFrame,
  ) {
    if (sourceFrame < 0) {
      return false;
    }

    final current = metadataFor(projectId, mediaPath);
    if (current.bookmarkFrames.contains(sourceFrame)) {
      return false;
    }

    final frames = <int>[...current.bookmarkFrames, sourceFrame]..sort();
    _store(
      projectId,
      mediaPath,
      current.copyWith(
        bookmarkFrames: List<int>.unmodifiable(frames),
      ),
    );
    return true;
  }

  bool removeBookmark(
    String projectId,
    String mediaPath,
    int sourceFrame,
  ) {
    final current = metadataFor(projectId, mediaPath);
    if (!current.bookmarkFrames.contains(sourceFrame)) {
      return false;
    }

    final frames = current.bookmarkFrames
        .where((frame) => frame != sourceFrame)
        .toList(growable: false);

    _store(
      projectId,
      mediaPath,
      current.copyWith(
        bookmarkFrames: List<int>.unmodifiable(frames),
      ),
    );
    return true;
  }

  bool toggleBookmark(
    String projectId,
    String mediaPath,
    int sourceFrame,
  ) {
    if (containsBookmark(projectId, mediaPath, sourceFrame)) {
      removeBookmark(projectId, mediaPath, sourceFrame);
      return false;
    }

    return addBookmark(projectId, mediaPath, sourceFrame);
  }

  List<String> mediaPathsForProject(String projectId) {
    _requireProjectId(projectId);

    final paths =
        _projects[projectId]?.keys.toList(growable: false) ?? <String>[];
    paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return List<String>.unmodifiable(paths);
  }

  List<String> bookmarkedMediaPathsForProject(String projectId) {
    _requireProjectId(projectId);

    final paths = (_projects[projectId]?.entries ??
            const <MapEntry<String, ProjectMediaMetadata>>[])
        .where((entry) => entry.value.bookmarkFrames.isNotEmpty)
        .map((entry) => entry.key)
        .toList(growable: false);
    paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return List<String>.unmodifiable(paths);
  }

  int ratedMediaCount(String projectId) =>
      _recordsFor(projectId).where((item) => item.rating > 0).length;

  int taggedMediaCount(String projectId) =>
      _recordsFor(projectId).where((item) => item.tags.isNotEmpty).length;

  int colorLabeledMediaCount(String projectId) =>
      _recordsFor(projectId).where((item) => item.colorHex != null).length;

  int bookmarkCount(String projectId) => _recordsFor(projectId).fold<int>(
        0,
        (total, item) => total + item.bookmarkFrames.length,
      );

  int bookmarkedMediaCount(String projectId) => _recordsFor(projectId)
      .where((item) => item.bookmarkFrames.isNotEmpty)
      .length;

  Map<int, int> ratingCountsForProject(String projectId) {
    final counts = <int, int>{
      for (var rating = 1; rating <= 5; rating++) rating: 0,
    };

    for (final metadata in _recordsFor(projectId)) {
      if (metadata.rating > 0) {
        counts[metadata.rating] = (counts[metadata.rating] ?? 0) + 1;
      }
    }

    return Map<int, int>.unmodifiable(counts);
  }

  Map<String, int> tagCountsForProject(String projectId) {
    final displayByKey = <String, String>{};
    final countsByKey = <String, int>{};

    for (final metadata in _recordsFor(projectId)) {
      for (final tag in metadata.tags) {
        final key = tag.toLowerCase();
        displayByKey.putIfAbsent(key, () => tag);
        countsByKey[key] = (countsByKey[key] ?? 0) + 1;
      }
    }

    final keys = countsByKey.keys.toList(growable: false)
      ..sort((a, b) {
        final byCount = countsByKey[b]!.compareTo(countsByKey[a]!);
        if (byCount != 0) {
          return byCount;
        }
        return displayByKey[a]!
            .toLowerCase()
            .compareTo(displayByKey[b]!.toLowerCase());
      });

    return Map<String, int>.unmodifiable(
      <String, int>{
        for (final key in keys) displayByKey[key]!: countsByKey[key]!,
      },
    );
  }

  Map<String, int> colorCountsForProject(String projectId) {
    final counts = <String, int>{};

    for (final metadata in _recordsFor(projectId)) {
      final colorHex = metadata.colorHex;
      if (colorHex != null) {
        counts[colorHex] = (counts[colorHex] ?? 0) + 1;
      }
    }

    final colors = counts.keys.toList(growable: false)..sort();
    return Map<String, int>.unmodifiable(
      <String, int>{
        for (final color in colors) color: counts[color]!,
      },
    );
  }

  void deleteProjectData(String projectId) {
    _requireProjectId(projectId);
    _projects.remove(projectId);
  }

  Future<void> load({
    required String defaultProjectId,
  }) async {
    _requireProjectId(defaultProjectId);

    _projects.clear();
    _loaded = false;
    _didMigrateLegacyData = false;

    if (await _stateFile.exists()) {
      await _loadCurrentState();
      _loaded = true;
      return;
    }

    final migrated = await _migrateLegacyState(defaultProjectId);
    _didMigrateLegacyData = migrated;
    _loaded = true;

    if (migrated) {
      await save();
    }
  }

  Future<void> _loadCurrentState() async {
    try {
      final decoded = jsonDecode(await _stateFile.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final rawProjects = decoded['projects'];
      if (rawProjects is! Map<String, dynamic>) {
        return;
      }

      for (final projectEntry in rawProjects.entries) {
        final projectId = projectEntry.key.trim();
        final rawProject = projectEntry.value;

        if (projectId.isEmpty || rawProject is! Map<String, dynamic>) {
          continue;
        }

        final rawAssets = rawProject['assets'];
        if (rawAssets is! Map<String, dynamic>) {
          continue;
        }

        final restored = <String, ProjectMediaMetadata>{};

        for (final assetEntry in rawAssets.entries) {
          final rawMetadata = assetEntry.value;
          if (rawMetadata is! Map<String, dynamic>) {
            continue;
          }

          final metadata = _metadataFromJson(rawMetadata);
          if (metadata.isEmpty) {
            continue;
          }

          final path = _normalizeMediaPath(assetEntry.key);
          if (path.isNotEmpty) {
            restored[path] = metadata;
          }
        }

        if (restored.isNotEmpty) {
          _projects[projectId] = restored;
        }
      }
    } catch (_) {
      _projects.clear();
    }
  }

  Future<bool> _migrateLegacyState(String defaultProjectId) async {
    final migrated = <String, ProjectMediaMetadata>{};

    await _readLegacyAnnotations(migrated);
    await _readLegacyBookmarks(migrated);

    migrated.removeWhere((_, metadata) => metadata.isEmpty);
    if (migrated.isEmpty) {
      return false;
    }

    _projects[defaultProjectId] = migrated;
    return true;
  }

  Future<void> _readLegacyAnnotations(
    Map<String, ProjectMediaMetadata> migrated,
  ) async {
    if (!await _legacyAnnotationsFile.exists()) {
      return;
    }

    try {
      final decoded = jsonDecode(
        await _legacyAnnotationsFile.readAsString(),
      );
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final assets = decoded['assets'];
      if (assets is! Map<String, dynamic>) {
        return;
      }

      for (final entry in assets.entries) {
        final raw = entry.value;
        if (raw is! Map<String, dynamic>) {
          continue;
        }

        final rawRating = raw['rating'];
        final rating =
            rawRating is int ? rawRating.clamp(0, 5).toInt() : 0;

        final rawTags = raw['tags'];
        final tags = rawTags is List
            ? normalizeTags(rawTags.whereType<String>())
            : const <String>[];

        final path = _normalizeMediaPath(entry.key);
        if (path.isEmpty) {
          continue;
        }

        final current =
            migrated[path] ?? ProjectMediaMetadata.empty;
        migrated[path] = current.copyWith(
          rating: rating,
          tags: tags,
        );
      }
    } catch (_) {
      // The old file remains untouched if it is malformed.
    }
  }

  Future<void> _readLegacyBookmarks(
    Map<String, ProjectMediaMetadata> migrated,
  ) async {
    if (!await _legacyBookmarksFile.exists()) {
      return;
    }

    try {
      final decoded = jsonDecode(
        await _legacyBookmarksFile.readAsString(),
      );
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final media = decoded['media'];
      if (media is! Map<String, dynamic>) {
        return;
      }

      for (final entry in media.entries) {
        final rawFrames = entry.value;
        if (rawFrames is! List) {
          continue;
        }

        final frames = _normalizeBookmarkFrames(
          rawFrames.whereType<int>(),
        );
        if (frames.isEmpty) {
          continue;
        }

        final path = _normalizeMediaPath(entry.key);
        if (path.isEmpty) {
          continue;
        }

        final current =
            migrated[path] ?? ProjectMediaMetadata.empty;
        migrated[path] = current.copyWith(
          bookmarkFrames: frames,
        );
      }
    } catch (_) {
      // The old file remains untouched if it is malformed.
    }
  }

  Future<void> save() {
    final projects = <String, Object>{};
    final projectIds = _projects.keys.toList()..sort();

    for (final projectId in projectIds) {
      final records = _projects[projectId];
      if (records == null || records.isEmpty) {
        continue;
      }

      final assets = <String, Object>{};
      final paths = records.keys.toList()..sort();

      for (final path in paths) {
        final metadata = records[path]!;
        if (!metadata.isEmpty) {
          assets[path] = _metadataToJson(metadata);
        }
      }

      if (assets.isNotEmpty) {
        projects[projectId] = <String, Object>{
          'assets': assets,
        };
      }
    }

    final contents = const JsonEncoder.withIndent('  ').convert(
      <String, Object>{
        'version': storageVersion,
        'projects': projects,
      },
    );

    final previousWrite = _writeTail;
    _writeTail = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later write should still run after an earlier failure.
      }

      await _configDirectory.create(recursive: true);

      final temporary = File('${_stateFile.path}.tmp');
      await temporary.writeAsString(contents, flush: true);

      if (await _stateFile.exists()) {
        await _stateFile.delete();
      }
      await temporary.rename(_stateFile.path);
    }();

    return _writeTail;
  }

  ProjectMediaMetadata _metadataFromJson(
    Map<String, dynamic> raw,
  ) {
    final rawRating = raw['rating'];
    final rating =
        rawRating is int ? rawRating.clamp(0, 5).toInt() : 0;

    final rawTags = raw['tags'];
    final tags = rawTags is List
        ? normalizeTags(rawTags.whereType<String>())
        : const <String>[];

    String? colorHex;
    final rawColor = raw['color'];
    if (rawColor is String) {
      try {
        colorHex = normalizeColorHex(rawColor);
      } on ArgumentError {
        colorHex = null;
      }
    }

    final rawBookmarks = raw['bookmarks'];
    final bookmarks = rawBookmarks is List
        ? _normalizeBookmarkFrames(
            rawBookmarks.whereType<int>(),
          )
        : const <int>[];

    return ProjectMediaMetadata(
      rating: rating,
      tags: tags,
      colorHex: colorHex,
      bookmarkFrames: bookmarks,
    );
  }

  Map<String, Object> _metadataToJson(
    ProjectMediaMetadata metadata,
  ) {
    final json = <String, Object>{};

    if (metadata.rating > 0) {
      json['rating'] = metadata.rating;
    }
    if (metadata.tags.isNotEmpty) {
      json['tags'] = metadata.tags;
    }
    if (metadata.colorHex != null) {
      json['color'] = metadata.colorHex!;
    }
    if (metadata.bookmarkFrames.isNotEmpty) {
      json['bookmarks'] = metadata.bookmarkFrames;
    }

    return json;
  }

  void _store(
    String projectId,
    String mediaPath,
    ProjectMediaMetadata metadata,
  ) {
    _requireProjectId(projectId);
    final path = _normalizeMediaPath(mediaPath);

    if (path.isEmpty) {
      return;
    }

    final records = _projects.putIfAbsent(
      projectId,
      () => <String, ProjectMediaMetadata>{},
    );

    if (metadata.isEmpty) {
      records.remove(path);
      if (records.isEmpty) {
        _projects.remove(projectId);
      }
      return;
    }

    records[path] = ProjectMediaMetadata(
      rating: metadata.rating.clamp(0, 5).toInt(),
      tags: normalizeTags(metadata.tags),
      colorHex: normalizeColorHex(metadata.colorHex),
      bookmarkFrames: _normalizeBookmarkFrames(
        metadata.bookmarkFrames,
      ),
    );
  }

  Iterable<ProjectMediaMetadata> _recordsFor(String projectId) {
    _requireProjectId(projectId);
    return _projects[projectId]?.values ??
        const <ProjectMediaMetadata>[];
  }

  static List<String> normalizeTags(Iterable<String> tags) {
    final normalized = <String>[];
    final seen = <String>{};

    for (final rawTag in tags) {
      final tag = rawTag.trim();
      if (tag.isEmpty) {
        continue;
      }

      if (seen.add(tag.toLowerCase())) {
        normalized.add(tag);
      }
    }

    return List<String>.unmodifiable(normalized);
  }

  static String? normalizeColorHex(String? colorHex) {
    final value = colorHex?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }

    if (!_colorPattern.hasMatch(value)) {
      throw ArgumentError.value(
        colorHex,
        'colorHex',
        'Color labels must use #RRGGBB.',
      );
    }

    return value.toUpperCase();
  }

  static List<int> _normalizeBookmarkFrames(
    Iterable<int> frames,
  ) {
    final normalized = frames
        .where((frame) => frame >= 0)
        .toSet()
        .toList()
      ..sort();

    return List<int>.unmodifiable(normalized);
  }

  static String _normalizeMediaPath(String mediaPath) {
    final trimmed = mediaPath.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return File(trimmed).absolute.path;
  }

  static void _requireProjectId(String projectId) {
    if (projectId.trim().isEmpty) {
      throw ArgumentError.value(
        projectId,
        'projectId',
        'Project ID cannot be empty.',
      );
    }
  }

  File get _stateFile =>
      File('${_configDirectory.path}/project_media_metadata.json');

  File get _legacyAnnotationsFile =>
      File('${_configDirectory.path}/explorer_annotations.json');

  File get _legacyBookmarksFile =>
      File('${_configDirectory.path}/bookmarks.json');

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
