// lib/services/redleaf_project_registry_service.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class RedleafProjectRecord {
  const RedleafProjectRecord({
    required this.instanceId,
    required this.name,
    required this.serverUrl,
    required this.createdAt,
    required this.updatedAt,
    this.sourceProjectName,
    this.lastSyncedAt,
  });

  final String instanceId;

  /// User-controlled display name inside MLT Player.
  final String name;

  /// Last known Redleaf server address for this database instance.
  final String serverUrl;

  /// Informational project name reported by Redleaf itself.
  ///
  /// This is deliberately separate from [name]. Renaming the MLT Player
  /// project must never rename anything inside Redleaf.
  final String? sourceProjectName;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastSyncedAt;

  String get workspaceKey => 'redleaf:$instanceId';

  RedleafProjectRecord copyWith({
    String? name,
    String? serverUrl,
    String? sourceProjectName,
    DateTime? updatedAt,
    DateTime? lastSyncedAt,
    bool clearSourceProjectName = false,
    bool clearLastSyncedAt = false,
  }) {
    return RedleafProjectRecord(
      instanceId: instanceId,
      name: name ?? this.name,
      serverUrl: serverUrl ?? this.serverUrl,
      sourceProjectName: clearSourceProjectName
          ? null
          : sourceProjectName ?? this.sourceProjectName,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastSyncedAt:
          clearLastSyncedAt ? null : lastSyncedAt ?? this.lastSyncedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'instanceId': instanceId,
      'name': name,
      'serverUrl': serverUrl,
      'sourceProjectName': sourceProjectName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'lastSyncedAt': lastSyncedAt?.toUtc().toIso8601String(),
    };
  }

  static RedleafProjectRecord? fromJson(dynamic raw) {
    if (raw is! Map) {
      return null;
    }

    final instanceId = raw['instanceId']?.toString().trim() ?? '';
    final name = raw['name']?.toString().trim() ?? '';
    final serverUrl = raw['serverUrl']?.toString().trim() ?? '';

    if (instanceId.isEmpty || name.isEmpty || serverUrl.isEmpty) {
      return null;
    }

    final createdAt = DateTime.tryParse(
      raw['createdAt']?.toString() ?? '',
    );
    final updatedAt = DateTime.tryParse(
      raw['updatedAt']?.toString() ?? '',
    );

    if (createdAt == null || updatedAt == null) {
      return null;
    }

    final rawSourceName = raw['sourceProjectName']?.toString().trim();
    final rawLastSyncedAt = raw['lastSyncedAt']?.toString().trim();

    return RedleafProjectRecord(
      instanceId: instanceId,
      name: name,
      serverUrl: serverUrl,
      sourceProjectName:
          rawSourceName == null || rawSourceName.isEmpty ? null : rawSourceName,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      lastSyncedAt: rawLastSyncedAt == null || rawLastSyncedAt.isEmpty
          ? null
          : DateTime.tryParse(rawLastSyncedAt)?.toUtc(),
    );
  }
}

class RedleafProjectRegistryService extends ChangeNotifier {
  RedleafProjectRegistryService({
    Directory? configDirectory,
  }) : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  static const int storageVersion = 1;

  final Directory _configDirectory;
  final Map<String, RedleafProjectRecord> _records =
      <String, RedleafProjectRecord>{};

  Future<void> _writeTail = Future<void>.value();
  bool _loaded = false;

  bool get loaded => _loaded;

  List<RedleafProjectRecord> get projects {
    final values = _records.values.toList(growable: false)
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(
              b.name.toLowerCase(),
            ),
      );
    return List<RedleafProjectRecord>.unmodifiable(values);
  }

  RedleafProjectRecord? projectByInstanceId(String instanceId) {
    return _records[instanceId.trim()];
  }

  Future<void> load() async {
    if (_loaded) {
      return;
    }

    _records.clear();

    final file = _stateFile;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());

        if (decoded is Map<String, dynamic>) {
          final rawProjects = decoded['projects'];
          if (rawProjects is List) {
            for (final raw in rawProjects) {
              final record = RedleafProjectRecord.fromJson(raw);
              if (record != null) {
                _records[record.instanceId] = record;
              }
            }
          }
        }
      } catch (_) {
        // A damaged registry must not prevent MLT Player from launching.
        // Leave the registry empty and allow the next successful Redleaf
        // connection to recreate its project record.
        _records.clear();
      }
    }

    _loaded = true;
    notifyListeners();
  }

  Future<RedleafProjectRecord> rememberConnectedProject({
    required String instanceId,
    required String suggestedName,
    required String serverUrl,
    String? sourceProjectName,
  }) async {
    _requireLoaded();

    final normalizedInstanceId = _cleanRequired(
      instanceId,
      label: 'Redleaf instance ID',
    );
    final normalizedServerUrl = _cleanRequired(
      serverUrl,
      label: 'Redleaf server URL',
    );
    final normalizedSuggestedName = _cleanRequired(
      suggestedName,
      label: 'Redleaf project name',
    );
    final normalizedSourceName = sourceProjectName?.trim();

    final now = DateTime.now().toUtc();
    final existing = _records[normalizedInstanceId];

    final record = existing == null
        ? RedleafProjectRecord(
            instanceId: normalizedInstanceId,
            name: _uniqueName(normalizedSuggestedName),
            serverUrl: normalizedServerUrl,
            sourceProjectName:
                normalizedSourceName == null || normalizedSourceName.isEmpty
                    ? null
                    : normalizedSourceName,
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(
            serverUrl: normalizedServerUrl,
            sourceProjectName:
                normalizedSourceName == null || normalizedSourceName.isEmpty
                    ? existing.sourceProjectName
                    : normalizedSourceName,
            updatedAt: now,
          );

    _records[normalizedInstanceId] = record;
    notifyListeners();
    await save();
    return record;
  }

  Future<RedleafProjectRecord> renameProject(
    String instanceId,
    String name,
  ) async {
    _requireLoaded();

    final normalizedInstanceId = instanceId.trim();
    final existing = _records[normalizedInstanceId];
    if (existing == null) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Unknown Redleaf project.',
      );
    }

    final normalizedName = _cleanRequired(
      name,
      label: 'Project name',
    );

    _ensureNameAvailable(
      normalizedName,
      excludingInstanceId: normalizedInstanceId,
    );

    final renamed = existing.copyWith(
      name: normalizedName,
      updatedAt: DateTime.now().toUtc(),
    );

    _records[normalizedInstanceId] = renamed;
    notifyListeners();
    await save();
    return renamed;
  }

  Future<RedleafProjectRecord> markSynced(
    String instanceId, {
    DateTime? syncedAt,
  }) async {
    _requireLoaded();

    final normalizedInstanceId = instanceId.trim();
    final existing = _records[normalizedInstanceId];
    if (existing == null) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Unknown Redleaf project.',
      );
    }

    final now = DateTime.now().toUtc();
    final updated = existing.copyWith(
      updatedAt: now,
      lastSyncedAt: (syncedAt ?? now).toUtc(),
    );

    _records[normalizedInstanceId] = updated;
    notifyListeners();
    await save();
    return updated;
  }

  Future<bool> forgetProject(String instanceId) async {
    _requireLoaded();

    final removed = _records.remove(instanceId.trim());
    if (removed == null) {
      return false;
    }

    notifyListeners();
    await save();
    return true;
  }

  Future<void> save() {
    _requireLoaded();

    final ordered = _records.values.toList(growable: false)
      ..sort((a, b) => a.instanceId.compareTo(b.instanceId));

    final contents = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'version': storageVersion,
        'projects': ordered.map((record) => record.toJson()).toList(),
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

      if (await target.exists()) {
        await target.delete();
      }
      await temporary.rename(target.path);
    }();

    return _writeTail;
  }

  String _uniqueName(String preferred) {
    if (_nameAvailable(preferred)) {
      return preferred;
    }

    for (var index = 2; index < 10000; index++) {
      final candidate = '$preferred $index';
      if (_nameAvailable(candidate)) {
        return candidate;
      }
    }

    throw StateError('Could not create a unique Redleaf project name.');
  }

  void _ensureNameAvailable(
    String name, {
    String? excludingInstanceId,
  }) {
    if (_nameAvailable(
      name,
      excludingInstanceId: excludingInstanceId,
    )) {
      return;
    }

    throw ArgumentError.value(
      name,
      'name',
      'Another Redleaf project already uses this name.',
    );
  }

  bool _nameAvailable(
    String name, {
    String? excludingInstanceId,
  }) {
    final normalized = name.toLowerCase();

    return !_records.values.any(
      (record) =>
          record.instanceId != excludingInstanceId &&
          record.name.toLowerCase() == normalized,
    );
  }

  static String _cleanRequired(
    String value, {
    required String label,
  }) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('$label cannot be empty.');
    }
    return normalized;
  }

  void _requireLoaded() {
    if (!_loaded) {
      throw StateError(
        'RedleafProjectRegistryService has not been loaded yet.',
      );
    }
  }

  File get _stateFile =>
      File('${_configDirectory.path}/redleaf_projects.json');

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
