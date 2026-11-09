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

    test('accepts a Redleaf folder path without an instance ID', () {
      final request = StartupProjectRequest.parse(
        const <String>['--redleaf-project-path', '/home/user/Redleaf Archive'],
      );
      expect(request.redleafProjectPath, '/home/user/Redleaf Archive');
      expect(request.redleafInstanceId, isNull);
      expect(request.error, isNull);

      final equals = StartupProjectRequest.parse(
        const <String>['--redleaf-project-path=/home/user/Archive Two'],
      );
      expect(equals.redleafProjectPath, '/home/user/Archive Two');
    });

    test('rejects duplicate or mixed Redleaf project options', () {
      expect(
        StartupProjectRequest.parse(
          const <String>[
            '--redleaf-project', 'an-id',
            '--redleaf-project-path', '/my/archive',
          ],
        ).error,
        isNotNull,
      );
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project-path'],
        ).error,
        isNotNull,
      );
      expect(
        StartupProjectRequest.parse(
          const <String>['--redleaf-project-path='],
        ).error,
        isNotNull,
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

    test('opens and registers a previously unseen Redleaf folder offline',
        () async {
      final redleafFolder = Directory(
        '${tempDirectory.path}/My Redleaf Archive #1',
      );
      await redleafFolder.create();
      await _createRedleafDatabase(
        redleafFolder,
        instanceId: 'archive-offline-123',
      );

      expect(connection.isConnected, isFalse);
      expect(registry.projectByInstanceId('archive-offline-123'), isNull);

      final request = StartupProjectRequest.parse(
        <String>['--redleaf-project-path', redleafFolder.path],
      );

      expect(await request.applyTo(workspace), isNull);
      expect(workspace.activeKey, 'redleaf:archive-offline-123');
      expect(workspace.activeProject?.isRedleaf, isTrue);
      expect(workspace.activeProject?.name, 'My Redleaf Archive #1');
      expect(connection.isConnected, isFalse);
      expect(
        registry.projectByInstanceId('archive-offline-123')?.name,
        'My Redleaf Archive #1',
      );

      // The identity remains registered after persistence reload.
      final secondRegistry =
          RedleafProjectRegistryService(configDirectory: tempDirectory);
      await secondRegistry.load();
      expect(
        secondRegistry.projectByInstanceId('archive-offline-123')?.name,
        'My Redleaf Archive #1',
      );
      secondRegistry.dispose();
    });

    test('preserves an existing saved project name and server URL',
        () async {
      final redleafFolder = Directory('${tempDirectory.path}/Renamed Folder');
      await redleafFolder.create();
      await _createRedleafDatabase(redleafFolder, instanceId: 'existing-id');

      await registry.rememberConnectedProject(
        instanceId: 'existing-id',
        suggestedName: 'Original Archive',
        serverUrl: 'http://127.0.0.1:5151',
      );
      await registry.renameProject('existing-id', 'Custom MLT Name');

      final request = StartupProjectRequest.parse(
        <String>['--redleaf-project-path', redleafFolder.path],
      );
      expect(await request.applyTo(workspace), isNull);
      final saved = registry.projectByInstanceId('existing-id');
      expect(saved?.name, 'Custom MLT Name');
      expect(saved?.serverUrl, 'http://127.0.0.1:5151');
      expect(workspace.activeKey, 'redleaf:existing-id');
    });

    test('refuses a folder with no database and leaves state unchanged',
        () async {
      final emptyFolder = Directory('${tempDirectory.path}/Empty');
      await emptyFolder.create();
      final originalKey = workspace.activeKey;
      final request = StartupProjectRequest.parse(
        <String>['--redleaf-project-path', emptyFolder.path],
      );

      expect(await request.applyTo(workspace), contains('knowledge_base.db'));
      expect(workspace.activeKey, originalKey);
      expect(registry.projects, isEmpty);
    });

    test('refuses an uninitialized database without writing an identity',
        () async {
      final folder = Directory('${tempDirectory.path}/Uninitialized');
      await folder.create();
      await _createRedleafDatabase(folder);

      final request = StartupProjectRequest.parse(
        <String>['--redleaf-project-path', folder.path],
      );

      expect(await request.applyTo(workspace), contains('no instance ID'));
      expect(workspace.activeProject?.isLocal, isTrue);
      expect(registry.projects, isEmpty);
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

Future<void> _createRedleafDatabase(
  Directory project, {
  String? instanceId,
}) async {
  final databasePath = '${project.path}/knowledge_base.db';
  const script = '''
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)"
)
if len(sys.argv) > 2:
    connection.execute(
        "INSERT INTO app_settings (key, value) VALUES (?, ?)",
        ("instance_id", sys.argv[2])
    )
connection.commit()
connection.close()
''';
  final result = await Process.run('python3', <String>[
    '-c',
    script,
    databasePath,
    if (instanceId != null) instanceId,
  ]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
}
