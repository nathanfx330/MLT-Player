// test/redleaf_project_trash_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_project_registry_service.dart';

void main() {
  late Directory home;
  late RedleafProjectRegistryService registry;

  setUp(() async {
    home = await Directory.systemTemp.createTemp(
      'mlt_player_redleaf_project_trash_test_',
    );
    registry = RedleafProjectRegistryService(configDirectory: home);
    await registry.load();
  });

  tearDown(() async {
    registry.dispose();
    await home.delete(recursive: true);
  });

  Future<void> create(
    String id,
    String name, {
    String url = 'http://127.0.0.1:5000',
  }) async {
    await registry.importConnectedProject(
      instanceId: id,
      displayName: name,
      serverUrl: url,
    );
  }

  test('Trash hides the project without deleting its ID or cached files',
      () async {
    await create('a', 'Research A');

    final snapshotDirectory = Directory('${home.path}/redleaf_snapshots');
    await snapshotDirectory.create();
    final sentinel = File('${snapshotDirectory.path}/keep-me.txt');
    await sentinel.writeAsString('cached');

    await registry.trashProject('a');

    expect(registry.projects, isEmpty);
    expect(registry.trashedProjects, hasLength(1));
    expect(registry.trashedProjects.single.isTrashed, isTrue);
    expect(registry.projectByInstanceId('a')?.name, 'Research A');
    expect(await sentinel.readAsString(), 'cached');

    final restarted =
        RedleafProjectRegistryService(configDirectory: home);
    await restarted.load();
    expect(restarted.projects, isEmpty);
    expect(restarted.trashedProjects.single.instanceId, 'a');

    await restarted.restoreProject('a');
    expect(restarted.projects.single.name, 'Research A');
    expect(restarted.trashedProjects, isEmpty);
    expect(await sentinel.readAsString(), 'cached');
    restarted.dispose();
  });

  test('reconnecting does not silently restore a trashed project', () async {
    await create('a', 'Archive');
    await registry.trashProject('a');

    await registry.rememberConnectedProject(
      instanceId: 'a',
      suggestedName: 'Changed Remote Name',
      serverUrl: 'http://127.0.0.1:5151',
    );

    expect(registry.projects, isEmpty);
    expect(registry.trashedProjects.single.name, 'Archive');
    expect(
      registry.trashedProjects.single.serverUrl,
      'http://127.0.0.1:5151',
    );
  });

  test('importing an ID in Trash must restore the same workspace', () async {
    await create('a', 'Archive');
    final initial = registry.projectByInstanceId('a')!;
    await registry.trashProject('a');

    await expectLater(
      registry.importConnectedProject(
        instanceId: 'a',
        displayName: 'Second Archive',
        serverUrl: 'http://127.0.0.1:5000',
      ),
      throwsA(isA<StateError>()),
    );

    expect(registry.projects, isEmpty);
    expect(registry.trashedProjects, hasLength(1));

    final restored = await registry.importConnectedProject(
      instanceId: 'a',
      displayName: 'Second Archive',
      serverUrl: 'http://127.0.0.1:5000',
      restoreFromTrash: true,
    );
    expect(restored.instanceId, initial.instanceId);
    expect(restored.createdAt, initial.createdAt);
    expect(restored.name, 'Second Archive');
    expect(restored.isTrashed, isFalse);
    expect(registry.projects, hasLength(1));
    expect(registry.trashedProjects, isEmpty);
  });

  test('name conflicts detect both saved and trashed projects', () async {
    await create('a', 'Common Name');
    await create('b', 'Other Archive');

    await expectLater(
      registry.importConnectedProject(
        instanceId: 'c',
        displayName: 'common name',
        serverUrl: 'http://127.0.0.1:5000',
      ),
      throwsA(isA<ArgumentError>()),
    );

    await registry.trashProject('a');

    await expectLater(
      registry.importConnectedProject(
        instanceId: 'c',
        displayName: 'COMMON NAME',
        serverUrl: 'http://127.0.0.1:5000',
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.toString(),
          'message',
          contains('Trash'),
        ),
      ),
    );

    expect(registry.projectByInstanceId('c'), isNull);
    expect(registry.trashedProjects, hasLength(1));
    expect(registry.projects, hasLength(1));
  });

  test('Empty Trash permanently removes trashed records only', () async {
    await create('trashed-1', 'Old Archive');
    await create('active-1', 'Current Archive');
    await create('trashed-2', 'Retired Archive');

    await registry.trashProject('trashed-1');
    await registry.trashProject('trashed-2');

    expect(registry.projects, hasLength(1));
    expect(registry.trashedProjects, hasLength(2));

    final removed = await registry.emptyTrash();

    expect(removed, 2);
    expect(registry.trashedProjects, isEmpty);
    expect(registry.projectByInstanceId('trashed-1'), isNull);
    expect(registry.projectByInstanceId('trashed-2'), isNull);
    expect(registry.projects.single.instanceId, 'active-1');
    expect(await registry.emptyTrash(), 0);

    final reopened = RedleafProjectRegistryService(configDirectory: home);
    await reopened.load();
    expect(reopened.trashedProjects, isEmpty);
    expect(reopened.projects.single.instanceId, 'active-1');
    reopened.dispose();
  });

  test('Empty Trash releases names and IDs for later explicit import',
      () async {
    await create('old-id', 'My Research');
    final original = registry.projectByInstanceId('old-id')!;
    await registry.trashProject('old-id');

    expect(await registry.emptyTrash(), 1);
    expect(registry.projectByInstanceId('old-id'), isNull);

    await create('different-id', 'My Research');
    expect(registry.projects.single.name, 'My Research');

    // Removing the original record also removes its original timestamps.
    await create('old-id', 'New Archive');
    final recreated = registry.projectByInstanceId('old-id')!;
    expect(recreated.instanceId, original.instanceId);
    expect(recreated.name, 'New Archive');
    expect(recreated.isTrashed, isFalse);
    expect(registry.projects, hasLength(2));
  });

  test('Empty Trash never deletes Redleaf source or cached files', () async {
    await create('cached-id', 'Cached Archive');
    final database = File('${home.path}/knowledge_base.db');
    await database.writeAsString('source database preserved');
    final snapshots = Directory('${home.path}/redleaf_snapshots');
    await snapshots.create(recursive: true);
    final snapshot = File('${snapshots.path}/cached-id.json');
    await snapshot.writeAsString('cached transcript');

    await registry.trashProject('cached-id');
    expect(await registry.emptyTrash(), 1);

    expect(await database.readAsString(), 'source database preserved');
    expect(await snapshot.readAsString(), 'cached transcript');
    expect(registry.trashedProjects, isEmpty);
    expect(registry.projects, isEmpty);
  });

  test('older registry JSON without a Trash field remains active', () async {
    await create('legacy-id', 'Old Archive');

    // Simulate an older saved registry version with no Trash metadata.
    final savedFile = File('${home.path}/redleaf_projects.json');
    final json = jsonDecode(await savedFile.readAsString())
        as Map<String, dynamic>;
    final saved = (json['projects'] as List<dynamic>).first
        as Map<String, dynamic>;
    saved.remove('trashedAt');
    await savedFile.writeAsString(jsonEncode(json));

    final reopened =
        RedleafProjectRegistryService(configDirectory: home);
    await reopened.load();

    expect(reopened.projects.single.name, 'Old Archive');
    expect(reopened.projects.single.isTrashed, isFalse);
    expect(reopened.trashedProjects, isEmpty);
    reopened.dispose();
  });
}
