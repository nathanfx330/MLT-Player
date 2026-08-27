// lib/services/redleaf_project_snapshot_service.dart

import 'dart:convert';
import 'dart:io';

import 'redleaf_catalog_service.dart';
import 'redleaf_srt_service.dart';

class RedleafProjectSnapshot {
  const RedleafProjectSnapshot({
    required this.instanceId,
    required this.syncedAt,
    required this.documents,
    required this.catalogs,
    required this.catalogMemberships,
  });

  final String instanceId;
  final DateTime syncedAt;
  final List<RedleafSrtDocument> documents;
  final List<RedleafCatalog> catalogs;

  /// Redleaf catalog ID -> exact SRT doc_ids belonging to that catalog.
  final Map<int, Set<int>> catalogMemberships;

  int get documentCount => documents.length;

  int get linkedMediaCount =>
      documents.where((document) => document.media.isLinked).length;

  int get transcriptOnlyCount => documents
      .where(
        (document) =>
            document.media.state == RedleafMediaLinkState.notLinked,
      )
      .length;

  Set<int> documentIdsForCatalog(int catalogId) {
    return Set<int>.unmodifiable(
      catalogMemberships[catalogId] ?? const <int>{},
    );
  }
}

class RedleafProjectSnapshotService {
  RedleafProjectSnapshotService({
    Directory? configDirectory,
  }) : _configDirectory =
            configDirectory ?? _defaultConfigDirectory();

  static const int storageVersion = 1;

  final Directory _configDirectory;

  Future<RedleafProjectSnapshot?> load(
    String instanceId,
  ) async {
    final normalizedInstanceId = _cleanInstanceId(instanceId);
    final file = _snapshotFile(normalizedInstanceId);

    if (!await file.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());

      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final version = _readInt(decoded['version']);
      if (version != storageVersion) {
        return null;
      }

      final storedInstanceId =
          decoded['instanceId']?.toString().trim() ?? '';
      if (storedInstanceId != normalizedInstanceId) {
        return null;
      }

      final syncedAt = DateTime.tryParse(
        decoded['syncedAt']?.toString() ?? '',
      )?.toUtc();

      if (syncedAt == null) {
        return null;
      }

      final rawDocuments = decoded['documents'];
      final documents = <RedleafSrtDocument>[];

      if (rawDocuments is List) {
        for (final raw in rawDocuments) {
          final document = _documentFromJson(raw);
          if (document != null) {
            documents.add(document);
          }
        }
      }

      documents.sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
              b.relativePath.toLowerCase(),
            ),
      );

      final rawCatalogs = decoded['catalogs'];
      final catalogs = <RedleafCatalog>[];

      if (rawCatalogs is List) {
        for (final raw in rawCatalogs) {
          final catalog = _catalogFromJson(raw);
          if (catalog != null) {
            catalogs.add(catalog);
          }
        }
      }

      catalogs.sort(
        (a, b) => a.name.toLowerCase().compareTo(
              b.name.toLowerCase(),
            ),
      );

      final knownDocIds =
          documents.map((document) => document.docId).toSet();
      final knownCatalogIds =
          catalogs.map((catalog) => catalog.id).toSet();

      final memberships = <int, Set<int>>{};
      final rawMemberships = decoded['catalogMemberships'];

      if (rawMemberships is Map) {
        for (final entry in rawMemberships.entries) {
          final catalogId = int.tryParse(
            entry.key.toString(),
          );

          if (catalogId == null ||
              !knownCatalogIds.contains(catalogId)) {
            continue;
          }

          final rawDocIds = entry.value;
          if (rawDocIds is! List) {
            continue;
          }

          final docIds = <int>{};
          for (final rawDocId in rawDocIds) {
            final docId = _readInt(rawDocId);
            if (docId != null && knownDocIds.contains(docId)) {
              docIds.add(docId);
            }
          }

          memberships[catalogId] = docIds;
        }
      }

      return RedleafProjectSnapshot(
        instanceId: normalizedInstanceId,
        syncedAt: syncedAt,
        documents: List<RedleafSrtDocument>.unmodifiable(
          documents,
        ),
        catalogs: List<RedleafCatalog>.unmodifiable(
          catalogs,
        ),
        catalogMemberships: Map<int, Set<int>>.unmodifiable(
          <int, Set<int>>{
            for (final entry in memberships.entries)
              entry.key: Set<int>.unmodifiable(entry.value),
          },
        ),
      );
    } catch (_) {
      // A damaged snapshot must never prevent MLT Player from opening.
      // The caller can perform an explicit sync to replace it.
      return null;
    }
  }

  Future<void> save({
    required String instanceId,
    required Iterable<RedleafSrtDocument> documents,
    required Iterable<RedleafCatalog> catalogs,
    required Map<int, Set<int>> catalogMemberships,
    DateTime? syncedAt,
  }) async {
    final normalizedInstanceId = _cleanInstanceId(instanceId);

    final documentList = documents.toList(growable: false)
      ..sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
              b.relativePath.toLowerCase(),
            ),
      );

    final catalogList = catalogs.toList(growable: false)
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(
              b.name.toLowerCase(),
            ),
      );

    final knownDocIds =
        documentList.map((document) => document.docId).toSet();
    final knownCatalogIds =
        catalogList.map((catalog) => catalog.id).toSet();

    final normalizedMemberships = <String, List<int>>{};

    for (final entry in catalogMemberships.entries) {
      if (!knownCatalogIds.contains(entry.key)) {
        continue;
      }

      final docIds = entry.value
          .where(knownDocIds.contains)
          .toSet()
          .toList(growable: false)
        ..sort();

      normalizedMemberships['${entry.key}'] = docIds;
    }

    final contents = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'version': storageVersion,
        'instanceId': normalizedInstanceId,
        'syncedAt':
            (syncedAt ?? DateTime.now()).toUtc().toIso8601String(),
        'documents': documentList
            .map(_documentToJson)
            .toList(growable: false),
        'catalogs': catalogList
            .map(_catalogToJson)
            .toList(growable: false),
        'catalogMemberships': normalizedMemberships,
      },
    );

    final directory = _snapshotDirectory;
    await directory.create(recursive: true);

    final target = _snapshotFile(normalizedInstanceId);
    final temporary = File('${target.path}.tmp');

    await temporary.writeAsString(contents, flush: true);

    if (await target.exists()) {
      await target.delete();
    }

    await temporary.rename(target.path);
  }

  Future<bool> delete(String instanceId) async {
    final normalizedInstanceId = _cleanInstanceId(instanceId);
    final file = _snapshotFile(normalizedInstanceId);

    if (!await file.exists()) {
      return false;
    }

    await file.delete();
    return true;
  }

  File _snapshotFile(String instanceId) {
    final encoded =
        base64Url.encode(utf8.encode(instanceId)).replaceAll('=', '');

    return File(
      '${_snapshotDirectory.path}/$encoded.json',
    );
  }

  Directory get _snapshotDirectory =>
      Directory('${_configDirectory.path}/redleaf_snapshots');

  static Map<String, Object?> _documentToJson(
    RedleafSrtDocument document,
  ) {
    return <String, Object?>{
      'docId': document.docId,
      'relativePath': document.relativePath,
      'status': document.status,
      'statusMessage': document.statusMessage,
      'processedAt': document.processedAt,
      'color': document.color,
      'fileSizeBytes': document.fileSizeBytes,
      'durationSeconds': document.durationSeconds,
      'tagCount': document.tagCount,
      'media': _mediaToJson(document.media),
    };
  }

  static RedleafSrtDocument? _documentFromJson(dynamic raw) {
    if (raw is! Map) {
      return null;
    }

    final docId = _readInt(raw['docId']);
    final relativePath =
        raw['relativePath']?.toString().trim() ?? '';

    if (docId == null || relativePath.isEmpty) {
      return null;
    }

    return RedleafSrtDocument(
      docId: docId,
      relativePath: relativePath,
      status: raw['status']?.toString() ?? '',
      statusMessage: _readOptionalString(
        raw['statusMessage'],
      ),
      processedAt: _readOptionalString(
        raw['processedAt'],
      ),
      color: _readOptionalString(raw['color']),
      fileSizeBytes: _readInt(raw['fileSizeBytes']),
      durationSeconds: _readDouble(
        raw['durationSeconds'],
      ),
      tagCount: _readInt(raw['tagCount']) ?? 0,
      media: _mediaFromJson(raw['media']),
    );
  }

  static Map<String, Object?> _mediaToJson(
    RedleafMediaLink media,
  ) {
    return <String, Object?>{
      'state': media.state.name,
      'path': media.path,
      'type': media.type,
      'source': media.source,
      'positionSeconds': media.positionSeconds,
      'offsetSeconds': media.offsetSeconds,
    };
  }

  static RedleafMediaLink _mediaFromJson(dynamic raw) {
    if (raw is! Map) {
      return const RedleafMediaLink.unknown();
    }

    final stateName =
        raw['state']?.toString().trim() ?? '';

    final state = switch (stateName) {
      'notLinked' => RedleafMediaLinkState.notLinked,
      'linked' => RedleafMediaLinkState.linked,
      _ => RedleafMediaLinkState.unknown,
    };

    if (state == RedleafMediaLinkState.unknown) {
      return const RedleafMediaLink.unknown();
    }

    if (state == RedleafMediaLinkState.notLinked) {
      return const RedleafMediaLink.notLinked();
    }

    return RedleafMediaLink(
      state: RedleafMediaLinkState.linked,
      path: _readOptionalString(raw['path']),
      type: _readOptionalString(raw['type']),
      source: _readOptionalString(raw['source']),
      positionSeconds: _readDouble(
        raw['positionSeconds'],
      ),
      offsetSeconds: _readDouble(
        raw['offsetSeconds'],
      ),
    );
  }

  static Map<String, Object?> _catalogToJson(
    RedleafCatalog catalog,
  ) {
    return <String, Object?>{
      'id': catalog.id,
      'name': catalog.name,
      'type': catalog.type,
    };
  }

  static RedleafCatalog? _catalogFromJson(dynamic raw) {
    if (raw is! Map) {
      return null;
    }

    final id = _readInt(raw['id']);
    final name = raw['name']?.toString().trim() ?? '';

    if (id == null || name.isEmpty) {
      return null;
    }

    return RedleafCatalog(
      id: id,
      name: name,
      type: raw['type']?.toString() ?? '',
    );
  }

  static String _cleanInstanceId(String instanceId) {
    final normalized = instanceId.trim();

    if (normalized.isEmpty) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Redleaf instance ID cannot be empty.',
      );
    }

    return normalized;
  }

  static int? _readInt(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(value?.toString() ?? '');
  }

  static double? _readDouble(dynamic value) {
    if (value is double) {
      return value;
    }

    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(value?.toString() ?? '');
  }

  static String? _readOptionalString(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

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
