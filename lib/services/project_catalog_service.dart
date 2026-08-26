// lib/services/project_catalog_service.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/project_catalog.dart';

class ProjectCatalogService {
  ProjectCatalogService({Directory? configDirectory})
      : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  static const int storageVersion = 1;
  static const String defaultProjectName = 'Default Project';
  static const String favoritesCatalogName = '⭐ Favorites';

  final Directory _configDirectory;
  final Map<String, MediaProject> _projects = <String, MediaProject>{};
  final Map<String, MediaCatalog> _catalogs = <String, MediaCatalog>{};
  final Map<String, CatalogMembership> _memberships =
      <String, CatalogMembership>{};

  Future<void> _writeTail = Future<void>.value();
  String? _activeProjectId;

  String get activeProjectId {
    _ensureInitialized();
    return _activeProjectId!;
  }

  MediaProject get activeProject {
    _ensureInitialized();
    return _projects[_activeProjectId]!;
  }

  List<MediaProject> get projects {
    _ensureInitialized();
    final values = _projects.values.toList(growable: false)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<MediaProject>.unmodifiable(values);
  }

  MediaProject? projectById(String projectId) => _projects[projectId];

  MediaCatalog? catalogById(String catalogId) => _catalogs[catalogId];

  List<MediaCatalog> catalogsForProject([String? projectId]) {
    _ensureInitialized();
    final resolvedProjectId = projectId ?? activeProjectId;

    final values = _catalogs.values
        .where((catalog) => catalog.projectId == resolvedProjectId)
        .toList(growable: false)
      ..sort(_compareCatalogs);

    return List<MediaCatalog>.unmodifiable(values);
  }

  List<MediaCatalog> rootCatalogsForProject([String? projectId]) {
    return List<MediaCatalog>.unmodifiable(
      catalogsForProject(projectId)
          .where((catalog) => catalog.parentId == null)
          .toList(growable: false),
    );
  }

  List<MediaCatalog> childrenOf(String catalogId) {
    final parent = _catalogs[catalogId];
    if (parent == null) {
      return const <MediaCatalog>[];
    }

    final children = _catalogs.values
        .where(
          (catalog) =>
              catalog.projectId == parent.projectId &&
              catalog.parentId == catalogId,
        )
        .toList(growable: false)
      ..sort(_compareCatalogs);

    return List<MediaCatalog>.unmodifiable(children);
  }

  MediaCatalog favoritesCatalogForProject([String? projectId]) {
    _ensureInitialized();
    final resolvedProjectId = projectId ?? activeProjectId;

    final existing = _catalogs.values.where(
      (catalog) =>
          catalog.projectId == resolvedProjectId &&
          catalog.type == CatalogType.favorites,
    );

    if (existing.isNotEmpty) {
      return existing.first;
    }

    return _createFavoritesCatalog(resolvedProjectId);
  }

  List<MediaCatalog> catalogPath(String catalogId) {
    final catalog = _catalogs[catalogId];
    if (catalog == null) {
      return const <MediaCatalog>[];
    }

    final path = <MediaCatalog>[];
    final seen = <String>{};
    MediaCatalog? cursor = catalog;

    while (cursor != null && seen.add(cursor.id)) {
      path.add(cursor);
      final parentId = cursor.parentId;
      cursor = parentId == null ? null : _catalogs[parentId];
    }

    return List<MediaCatalog>.unmodifiable(path.reversed);
  }

  String catalogBreadcrumb(String catalogId) {
    return catalogPath(catalogId).map((catalog) => catalog.name).join(' / ');
  }

  MediaProject createProject(String name) {
    final normalizedName = _cleanName(name, label: 'Project name');
    _ensureProjectNameAvailable(normalizedName);

    final now = DateTime.now().toUtc();
    final project = MediaProject(
      id: _newUuid(),
      name: normalizedName,
      createdAt: now,
      updatedAt: now,
    );

    _projects[project.id] = project;
    _createFavoritesCatalog(project.id);

    _activeProjectId ??= project.id;
    return project;
  }

  void renameProject(String projectId, String name) {
    final project = _requireProject(projectId);
    final normalizedName = _cleanName(name, label: 'Project name');

    _ensureProjectNameAvailable(
      normalizedName,
      excludingProjectId: projectId,
    );

    _projects[projectId] = project.copyWith(
      name: normalizedName,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  void setActiveProject(String projectId) {
    _requireProject(projectId);
    _activeProjectId = projectId;
  }

  void deleteProject(String projectId) {
    _requireProject(projectId);

    if (_projects.length <= 1) {
      throw StateError('MLT Player must keep at least one project.');
    }

    final catalogIds = _catalogs.values
        .where((catalog) => catalog.projectId == projectId)
        .map((catalog) => catalog.id)
        .toSet();

    _memberships.removeWhere(
      (_, membership) =>
          membership.projectId == projectId ||
          catalogIds.contains(membership.catalogId),
    );
    _catalogs.removeWhere((_, catalog) => catalog.projectId == projectId);
    _projects.remove(projectId);

    if (_activeProjectId == projectId) {
      final remaining = projects;
      _activeProjectId = remaining.first.id;
    }
  }

  MediaCatalog createCatalog(
    String name, {
    String? projectId,
    String? parentId,
    String description = '',
  }) {
    _ensureInitialized();
    final resolvedProjectId = projectId ?? activeProjectId;
    _requireProject(resolvedProjectId);

    if (parentId != null) {
      final parent = _requireCatalog(parentId);
      if (parent.projectId != resolvedProjectId) {
        throw ArgumentError(
          'A catalog cannot be nested inside a catalog from another project.',
        );
      }
      if (parent.isFavorites) {
        throw StateError('Favorites cannot contain child catalogs.');
      }
    }

    final normalizedName = _cleanName(name, label: 'Catalog name');
    _ensureCatalogNameAvailable(
      resolvedProjectId,
      parentId,
      normalizedName,
    );

    final now = DateTime.now().toUtc();
    final catalog = MediaCatalog(
      id: _newUuid(),
      projectId: resolvedProjectId,
      name: normalizedName,
      description: description.trim(),
      parentId: parentId,
      type: CatalogType.user,
      createdAt: now,
      updatedAt: now,
    );

    _catalogs[catalog.id] = catalog;
    _touchProject(resolvedProjectId);
    return catalog;
  }

  void renameCatalog(String catalogId, String name) {
    final catalog = _requireCatalog(catalogId);
    if (catalog.isFavorites) {
      throw StateError('The Favorites catalog cannot be renamed.');
    }

    final normalizedName = _cleanName(name, label: 'Catalog name');
    _ensureCatalogNameAvailable(
      catalog.projectId,
      catalog.parentId,
      normalizedName,
      excludingCatalogId: catalog.id,
    );

    _catalogs[catalog.id] = catalog.copyWith(
      name: normalizedName,
      updatedAt: DateTime.now().toUtc(),
    );
    _touchProject(catalog.projectId);
  }

  void setCatalogDescription(String catalogId, String description) {
    final catalog = _requireCatalog(catalogId);
    if (catalog.isFavorites) {
      throw StateError('The Favorites catalog cannot be edited.');
    }

    _catalogs[catalog.id] = catalog.copyWith(
      description: description.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    _touchProject(catalog.projectId);
  }

  void moveCatalog(String catalogId, {String? parentId}) {
    final catalog = _requireCatalog(catalogId);
    if (catalog.isFavorites) {
      throw StateError('The Favorites catalog cannot be moved.');
    }

    if (parentId == catalogId) {
      throw ArgumentError('A catalog cannot be its own parent.');
    }

    if (parentId != null) {
      final parent = _requireCatalog(parentId);
      if (parent.projectId != catalog.projectId) {
        throw ArgumentError(
          'A catalog cannot be moved into another project.',
        );
      }
      if (parent.isFavorites) {
        throw StateError('Favorites cannot contain child catalogs.');
      }

      final descendants = _descendantIds(catalogId);
      if (descendants.contains(parentId)) {
        throw ArgumentError(
          'A catalog cannot be moved inside one of its descendants.',
        );
      }
    }

    _ensureCatalogNameAvailable(
      catalog.projectId,
      parentId,
      catalog.name,
      excludingCatalogId: catalog.id,
    );

    _catalogs[catalog.id] = catalog.copyWith(
      parentId: parentId,
      clearParent: parentId == null,
      updatedAt: DateTime.now().toUtc(),
    );
    _touchProject(catalog.projectId);
  }

  void deleteCatalog(String catalogId) {
    final catalog = _requireCatalog(catalogId);
    if (catalog.isFavorites) {
      throw StateError('The Favorites catalog cannot be deleted.');
    }

    final idsToDelete = <String>{catalogId, ..._descendantIds(catalogId)};

    _memberships.removeWhere(
      (_, membership) => idsToDelete.contains(membership.catalogId),
    );
    _catalogs.removeWhere((id, _) => idsToDelete.contains(id));

    _touchProject(catalog.projectId);
  }

  Set<String> catalogIdsForMedia(
    String mediaPath, {
    String? projectId,
  }) {
    _ensureInitialized();
    final resolvedProjectId = projectId ?? activeProjectId;
    final normalizedPath = _normalizeMediaPath(mediaPath);

    return Set<String>.unmodifiable(
      _memberships.values
          .where(
            (membership) =>
                membership.projectId == resolvedProjectId &&
                membership.mediaPath == normalizedPath,
          )
          .map((membership) => membership.catalogId),
    );
  }

  List<String> mediaPathsForCatalog(String catalogId) {
    final catalog = _requireCatalog(catalogId);

    final paths = _memberships.values
        .where(
          (membership) =>
              membership.projectId == catalog.projectId &&
              membership.catalogId == catalog.id,
        )
        .toList(growable: false)
      ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

    return List<String>.unmodifiable(
      paths.map((membership) => membership.mediaPath),
    );
  }

  int mediaCountForCatalog(String catalogId) {
    return mediaPathsForCatalog(catalogId).length;
  }

  bool isInCatalog(String mediaPath, String catalogId) {
    final catalog = _requireCatalog(catalogId);
    final normalizedPath = _normalizeMediaPath(mediaPath);
    return _memberships.containsKey(
      _membershipKey(catalog.projectId, catalog.id, normalizedPath),
    );
  }

  bool addMediaToCatalog(String mediaPath, String catalogId) {
    final catalog = _requireCatalog(catalogId);
    final normalizedPath = _normalizeMediaPath(mediaPath);
    final key = _membershipKey(
      catalog.projectId,
      catalog.id,
      normalizedPath,
    );

    if (_memberships.containsKey(key)) {
      return false;
    }

    _memberships[key] = CatalogMembership(
      projectId: catalog.projectId,
      catalogId: catalog.id,
      mediaPath: normalizedPath,
      addedAt: DateTime.now().toUtc(),
    );
    _touchProject(catalog.projectId);
    return true;
  }

  bool removeMediaFromCatalog(String mediaPath, String catalogId) {
    final catalog = _requireCatalog(catalogId);
    final normalizedPath = _normalizeMediaPath(mediaPath);
    final removed = _memberships.remove(
      _membershipKey(catalog.projectId, catalog.id, normalizedPath),
    );

    if (removed != null) {
      _touchProject(catalog.projectId);
      return true;
    }
    return false;
  }

  void setMediaCatalogs(
    String mediaPath,
    Iterable<String> catalogIds, {
    String? projectId,
  }) {
    _ensureInitialized();
    final resolvedProjectId = projectId ?? activeProjectId;
    _requireProject(resolvedProjectId);
    final normalizedPath = _normalizeMediaPath(mediaPath);

    final requested = catalogIds.toSet();
    for (final catalogId in requested) {
      final catalog = _requireCatalog(catalogId);
      if (catalog.projectId != resolvedProjectId) {
        throw ArgumentError(
          'Media membership cannot cross project boundaries.',
        );
      }
    }

    final existing = catalogIdsForMedia(
      normalizedPath,
      projectId: resolvedProjectId,
    );

    for (final catalogId in existing.difference(requested)) {
      removeMediaFromCatalog(normalizedPath, catalogId);
    }
    for (final catalogId in requested.difference(existing)) {
      addMediaToCatalog(normalizedPath, catalogId);
    }
  }

  bool isFavorite(
    String mediaPath, {
    String? projectId,
  }) {
    final favorites = favoritesCatalogForProject(projectId);
    return isInCatalog(mediaPath, favorites.id);
  }

  bool setFavorite(
    String mediaPath,
    bool favorite, {
    String? projectId,
  }) {
    final favorites = favoritesCatalogForProject(projectId);
    return favorite
        ? addMediaToCatalog(mediaPath, favorites.id)
        : removeMediaFromCatalog(mediaPath, favorites.id);
  }

  bool toggleFavorite(
    String mediaPath, {
    String? projectId,
  }) {
    final current = isFavorite(mediaPath, projectId: projectId);
    setFavorite(mediaPath, !current, projectId: projectId);
    return !current;
  }

  Future<void> load() async {
    _projects.clear();
    _catalogs.clear();
    _memberships.clear();
    _activeProjectId = null;

    final file = _stateFile;
    if (!await file.exists()) {
      _ensureInitialized();
      return;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        _ensureInitialized();
        return;
      }

      final rawProjects = decoded['projects'];
      if (rawProjects is List) {
        for (final rawProject in rawProjects) {
          final project = MediaProject.fromJson(rawProject);
          if (project != null) {
            _projects[project.id] = project;
          }
        }
      }

      final rawCatalogs = decoded['catalogs'];
      if (rawCatalogs is List) {
        for (final rawCatalog in rawCatalogs) {
          final catalog = MediaCatalog.fromJson(rawCatalog);
          if (catalog != null && _projects.containsKey(catalog.projectId)) {
            _catalogs[catalog.id] = catalog;
          }
        }
      }

      _repairCatalogParents();

      final rawMemberships = decoded['memberships'];
      if (rawMemberships is List) {
        for (final rawMembership in rawMemberships) {
          final membership = CatalogMembership.fromJson(rawMembership);
          if (membership == null) {
            continue;
          }

          final catalog = _catalogs[membership.catalogId];
          if (catalog == null ||
              catalog.projectId != membership.projectId ||
              !_projects.containsKey(membership.projectId)) {
            continue;
          }

          final normalizedPath = _normalizeMediaPath(membership.mediaPath);
          final normalizedMembership = CatalogMembership(
            projectId: membership.projectId,
            catalogId: membership.catalogId,
            mediaPath: normalizedPath,
            addedAt: membership.addedAt,
          );
          _memberships[
              _membershipKey(
                normalizedMembership.projectId,
                normalizedMembership.catalogId,
                normalizedMembership.mediaPath,
              )] = normalizedMembership;
        }
      }

      final rawActiveProjectId = decoded['activeProjectId'];
      if (rawActiveProjectId is String &&
          _projects.containsKey(rawActiveProjectId)) {
        _activeProjectId = rawActiveProjectId;
      }

      _ensureInitialized();
      _ensureFavoritesCatalogs();
    } catch (_) {
      _projects.clear();
      _catalogs.clear();
      _memberships.clear();
      _activeProjectId = null;
      _ensureInitialized();
    }
  }

  Future<void> save() {
    _ensureInitialized();
    _ensureFavoritesCatalogs();

    final projectList = _projects.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    final catalogList = _catalogs.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    final membershipList = _memberships.values.toList(growable: false)
      ..sort((a, b) {
        final projectCompare = a.projectId.compareTo(b.projectId);
        if (projectCompare != 0) {
          return projectCompare;
        }
        final catalogCompare = a.catalogId.compareTo(b.catalogId);
        if (catalogCompare != 0) {
          return catalogCompare;
        }
        return a.mediaPath.compareTo(b.mediaPath);
      });

    final contents = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'version': storageVersion,
        'activeProjectId': activeProjectId,
        'projects': projectList.map((project) => project.toJson()).toList(),
        'catalogs': catalogList.map((catalog) => catalog.toJson()).toList(),
        'memberships': membershipList
            .map((membership) => membership.toJson())
            .toList(),
      },
    );

    final previousWrite = _writeTail;
    _writeTail = () async {
      try {
        await previousWrite;
      } catch (_) {
        // Later saves still run if an earlier write failed.
      }

      await _configDirectory.create(recursive: true);

      final target = _stateFile;
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(target.path);
    }();

    return _writeTail;
  }

  void _ensureInitialized() {
    if (_projects.isEmpty) {
      final project = createProject(defaultProjectName);
      _activeProjectId = project.id;
    }

    if (_activeProjectId == null ||
        !_projects.containsKey(_activeProjectId)) {
      final ordered = _projects.values.toList(growable: false)
        ..sort(
          (a, b) => a.createdAt.compareTo(b.createdAt),
        );
      _activeProjectId = ordered.first.id;
    }

    _ensureFavoritesCatalogs();
  }

  void _ensureFavoritesCatalogs() {
    for (final projectId in _projects.keys.toList(growable: false)) {
      final favorites = _catalogs.values.where(
        (catalog) =>
            catalog.projectId == projectId &&
            catalog.type == CatalogType.favorites,
      );

      if (favorites.isEmpty) {
        _createFavoritesCatalog(projectId);
        continue;
      }

      final keeper = favorites.first;
      for (final duplicate in favorites.skip(1).toList(growable: false)) {
        final duplicateMemberships = _memberships.values
            .where((membership) => membership.catalogId == duplicate.id)
            .toList(growable: false);

        for (final membership in duplicateMemberships) {
          addMediaToCatalog(membership.mediaPath, keeper.id);
          _memberships.remove(
            _membershipKey(
              membership.projectId,
              membership.catalogId,
              membership.mediaPath,
            ),
          );
        }
        _catalogs.remove(duplicate.id);
      }

      if (keeper.parentId != null ||
          keeper.name != favoritesCatalogName ||
          keeper.description.isEmpty) {
        _catalogs[keeper.id] = MediaCatalog(
          id: keeper.id,
          projectId: keeper.projectId,
          name: favoritesCatalogName,
          description: keeper.description.isEmpty
              ? 'Media marked as a favorite in this project.'
              : keeper.description,
          parentId: null,
          type: CatalogType.favorites,
          createdAt: keeper.createdAt,
          updatedAt: keeper.updatedAt,
        );
      }
    }
  }

  MediaCatalog _createFavoritesCatalog(String projectId) {
    final project = _requireProject(projectId);
    final now = DateTime.now().toUtc();

    final favorites = MediaCatalog(
      id: _newUuid(),
      projectId: project.id,
      name: favoritesCatalogName,
      description: 'Media marked as a favorite in this project.',
      parentId: null,
      type: CatalogType.favorites,
      createdAt: now,
      updatedAt: now,
    );

    _catalogs[favorites.id] = favorites;
    return favorites;
  }

  void _repairCatalogParents() {
    final catalogIds = _catalogs.keys.toSet();

    for (final entry in _catalogs.entries.toList(growable: false)) {
      final catalog = entry.value;
      final parentId = catalog.parentId;
      if (parentId == null) {
        continue;
      }

      final parent = _catalogs[parentId];
      if (!catalogIds.contains(parentId) ||
          parent == null ||
          parent.projectId != catalog.projectId ||
          parent.isFavorites ||
          parent.id == catalog.id) {
        _catalogs[catalog.id] = catalog.copyWith(clearParent: true);
      }
    }

    // Break any remaining parent cycles by promoting the first repeated node.
    for (final catalog in _catalogs.values.toList(growable: false)) {
      final seen = <String>{};
      MediaCatalog? cursor = catalog;

      while (cursor != null && cursor.parentId != null) {
        if (!seen.add(cursor.id)) {
          _catalogs[cursor.id] = cursor.copyWith(clearParent: true);
          break;
        }
        cursor = _catalogs[cursor.parentId];
      }
    }
  }

  Set<String> _descendantIds(String catalogId) {
    final descendants = <String>{};
    final pending = <String>[catalogId];

    while (pending.isNotEmpty) {
      final parentId = pending.removeLast();
      for (final catalog in _catalogs.values) {
        if (catalog.parentId == parentId && descendants.add(catalog.id)) {
          pending.add(catalog.id);
        }
      }
    }

    return descendants;
  }

  void _ensureProjectNameAvailable(
    String name, {
    String? excludingProjectId,
  }) {
    final key = name.toLowerCase();
    final conflict = _projects.values.any(
      (project) =>
          project.id != excludingProjectId &&
          project.name.toLowerCase() == key,
    );

    if (conflict) {
      throw ArgumentError('A project named "$name" already exists.');
    }
  }

  void _ensureCatalogNameAvailable(
    String projectId,
    String? parentId,
    String name, {
    String? excludingCatalogId,
  }) {
    final key = name.toLowerCase();

    final conflict = _catalogs.values.any(
      (catalog) =>
          catalog.id != excludingCatalogId &&
          catalog.projectId == projectId &&
          catalog.parentId == parentId &&
          catalog.name.toLowerCase() == key,
    );

    if (conflict) {
      throw ArgumentError(
        'A catalog named "$name" already exists at this level.',
      );
    }
  }

  MediaProject _requireProject(String projectId) {
    final project = _projects[projectId];
    if (project == null) {
      throw ArgumentError('Unknown project: $projectId');
    }
    return project;
  }

  MediaCatalog _requireCatalog(String catalogId) {
    final catalog = _catalogs[catalogId];
    if (catalog == null) {
      throw ArgumentError('Unknown catalog: $catalogId');
    }
    return catalog;
  }

  void _touchProject(String projectId) {
    final project = _projects[projectId];
    if (project == null) {
      return;
    }
    _projects[projectId] = project.copyWith(
      updatedAt: DateTime.now().toUtc(),
    );
  }

  static int _compareCatalogs(MediaCatalog a, MediaCatalog b) {
    if (a.isFavorites != b.isFavorites) {
      return a.isFavorites ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  static String _cleanName(String value, {required String label}) {
    final name = value.trim();
    if (name.isEmpty) {
      throw ArgumentError('$label cannot be empty.');
    }
    return name;
  }

  static String _normalizeMediaPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Media path cannot be empty.');
    }
    return File(trimmed).absolute.path;
  }

  static String _membershipKey(
    String projectId,
    String catalogId,
    String mediaPath,
  ) {
    return '$projectId\u0000$catalogId\u0000$mediaPath';
  }

  static String _newUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    // RFC 4122 version 4 + variant 1 bits.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int value) => value.toRadixString(16).padLeft(2, '0');

    final parts = <String>[
      bytes.sublist(0, 4).map(hex).join(),
      bytes.sublist(4, 6).map(hex).join(),
      bytes.sublist(6, 8).map(hex).join(),
      bytes.sublist(8, 10).map(hex).join(),
      bytes.sublist(10, 16).map(hex).join(),
    ];

    return parts.join('-');
  }

  File get _stateFile => File('${_configDirectory.path}/projects.json');

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
