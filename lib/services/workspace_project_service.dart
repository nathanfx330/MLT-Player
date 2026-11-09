// lib/services/workspace_project_service.dart

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/workspace_project.dart';
import 'project_catalog_service.dart';
import 'redleaf_connection_service.dart';
import 'redleaf_project_registry_service.dart';

class WorkspaceProjectService extends ChangeNotifier {
  WorkspaceProjectService({
    required ProjectCatalogService localProjects,
    RedleafConnectionService? redleafConnection,
    RedleafProjectRegistryService? redleafProjects,
  })  : _localProjects = localProjects,
        _redleafConnection =
            redleafConnection ?? RedleafConnectionService.instance,
        _redleafProjects =
            redleafProjects ?? RedleafProjectRegistryService() {
    _redleafConnection.addListener(_onRedleafChanged);
    _redleafProjects.addListener(_onRedleafProjectsChanged);
  }

  final ProjectCatalogService _localProjects;
  final RedleafConnectionService _redleafConnection;
  final RedleafProjectRegistryService _redleafProjects;

  bool _loaded = false;
  String? _activeKey;

  bool get loaded => _loaded;

  List<RedleafProjectRecord> get savedRedleafProjects =>
      _loaded ? _redleafProjects.projects : const <RedleafProjectRecord>[];

  List<RedleafProjectRecord> get trashedRedleafProjects =>
      _loaded ? _redleafProjects.trashedProjects : const <RedleafProjectRecord>[];

  RedleafProjectRecord? get connectedRedleafRecord => _loaded &&
          _redleafConnection.isConnected
      ? _redleafProjects.projectByInstanceId(_redleafConnection.instanceId)
      : null;

  String? get activeKey => activeProject?.key;

  WorkspaceProject? get activeProject {
    if (!_loaded) {
      return null;
    }

    final key = _activeKey;
    if (key != null) {
      for (final project in projects) {
        if (project.key == key) {
          return project;
        }
      }
    }

    return WorkspaceProject.local(_localProjects.activeProject);
  }

  bool get activeIsLocal => activeProject?.isLocal ?? true;
  bool get activeIsRedleaf => activeProject?.isRedleaf ?? false;

  List<WorkspaceProject> get projects {
    if (!_loaded) {
      return const <WorkspaceProject>[];
    }

    final result = <WorkspaceProject>[
      for (final project in _localProjects.projects)
        WorkspaceProject.local(project),
    ];

    final redleafByKey = <String, WorkspaceProject>{};

    for (final record in _redleafProjects.projects) {
      final project = WorkspaceProject.redleaf(
        instanceId: record.instanceId,
        name: record.name,
        serverUrl: record.serverUrl,
      );
      redleafByKey[project.key] = project;
    }

    // A newly connected instance is visible immediately, even before its
    // persistence write has completed. If it is already known, the saved
    // MLT Player name wins over Redleaf's source-side project name.
    final connected = redleafProject;
    if (connected != null) {
      redleafByKey[connected.key] = connected;
    }

    final redleafProjects = redleafByKey.values.toList(growable: false)
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(
              b.name.toLowerCase(),
            ),
      );

    result.addAll(redleafProjects);

    return List<WorkspaceProject>.unmodifiable(result);
  }

  /// The Redleaf project represented by the current live connection.
  ///
  /// Its MLT Player display name comes from the persistent registry whenever
  /// this instance has already been remembered.
  WorkspaceProject? get redleafProject {
    if (!_loaded || !_redleafConnection.isConnected) {
      return null;
    }

    final instanceId = _redleafConnection.instanceId.trim();
    if (instanceId.isEmpty) {
      return null;
    }

    final saved = _redleafProjects.projectByInstanceId(instanceId);
    if (saved?.isTrashed == true) return null;
    final sourceProjectName = _redleafConnection.projectName.trim();

    return WorkspaceProject.redleaf(
      instanceId: instanceId,
      name: saved?.name ??
          (sourceProjectName.isEmpty ? 'Redleaf' : sourceProjectName),
      serverUrl: saved?.serverUrl ?? _redleafConnection.serverUrl,
    );
  }

  Future<void> load() async {
    if (_loaded) {
      return;
    }

    await _localProjects.load();
    await _redleafProjects.load();
    await _redleafConnection.load();

    _activeKey = WorkspaceProject.localKey(
      _localProjects.activeProjectId,
    );
    _loaded = true;

    if (_redleafConnection.isConnected) {
      unawaited(_rememberConnectedRedleaf());
    }

    notifyListeners();
  }

  void select(String workspaceProjectKey) {
    _requireLoaded();

    final requested = _projectByKey(workspaceProjectKey);
    if (requested == null) {
      throw ArgumentError.value(
        workspaceProjectKey,
        'workspaceProjectKey',
        'Workspace project is not currently available.',
      );
    }

    if (requested.isLocal) {
      _localProjects.setActiveProject(requested.localProjectId!);
    }

    if (_activeKey == requested.key) {
      return;
    }

    _activeKey = requested.key;
    notifyListeners();
  }

  /// Open the Redleaf workspace for an existing local database.
  /// Does not require the Redleaf server or scan for documents.
  Future<void> selectLocalRedleafProject({
    required String instanceId,
    required String suggestedName,
  }) async {
    _requireLoaded();
    if (_redleafProjects.projectByInstanceId(instanceId)?.isTrashed == true) {
      throw StateError('This Redleaf project is in Trash. Restore it first.');
    }
    await _redleafProjects.rememberLocalProject(
      instanceId: instanceId,
      suggestedName: suggestedName,
    );
    select(WorkspaceProject.redleafKey(instanceId));
  }

  void selectLocalProject(String projectId) {
    select(WorkspaceProject.localKey(projectId));
  }

  /// Select the Redleaf instance that is currently connected.
  ///
  /// Saved Redleaf projects can also be selected directly through [select],
  /// even while disconnected.
  void selectRedleaf() {
    _requireLoaded();

    final redleaf = redleafProject;
    if (redleaf == null) {
      throw StateError(
        'Redleaf must be connected before selecting the live Redleaf project.',
      );
    }

    select(redleaf.key);
  }

  /// Explicitly import the authenticated Redleaf instance as a workspace.
  /// Save its identity before selecting it so the project is available
  /// immediately and survives application restart.
  Future<void> importConnectedRedleafProject({
    String? displayName,
    bool restoreFromTrash = false,
  }) async {
    _requireLoaded();

    if (!_redleafConnection.isConnected) {
      throw StateError('Sign in to a Redleaf server before importing.');
    }

    final instanceId = _redleafConnection.instanceId.trim();
    if (instanceId.isEmpty) {
      throw StateError('The connected Redleaf server has no instance ID.');
    }

    final sourceName = _redleafConnection.projectName.trim();
    final saved = _redleafProjects.projectByInstanceId(instanceId);
    await _redleafProjects.importConnectedProject(
      instanceId: instanceId,
      displayName: displayName ?? saved?.name ??
          (sourceName.isEmpty ? 'Redleaf' : sourceName),
      serverUrl: _redleafConnection.serverUrl,
      sourceProjectName: sourceName.isEmpty ? null : sourceName,
      restoreFromTrash: restoreFromTrash,
    );

    // Sign-in may have changed while the local registry was being saved.
    if (!_redleafConnection.isConnected ||
        _redleafConnection.instanceId != instanceId) {
      throw StateError(
        'The connected Redleaf project changed before import completed.',
      );
    }

    select(WorkspaceProject.redleafKey(instanceId));
  }

  Future<void> trashRedleafProject(String instanceId) async {
    _requireLoaded();
    await _redleafProjects.trashProject(instanceId);
  }

  Future<void> restoreRedleafProject(String instanceId) async {
    _requireLoaded();
    await _redleafProjects.restoreProject(instanceId);
  }

  Future<void> renameRedleafProject(
    String instanceId,
    String name,
  ) async {
    _requireLoaded();

    final normalizedInstanceId = instanceId.trim();
    final key = WorkspaceProject.redleafKey(normalizedInstanceId);
    final project = _projectByKey(key);

    if (project == null || !project.isRedleaf) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Unknown Redleaf workspace project.',
      );
    }

    await _redleafProjects.renameProject(
      normalizedInstanceId,
      name,
    );
  }

  /// Call this after the local project collection is created, renamed,
  /// deleted, or otherwise changed through ProjectCatalogService.
  ///
  /// ProjectCatalogService intentionally remains the sole owner of local
  /// project persistence. This service only keeps the higher-level workspace
  /// selection synchronized with it.
  void synchronizeLocalProjects() {
    if (!_loaded) {
      return;
    }

    final active = activeProject;

    if (active == null || active.isLocal) {
      _activeKey = WorkspaceProject.localKey(
        _localProjects.activeProjectId,
      );
    }

    notifyListeners();
  }

  WorkspaceProject? _projectByKey(String key) {
    for (final project in projects) {
      if (project.key == key) {
        return project;
      }
    }
    return null;
  }

  void _onRedleafChanged() {
    if (!_loaded) {
      return;
    }

    if (_redleafConnection.isConnected) {
      unawaited(_rememberConnectedRedleaf());
    }

    // Disconnecting Redleaf no longer removes the project or forces the
    // workspace back to a local project. The saved Redleaf project remains a
    // first-class workspace project; only its live connection is gone.
    notifyListeners();
  }

  void _onRedleafProjectsChanged() {
    if (!_loaded) {
      return;
    }

    final activeKey = _activeKey;
    if (activeKey != null &&
        activeKey.startsWith('redleaf:') &&
        _projectByKey(activeKey) == null) {
      _activeKey = WorkspaceProject.localKey(
        _localProjects.activeProjectId,
      );
    }

    notifyListeners();
  }

  Future<void> _rememberConnectedRedleaf() async {
    if (!_loaded || !_redleafConnection.isConnected) {
      return;
    }

    final instanceId = _redleafConnection.instanceId.trim();
    if (instanceId.isEmpty) {
      return;
    }

    final sourceProjectName = _redleafConnection.projectName.trim();
    final suggestedName =
        sourceProjectName.isEmpty ? 'Redleaf' : sourceProjectName;

    try {
      await _redleafProjects.rememberConnectedProject(
        instanceId: instanceId,
        suggestedName: suggestedName,
        serverUrl: _redleafConnection.serverUrl,
        sourceProjectName:
            sourceProjectName.isEmpty ? null : sourceProjectName,
      );
    } catch (_) {
      // The live Redleaf session remains usable even if local workspace
      // persistence fails. A later connection can retry remembering it.
    }
  }

  void _requireLoaded() {
    if (!_loaded) {
      throw StateError('WorkspaceProjectService has not been loaded yet.');
    }
  }

  @override
  void dispose() {
    _redleafConnection.removeListener(_onRedleafChanged);
    _redleafProjects.removeListener(_onRedleafProjectsChanged);
    super.dispose();
  }
}
