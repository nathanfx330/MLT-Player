// test/startup_project_request_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/project_catalog_service.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/redleaf_project_registry_service.dart';
import 'package:mlt_player/services/startup_project_request.dart';
import 'package:mlt_player/services/workspace_project_service.dart';

void main() {
  group('Redleaf Hub startup arguments', () {
    test('normal launch does not request a workspace', () {
      final request = StartupProjectRequest.parse(const <String>[]);
      expect(request.redleafInstanceId, isNull);
      expect(request.error, isNull);
    });

    test('accepts raw IDs, namespaced keys and equals syntax', () {
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project', 'archive-123'],
        ).redleafInstanceId,
        'archive-123',
      );
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project=redleaf:archive-123'],
        ).redleafInstanceId,
        'archive-123',
      );
    });

    test('rejects missing, blank and duplicate project options', () {
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project'],
        ).error,
        isNotNull,
      );
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project='],
        ).error,
        isNotNull,
      );
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project', '--unknown'],
        ).error,
        isNotNull,
      );
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project', 'a', '--redleaf-project=b'],
        ).error,
        isNotNull,
      );
    });
  });

  group('Redleaf Hub startup selection', () {
    late Directory tempDirectory;
    late ProjectCatalogService localProjects;
    late RedleafConnectionService connection;
    late RedleafProjectRegistryService registry;
    late WorkspaceProjectService workspace;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_player_hub_launch_test_',
      );
      localProjects = ProjectCatalogService(configDirectory: tempDirectory);
      connection = RedleafConnectionService(configDirectory: tempDirectory);
      registry = RedleafProjectRegistryService(configDirectory: tempDirectory);
      workspace = WorkspaceProjectService(
        localProjects: localProjects,
        redleafConnection: connection,
        redleafProjects: registry,
      );
      await workspace.load();
    });

    tearDown(() async {
      workspace.dispose();
      registry.dispose();
      connection.dispose();
      await tempDirectory.delete(recursive: true);
    });

    test('selects only the exact saved Redleaf workspace while offline',
        () async {
      await registry.rememberConnectedProject(
        instanceId: 'correct-instance',
        suggestedName: 'Archive A',
        serverUrl: 'http://127.0.0.1:5000',
      );
      await registry.rememberConnectedProject(
        instanceId: 'another-instance',
        suggestedName: 'Archive B',
        serverUrl: 'http://127.0.0.1:5001',
      );

      final originalLocalProjectId = localProjects.activeProjectId;
      final request = StartupProjectRequest.parse(
        const <String>['--redleaf-project', 'correct-instance'],
      );

      expect(request.selectIn(workspace), isNull);
      expect(workspace.activeKey, 'redleaf:correct-instance');
      expect(workspace.activeProject?.isRedleaf, isTrue);
      expect(localProjects.activeProjectId, originalLocalProjectId);
      expect(connection.isConnected, isFalse);
    });

    test('unknown instance does not switch to a different project', () {
      final originalKey = workspace.activeKey;
      final request = StartupProjectRequest.parse(
        const <String>['--redleaf-project', 'not-registered'],
      );

      expect(request.selectIn(workspace), contains('not saved'));
      expect(workspace.activeKey, originalKey);
    });

    test('normal and malformed launch preserve the selected project', () {
      final originalKey = workspace.activeKey;
      expect(
        StartupProjectRequest.parse(const <String>[]).selectIn(workspace),
        isNull,
      );
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project'],
        ).selectIn(workspace),
        isNotNull,
      );
      expect(workspace.activeKey, originalKey);
    });
  });
}
