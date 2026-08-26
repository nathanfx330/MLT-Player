// lib/models/project_catalog.dart

enum CatalogType {
  user,
  favorites,
  podcast,
}

String catalogTypeToStorage(CatalogType type) {
  return switch (type) {
    CatalogType.user => 'user',
    CatalogType.favorites => 'favorites',
    CatalogType.podcast => 'podcast',
  };
}

CatalogType catalogTypeFromStorage(Object? value) {
  return switch (value) {
    'favorites' => CatalogType.favorites,
    'podcast' => CatalogType.podcast,
    _ => CatalogType.user,
  };
}

class MediaProject {
  const MediaProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  MediaProject copyWith({
    String? name,
    DateTime? updatedAt,
  }) {
    return MediaProject(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  static MediaProject? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }

    final id = value['id'];
    final name = value['name'];
    final createdAt = DateTime.tryParse(value['createdAt']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(value['updatedAt']?.toString() ?? '');

    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }

    return MediaProject(
      id: id,
      name: name.trim(),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class MediaCatalog {
  const MediaCatalog({
    required this.id,
    required this.projectId,
    required this.name,
    required this.description,
    required this.parentId,
    required this.type,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String name;
  final String description;
  final String? parentId;
  final CatalogType type;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isFavorites => type == CatalogType.favorites;

  MediaCatalog copyWith({
    String? name,
    String? description,
    String? parentId,
    bool clearParent = false,
    DateTime? updatedAt,
  }) {
    return MediaCatalog(
      id: id,
      projectId: projectId,
      name: name ?? this.name,
      description: description ?? this.description,
      parentId: clearParent ? null : (parentId ?? this.parentId),
      type: type,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'projectId': projectId,
      'name': name,
      'description': description,
      'parentId': parentId,
      'catalogType': catalogTypeToStorage(type),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  static MediaCatalog? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }

    final id = value['id'];
    final projectId = value['projectId'];
    final name = value['name'];
    final description = value['description'];
    final rawParentId = value['parentId'];
    final createdAt = DateTime.tryParse(value['createdAt']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(value['updatedAt']?.toString() ?? '');

    if (id is! String ||
        id.trim().isEmpty ||
        projectId is! String ||
        projectId.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }

    return MediaCatalog(
      id: id,
      projectId: projectId,
      name: name.trim(),
      description: description is String ? description.trim() : '',
      parentId: rawParentId is String && rawParentId.trim().isNotEmpty
          ? rawParentId.trim()
          : null,
      type: catalogTypeFromStorage(value['catalogType']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class CatalogMembership {
  const CatalogMembership({
    required this.projectId,
    required this.catalogId,
    required this.mediaPath,
    required this.addedAt,
  });

  final String projectId;
  final String catalogId;
  final String mediaPath;
  final DateTime addedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'projectId': projectId,
      'catalogId': catalogId,
      'mediaPath': mediaPath,
      'addedAt': addedAt.toUtc().toIso8601String(),
    };
  }

  static CatalogMembership? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }

    final projectId = value['projectId'];
    final catalogId = value['catalogId'];
    final mediaPath = value['mediaPath'];
    final addedAt = DateTime.tryParse(value['addedAt']?.toString() ?? '');

    if (projectId is! String ||
        projectId.trim().isEmpty ||
        catalogId is! String ||
        catalogId.trim().isEmpty ||
        mediaPath is! String ||
        mediaPath.trim().isEmpty ||
        addedAt == null) {
      return null;
    }

    return CatalogMembership(
      projectId: projectId.trim(),
      catalogId: catalogId.trim(),
      mediaPath: mediaPath.trim(),
      addedAt: addedAt,
    );
  }
}
