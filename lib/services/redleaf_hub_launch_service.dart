// lib/services/redleaf_hub_launch_service.dart

import 'redleaf_local_project_service.dart';
import 'redleaf_project_registry_service.dart';
import 'redleaf_project_snapshot_service.dart';
import 'workspace_project_service.dart';

enum RedleafHubLaunchDisposition {
  openCached,
  onboard,
  restore,
}

/// Result of resolving a Hub launch against the local MLT Player registry.
/// Identity comes from the Redleaf database, never from a folder name or an
/// unauthenticated network response.
class RedleafHubLaunchResolution {
  const RedleafHubLaunchResolution({
    required this.instanceId,
    required this.suggestedName,
    required this.disposition,
    this.existingRecord,
  });

  final String instanceId;
  final String suggestedName;
  final RedleafHubLaunchDisposition disposition;
  final RedleafProjectRecord? existingRecord;

  bool get requiresOnboarding =>
      disposition != RedleafHubLaunchDisposition.openCached;
}

class RedleafHubLaunchService {
  RedleafHubLaunchService({
    RedleafLocalProjectService? localProjects,
    RedleafProjectSnapshotService? snapshots,
  })  : _localProjects = localProjects ?? RedleafLocalProjectService(),
        _snapshots = snapshots ?? RedleafProjectSnapshotService();

  final RedleafLocalProjectService _localProjects;
  final RedleafProjectSnapshotService _snapshots;

  /// Read-only inspection: no project is created, selected, renamed, synced,
  /// or restored until the corresponding explicit user action.
  Future<RedleafHubLaunchResolution> inspect({
    required String projectPath,
    required WorkspaceProjectService workspace,
  }) async {
    if (!workspace.loaded) {
      throw StateError('MLT Player must load its project registry first.');
    }

    final local = await _localProjects.read(projectPath);
    final record = workspace.redleafRecordByInstanceId(local.instanceId);

    if (record?.isTrashed == true) {
      return RedleafHubLaunchResolution(
        instanceId: local.instanceId,
        suggestedName: record!.name,
        existingRecord: record,
        disposition: RedleafHubLaunchDisposition.restore,
      );
    }

    // An entry alone is not evidence of a completed sync. Require a valid
    // persistent snapshot for this exact database instance ID.
    final snapshot = record == null ? null : await _snapshots.load(local.instanceId);
    final cached = record != null && snapshot != null;

    return RedleafHubLaunchResolution(
      instanceId: local.instanceId,
      suggestedName: record?.name ?? local.projectName,
      existingRecord: record,
      disposition: cached
          ? RedleafHubLaunchDisposition.openCached
          : RedleafHubLaunchDisposition.onboard,
    );
  }
}
