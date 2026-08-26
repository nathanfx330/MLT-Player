// test/project_page_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/project_catalog_service.dart';
import 'package:mlt_player/services/project_media_metadata_service.dart';
import 'package:mlt_player/ui/project_page.dart';

void main() {
  testWidgets('ProjectPage renders live project summaries', (tester) async {
    // This is deliberately an in-memory widget test. The services only need a
    // configDirectory when load/save is called, so avoiding filesystem I/O here
    // keeps Flutter's fake test clock from waiting on unrelated async work.
    final unusedConfigDirectory = Directory(
      '${Directory.systemTemp.path}/mlt_project_page_widget_test',
    );

    final catalogs = ProjectCatalogService(
      configDirectory: unusedConfigDirectory,
    );

    final projectId = catalogs.activeProjectId;
    final archival = catalogs.createCatalog('Archival');
    final newspapers = catalogs.createCatalog(
      'Newspapers',
      parentId: archival.id,
    );
    catalogs.addMediaToCatalog('/tmp/a.mov', archival.id);
    catalogs.addMediaToCatalog('/tmp/b.mov', newspapers.id);

    final metadata = ProjectMediaMetadataService(
      configDirectory: unusedConfigDirectory,
    );
    metadata.setRating(projectId, '/tmp/a.mov', 5);
    metadata.setTags(projectId, '/tmp/a.mov', <String>['Select']);
    metadata.setColorHex(projectId, '/tmp/a.mov', '#64B5F6');
    metadata.addBookmark(projectId, '/tmp/a.mov', 24);

    await tester.pumpWidget(
      MaterialApp(
        home: ProjectPage(
          projectCatalogService: catalogs,
          projectMediaMetadataService: metadata,
          activeProjectId: projectId,
        ),
      ),
    );

    expect(find.text('PROJECT OVERVIEW'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('project-overview-name')),
      findsOneWidget,
    );
    expect(find.text('Archival'), findsOneWidget);
    expect(find.text('Newspapers'), findsOneWidget);
    expect(find.text('RATINGS'), findsOneWidget);
    expect(find.text('COLORS'), findsOneWidget);
    expect(find.text('TAGS'), findsNWidgets(2));
    expect(find.text('BOOKMARKS'), findsNWidgets(2));
    expect(find.text('Blue'), findsOneWidget);
    expect(find.textContaining('Select', findRichText: true), findsOneWidget);
  });
}
