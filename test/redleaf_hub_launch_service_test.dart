// test/redleaf_hub_launch_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/project_catalog_service.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/redleaf_hub_launch_service.dart';
import 'package:mlt_player/services/redleaf_local_project_service.dart';
import 'package:mlt_player/services/redleaf_project_registry_service.dart';
import 'package:mlt_player/services/redleaf_project_snapshot_service.dart';
import 'package:mlt_player/services/workspace_project_service.dart';

class _LocalIdentity extends RedleafLocalProjectService {
  @override
  Future<RedleafLocalProjectIdentity> read(String rawProjectPath) async {
    if (rawProjectPath != '/hub/archives/my-project') {
      throw const RedleafLocalProjectException('Unexpected project path.');
    }
    return const RedleafLocalProjectIdentity(
      instanceId: 'remote-instance-1',
      projectName: 'Project from Hub',
    );
  }
}

class _Snapshots extends RedleafProjectSnapshotService {
  bool synced = false;

  @override
  Future<RedleafProjectSnapshot?> load(String instanceId) async {
    if (!synced || instanceId != 'remote-instance-1') return null;
    return RedleafProjectSnapshot(
      instanceId: instanceId,
      syncedAt: DateTime.utc(2026, 11, 9),
      documents: const [],
      catalogs: const [],
      catalogMemberships: const {},
    );
  }
}

void main() {
  late Directory tempDirectory;
  late RedleafProjectRegistryService registry;
  late RedleafConnectionService connection;
  late WorkspaceProjectService workspace;
  late _Snapshots snapshots;
  late RedleafHubLaunchService launcher;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('hub_launch_');
    registry = RedleafProjectRegistryService(configDirectory: tempDirectory);
    connection = RedleafConnectionService(configDirectory: tempDirectory);
    workspace = WorkspaceProjectService(
      localProjects: ProjectCatalogService(configDirectory: tempDirectory),
      redleafConnection: connection,
      redleafProjects: registry,
    );
    await workspace.load();
    snapshots = _Snapshots();
    launcher = RedleafHubLaunchService(
      localProjects: _LocalIdentity(),
      snapshots: snapshots,
    );
  });

  tearDown(() async {
    workspace.dispose();
    registry.dispose();
    connection.dispose();
    await tempDirectory.delete(recursive: true);
  });

  Future<RedleafHubLaunchResolution> resolve() => launcher.inspect(
        projectPath: '/hub/archives/my-project',
        workspace: workspace,
      );

  test('new Hub project requires onboarding and is not auto-registered',
      () async {
    final original = workspace.activeKey;
    final result = await resolve();

    expect(result.disposition, RedleafHubLaunchDisposition.onboard);
    expect(result.suggestedName, 'Project from Hub');
    expect(result.instanceId, 'remote-instance-1');
    expect(result.existingRecord, isNull);
    expect(workspace.activeKey, original);
    expect(registry.projects, isEmpty);
    expect(connection.isConnected, isFalse);
  });

  test('registered but never synced still requires onboarding', () async {
    await registry.rememberConnectedProject(
      instanceId: 'remote-instance-1',
      suggestedName: 'Custom MLT Name',
      serverUrl: 'http://127.0.0.1:5000',
    );
    final result = await resolve();
    expect(result.disposition, RedleafHubLaunchDisposition.onboard);
    expect(result.suggestedName, 'Custom MLT Name');
    expect(result.hasCachedSnapshot, isFalse);
  });

  test('saved entry plus valid snapshot opens the cached project', () async {
    await registry.rememberConnectedProject(
      instanceId: 'remote-instance-1',
      suggestedName: 'Research Name',
      serverUrl: 'http://127.0.0.1:5000',
    );
    snapshots.synced = true;

    final before = workspace.activeKey;
    final result = await resolve();
    expect(result.disposition, RedleafHubLaunchDisposition.openCached);
    expect(result.suggestedName, 'Research Name');
    expect(result.hasCachedSnapshot, isTrue);
    expect(workspace.activeKey, before);
    expect(connection.isConnected, isFalse);
  });

  test('a trashed synced project requires explicit restoration', () async {
    await registry.rememberConnectedProject(
      instanceId: 'remote-instance-1',
      suggestedName: 'Retired Archive',
      serverUrl: 'http://127.0.0.1:5000',
    );
    await registry.trashProject('remote-instance-1');
    snapshots.synced = true;

    final result = await resolve();
    expect(result.disposition, RedleafHubLaunchDisposition.restore);
    expect(result.suggestedName, 'Retired Archive');
    expect(result.hasCachedSnapshot, isTrue);
    expect(registry.projects, isEmpty);
    expect(registry.trashedProjects, hasLength(1));
  });

  test('a trashed unsynced project cannot be silently recreated', () async {
    await registry.rememberConnectedProject(
      instanceId: 'remote-instance-1',
      suggestedName: 'Retired Archive',
      serverUrl: 'http://127.0.0.1:5000',
    );
    await registry.trashProject('remote-instance-1');

    final result = await resolve();
    expect(result.disposition, RedleafHubLaunchDisposition.restore);
    expect(result.hasCachedSnapshot, isFalse);
    expect(registry.projects, isEmpty);
  });
}
