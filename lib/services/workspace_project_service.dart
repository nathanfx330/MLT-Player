// lib/services/workspace_project_service.dart

import 'package:flutter/foundation.dart';

import '../models/workspace_project.dart';
import 'project_catalog_service.dart';
import 'redleaf_connection_service.dart';

class WorkspaceProjectService extends ChangeNotifier {
  WorkspaceProjectService({
    required ProjectCatalogService localProjects,
    RedleafConnectionService? redleafConnection,
  })  : _localProjects = localProjects,
        _redleafConnection =
            redleafConnection ?? RedleafConnectionService.instance {
    _redleafConnection.addListener(_onRedleafChanged);
  }

  final ProjectCatalogService _localProjects;
  final RedleafConnectionService _redleafConnection;

  bool _loaded = false;
  String? _activeKey;

  bool get loaded => _loaded;

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

    final redleaf = redleafProject;
    if (redleaf != null) {
      result.add(redleaf);
    }

    return List<WorkspaceProject>.unmodifiable(result);
  }

  WorkspaceProject? get redleafProject {
    if (!_loaded || !_redleafConnection.isConnected) {
      return null;
    }

    final instanceId = _redleafConnection.instanceId.trim();
    if (instanceId.isEmpty) {
      return null;
    }

    final projectName = _redleafConnection.projectName.trim();

    return WorkspaceProject.redleaf(
      instanceId: instanceId,
      name: projectName.isEmpty ? 'Redleaf' : projectName,
      serverUrl: _redleafConnection.serverUrl,
    );
  }

  Future<void> load() async {
    if (_loaded) {
      return;
    }

    await _localProjects.load();
    await _redleafConnection.load();

    _activeKey = WorkspaceProject.localKey(
      _localProjects.activeProjectId,
    );
    _loaded = true;
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

  void selectLocalProject(String projectId) {
    select(WorkspaceProject.localKey(projectId));
  }

  void selectRedleaf() {
    _requireLoaded();

    final redleaf = redleafProject;
    if (redleaf == null) {
      throw StateError(
        'Redleaf must be connected before selecting it as a project.',
      );
    }

    select(redleaf.key);
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

    final activeKey = _activeKey;
    final redleaf = redleafProject;

    if (activeKey != null &&
        activeKey.startsWith('redleaf:') &&
        (redleaf == null || redleaf.key != activeKey)) {
      _activeKey = WorkspaceProject.localKey(
        _localProjects.activeProjectId,
      );
    }

    notifyListeners();
  }

  void _requireLoaded() {
    if (!_loaded) {
      throw StateError('WorkspaceProjectService has not been loaded yet.');
    }
  }

  @override
  void dispose() {
    _redleafConnection.removeListener(_onRedleafChanged);
    super.dispose();
  }
}
