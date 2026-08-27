// test/workspace_project_service_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/workspace_project.dart';
import 'package:mlt_player/services/project_catalog_service.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/workspace_project_service.dart';

void main() {
  group('WorkspaceProjectService', () {
    late Directory tempDirectory;
    late HttpServer server;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_player_workspace_project_test_',
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDirectory.delete(recursive: true);
    });

    test('starts with local MLT projects only', () async {
      final localProjects = ProjectCatalogService(
        configDirectory: tempDirectory,
      );
      final redleaf = RedleafConnectionService(
        configDirectory: tempDirectory,
      );
      final workspace = WorkspaceProjectService(
        localProjects: localProjects,
        redleafConnection: redleaf,
      );

      await workspace.load();

      expect(workspace.loaded, isTrue);
      expect(workspace.projects, hasLength(1));
      expect(workspace.activeProject, isNotNull);
      expect(workspace.activeProject!.kind, WorkspaceProjectKind.local);
      expect(workspace.activeProject!.localProjectId, localProjects.activeProjectId);
      expect(workspace.activeIsLocal, isTrue);
      expect(workspace.activeIsRedleaf, isFalse);

      workspace.dispose();
    });

    test('adds connected Redleaf as a separate workspace project', () async {
      unawaited(_serveRedleaf(server));

      final localProjects = ProjectCatalogService(
        configDirectory: tempDirectory,
      );
      final redleaf = RedleafConnectionService(
        configDirectory: tempDirectory,
      );
      final workspace = WorkspaceProjectService(
        localProjects: localProjects,
        redleafConnection: redleaf,
      );

      await workspace.load();

      final documentary = localProjects.createProject('Documentary');
      localProjects.setActiveProject(documentary.id);
      workspace.synchronizeLocalProjects();

      final baseUrl = 'http://${server.address.address}:${server.port}';
      expect(
        await redleaf.signIn(
          serverUrl: baseUrl,
          username: 'tester',
          password: 'secret',
        ),
        isTrue,
      );

      final projects = workspace.projects;

      expect(projects, hasLength(3));
      expect(
        projects.where((project) => project.isLocal),
        hasLength(2),
      );
      expect(
        projects.where((project) => project.isRedleaf),
        hasLength(1),
      );

      final remote = projects.singleWhere((project) => project.isRedleaf);
      expect(remote.name, 'Radio Archive');
      expect(remote.redleafInstanceId, 'radio-test-instance');
      expect(remote.redleafServerUrl, baseUrl);
      expect(remote.key, 'redleaf:radio-test-instance');

      // Connecting Redleaf does not steal the active local project.
      expect(workspace.activeProject!.isLocal, isTrue);
      expect(workspace.activeProject!.localProjectId, documentary.id);

      workspace.dispose();
    });

    test('switches between local and Redleaf without mixing identities', () async {
      unawaited(_serveRedleaf(server));

      final localProjects = ProjectCatalogService(
        configDirectory: tempDirectory,
      );
      final redleaf = RedleafConnectionService(
        configDirectory: tempDirectory,
      );
      final workspace = WorkspaceProjectService(
        localProjects: localProjects,
        redleafConnection: redleaf,
      );

      await workspace.load();

      final documentary = localProjects.createProject('Documentary');
      final research = localProjects.createProject('Research');

      localProjects.setActiveProject(documentary.id);
      workspace.synchronizeLocalProjects();

      final baseUrl = 'http://${server.address.address}:${server.port}';
      expect(
        await redleaf.signIn(
          serverUrl: baseUrl,
          username: 'tester',
          password: 'secret',
        ),
        isTrue,
      );

      workspace.selectRedleaf();

      expect(workspace.activeIsRedleaf, isTrue);
      expect(
        workspace.activeProject!.key,
        WorkspaceProject.redleafKey('radio-test-instance'),
      );

      // Selecting Redleaf must not alter the active local project underneath.
      expect(localProjects.activeProjectId, documentary.id);

      workspace.selectLocalProject(research.id);

      expect(workspace.activeIsLocal, isTrue);
      expect(workspace.activeProject!.localProjectId, research.id);
      expect(localProjects.activeProjectId, research.id);

      workspace.selectRedleaf();
      expect(workspace.activeIsRedleaf, isTrue);

      redleaf.disconnect();

      // If the remote source disappears, the workspace safely falls back to
      // whichever local project was last active.
      expect(workspace.activeIsLocal, isTrue);
      expect(workspace.activeProject!.localProjectId, research.id);
      expect(localProjects.activeProjectId, research.id);

      workspace.dispose();
    });
  });
}

Future<void> _serveRedleaf(HttpServer server) async {
  await for (final request in server) {
    final path = request.uri.path;

    if (request.method == 'GET' && path == '/login') {
      request.response.cookies.add(Cookie('session', 'preauth'));
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<html><body><form>'
        '<input type="hidden" name="csrf_token" value="csrf-login">'
        '</form></body></html>',
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'POST' && path == '/login') {
      final body = await utf8.decoder.bind(request).join();
      final values = Uri.splitQueryString(body);
      final cookie =
          request.headers.value(HttpHeaders.cookieHeader) ?? '';

      final accepted =
          cookie.contains('session=preauth') &&
          values['csrf_token'] == 'csrf-login' &&
          values['username'] == 'tester' &&
          values['password'] == 'secret';

      if (accepted) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/dashboard',
        );
        request.response.cookies.add(Cookie('session', 'authed'));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('Sign in failed');
      }

      await request.response.close();
      continue;
    }

    if (request.method == 'GET' && path == '/dashboard') {
      if (!_isAuthenticated(request)) {
        _redirectToLogin(request);
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<input type="hidden" name="csrf_token" value="csrf-session">',
        );
      }
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' && path == '/api/system/info') {
      if (!_isAuthenticated(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object>{
            'project_name': 'Radio Archive',
            'instance_id': 'radio-test-instance',
            'base_dir': '/srv/redleaf-radio',
          }),
        );
      }
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' && path == '/api/dashboard/status') {
      if (!_isAuthenticated(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        continue;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'documents': const <Object>[],
          'total_documents': 0,
          'page': 1,
          'per_page': 1,
          'all_types': const <String>[],
          'selected_types': const <String>[],
          'selected_statuses': null,
          'queue_size': 0,
          'task_states': const <String, Object>{},
        }),
      );
      await request.response.close();
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

bool _isAuthenticated(HttpRequest request) {
  final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
  return cookie.contains('session=authed');
}

void _redirectToLogin(HttpRequest request) {
  request.response.statusCode = HttpStatus.found;
  request.response.headers.set(HttpHeaders.locationHeader, '/login');
}
