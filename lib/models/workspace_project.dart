// lib/models/workspace_project.dart

import 'project_catalog.dart';

enum WorkspaceProjectKind {
  local,
  redleaf,
}

class WorkspaceProject {
  const WorkspaceProject._({
    required this.key,
    required this.name,
    required this.kind,
    this.localProjectId,
    this.redleafInstanceId,
    this.redleafServerUrl,
  });

  factory WorkspaceProject.local(MediaProject project) {
    return WorkspaceProject._(
      key: localKey(project.id),
      name: project.name,
      kind: WorkspaceProjectKind.local,
      localProjectId: project.id,
    );
  }

  factory WorkspaceProject.redleaf({
    required String instanceId,
    required String name,
    required String serverUrl,
  }) {
    final normalizedInstanceId = instanceId.trim();
    final normalizedName = name.trim();
    final normalizedServerUrl = serverUrl.trim();

    if (normalizedInstanceId.isEmpty) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Redleaf project identity cannot be empty.',
      );
    }

    if (normalizedName.isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'Redleaf project name cannot be empty.',
      );
    }

    if (normalizedServerUrl.isEmpty) {
      throw ArgumentError.value(
        serverUrl,
        'serverUrl',
        'Redleaf server URL cannot be empty.',
      );
    }

    return WorkspaceProject._(
      key: redleafKey(normalizedInstanceId),
      name: normalizedName,
      kind: WorkspaceProjectKind.redleaf,
      redleafInstanceId: normalizedInstanceId,
      redleafServerUrl: normalizedServerUrl,
    );
  }

  final String key;
  final String name;
  final WorkspaceProjectKind kind;

  final String? localProjectId;
  final String? redleafInstanceId;
  final String? redleafServerUrl;

  bool get isLocal => kind == WorkspaceProjectKind.local;
  bool get isRedleaf => kind == WorkspaceProjectKind.redleaf;

  String get sourceId {
    return switch (kind) {
      WorkspaceProjectKind.local => localProjectId!,
      WorkspaceProjectKind.redleaf => redleafInstanceId!,
    };
  }

  static String localKey(String projectId) {
    final normalized = projectId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        projectId,
        'projectId',
        'Local project identity cannot be empty.',
      );
    }
    return 'local:$normalized';
  }

  static String redleafKey(String instanceId) {
    final normalized = instanceId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Redleaf instance identity cannot be empty.',
      );
    }
    return 'redleaf:$normalized';
  }
}
