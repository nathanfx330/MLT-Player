// test/project_catalog_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/project_catalog.dart';
import 'package:mlt_player/services/project_catalog_service.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'mlt_player_project_catalog_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('empty storage creates a default project with Favorites', () async {
    final service = ProjectCatalogService(configDirectory: tempDirectory);

    await service.load();

    expect(service.projects, hasLength(1));
    expect(service.activeProject.name, ProjectCatalogService.defaultProjectName);

    final favorites = service.favoritesCatalogForProject();
    expect(favorites.name, ProjectCatalogService.favoritesCatalogName);
    expect(favorites.type, CatalogType.favorites);
    expect(favorites.parentId, isNull);
  });

  test('catalogs can nest and names are unique only among siblings', () async {
    final service = ProjectCatalogService(configDirectory: tempDirectory);
    await service.load();

    final interviews = service.createCatalog('Interviews');
    final archival = service.createCatalog('Archival');
    final selectedInInterviews = service.createCatalog(
      'Selected',
      parentId: interviews.id,
    );
    final selectedInArchival = service.createCatalog(
      'Selected',
      parentId: archival.id,
    );

    expect(selectedInInterviews.parentId, interviews.id);
    expect(selectedInArchival.parentId, archival.id);

    expect(
      () => service.createCatalog('Selected', parentId: interviews.id),
      throwsArgumentError,
    );

    expect(
      service.catalogBreadcrumb(selectedInInterviews.id),
      'Interviews / Selected',
    );
  });

  test('one media file can belong to many catalogs', () async {
    final service = ProjectCatalogService(configDirectory: tempDirectory);
    await service.load();

    final interviews = service.createCatalog('Interviews');
    final bRoll = service.createCatalog('B-Roll');
    const mediaPath = '/tmp/interview_01.mov';

    expect(service.addMediaToCatalog(mediaPath, interviews.id), isTrue);
    expect(service.addMediaToCatalog(mediaPath, bRoll.id), isTrue);
    expect(service.addMediaToCatalog(mediaPath, bRoll.id), isFalse);

    final memberships = service.catalogIdsForMedia(mediaPath);
    expect(memberships, containsAll(<String>[interviews.id, bRoll.id]));
    expect(memberships, hasLength(2));
  });

  test('Favorites is a project-scoped catalog membership', () async {
    final service = ProjectCatalogService(configDirectory: tempDirectory);
    await service.load();

    const mediaPath = '/tmp/favorite.mov';

    expect(service.isFavorite(mediaPath), isFalse);
    expect(service.toggleFavorite(mediaPath), isTrue);
    expect(service.isFavorite(mediaPath), isTrue);

    final favorites = service.favoritesCatalogForProject();
    expect(service.mediaPathsForCatalog(favorites.id), contains(mediaPath));

    expect(service.toggleFavorite(mediaPath), isFalse);
    expect(service.isFavorite(mediaPath), isFalse);
  });

  test('projects isolate catalogs and memberships', () async {
    final service = ProjectCatalogService(configDirectory: tempDirectory);
    await service.load();

    final firstProject = service.activeProject;
    final firstCatalog = service.createCatalog('Selects');
    const mediaPath = '/tmp/shared.mov';
    service.addMediaToCatalog(mediaPath, firstCatalog.id);

    final secondProject = service.createProject('Second Project');
    service.setActiveProject(secondProject.id);
    final secondCatalog = service.createCatalog('Selects');

    expect(
      service.catalogIdsForMedia(mediaPath),
      isEmpty,
    );

    service.addMediaToCatalog(mediaPath, secondCatalog.id);
    expect(
      service.catalogIdsForMedia(mediaPath),
      <String>{secondCatalog.id},
    );

    service.setActiveProject(firstProject.id);
    expect(
      service.catalogIdsForMedia(mediaPath),
      <String>{firstCatalog.id},
    );
  });

  test('deleting a parent catalog removes descendants and memberships', () async {
    final service = ProjectCatalogService(configDirectory: tempDirectory);
    await service.load();

    final archival = service.createCatalog('Archival');
    final newspapers = service.createCatalog(
      'Newspapers',
      parentId: archival.id,
    );
    final scans = service.createCatalog(
      'Scans',
      parentId: newspapers.id,
    );

    service.addMediaToCatalog('/tmp/a.png', archival.id);
    service.addMediaToCatalog('/tmp/b.png', newspapers.id);
    service.addMediaToCatalog('/tmp/c.png', scans.id);

    service.deleteCatalog(archival.id);

    expect(service.catalogById(archival.id), isNull);
    expect(service.catalogById(newspapers.id), isNull);
    expect(service.catalogById(scans.id), isNull);
    expect(service.catalogIdsForMedia('/tmp/a.png'), isEmpty);
    expect(service.catalogIdsForMedia('/tmp/b.png'), isEmpty);
    expect(service.catalogIdsForMedia('/tmp/c.png'), isEmpty);
  });

  test('catalog state survives a save and reload round trip', () async {
    final first = ProjectCatalogService(configDirectory: tempDirectory);
    await first.load();

    first.renameProject(first.activeProjectId, 'Episode One');
    final interviews = first.createCatalog(
      'Interviews',
      description: 'Recorded interviews',
    );
    final historians = first.createCatalog(
      'Historians',
      parentId: interviews.id,
    );

    const mediaPath = '/tmp/history.mov';
    first.addMediaToCatalog(mediaPath, historians.id);
    first.setFavorite(mediaPath, true);
    await first.save();

    final second = ProjectCatalogService(configDirectory: tempDirectory);
    await second.load();

    expect(second.activeProject.name, 'Episode One');

    final restoredHistorians = second
        .catalogsForProject()
        .where((catalog) => catalog.name == 'Historians')
        .single;

    expect(
      second.catalogBreadcrumb(restoredHistorians.id),
      'Interviews / Historians',
    );
    expect(
      second.mediaPathsForCatalog(restoredHistorians.id),
      contains(mediaPath),
    );
    expect(second.isFavorite(mediaPath), isTrue);
  });

  test('the final project cannot be deleted', () async {
    final service = ProjectCatalogService(configDirectory: tempDirectory);
    await service.load();

    expect(
      () => service.deleteProject(service.activeProjectId),
      throwsStateError,
    );
  });
}
