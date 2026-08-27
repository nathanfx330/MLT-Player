// test/redleaf_media_resource_service_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/redleaf_media_resource_service.dart';
import 'package:mlt_player/services/redleaf_srt_service.dart';

void main() {
  group('RedleafMediaResourceService', () {
    late Directory tempDirectory;
    late Directory redleafRoot;
    late Directory documentsDirectory;
    late Directory configDirectory;
    late HttpServer server;
    late RedleafConnectionService connection;
    late RedleafMediaResourceService resources;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_player_redleaf_media_resource_test_',
      );

      redleafRoot = Directory(
        _join(tempDirectory.path, const <String>['redleaf']),
      );
      documentsDirectory = Directory(
        _join(redleafRoot.path, const <String>['documents']),
      );
      configDirectory = Directory(
        _join(tempDirectory.path, const <String>['config']),
      );

      await documentsDirectory.create(recursive: true);
      await configDirectory.create(recursive: true);

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        _serveRedleaf(
          server,
          baseDirectory: redleafRoot.path,
        ),
      );

      connection = RedleafConnectionService(
        configDirectory: configDirectory,
      );

      final baseUrl = 'http://${server.address.address}:${server.port}';
      final signedIn = await connection.signIn(
        serverUrl: baseUrl,
        username: 'tester',
        password: 'secret',
      );

      expect(signedIn, isTrue);
      expect(connection.baseDirectory, redleafRoot.path);

      resources = RedleafMediaResourceService(
        connection: connection,
      );
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDirectory.delete(recursive: true);
    });

    test('resolves and verifies ordinary local Redleaf media', () async {
      final mediaFile = File(
        _join(
          documentsDirectory.path,
          const <String>['media', 'audio.mp3'],
        ),
      );
      await mediaFile.parent.create(recursive: true);
      await mediaFile.writeAsBytes(const <int>[1, 2, 3]);

      final result = await resources.resolve(
        _document(
          media: const RedleafMediaLink(
            state: RedleafMediaLinkState.linked,
            path: '/serve_doc/media/audio.mp3',
            type: 'audio',
            source: 'local',
          ),
        ),
      );

      expect(
        result.state,
        RedleafMediaResourceState.localFileReady,
      );
      expect(result.isPlayerReady, isTrue);
      expect(result.virtualPath, 'media/audio.mp3');
      expect(result.redleafReference, '/serve_doc/media/audio.mp3');
      expect(result.resolvedResource, mediaFile.absolute.path);
    });

    test('resolves local media through a Redleaf .rlink', () async {
      final externalRoot = Directory(
        _join(tempDirectory.path, const <String>['external_archive']),
      );
      final mediaFile = File(
        _join(
          externalRoot.path,
          const <String>['episodes', 'video.mp4'],
        ),
      );
      await mediaFile.parent.create(recursive: true);
      await mediaFile.writeAsBytes(const <int>[4, 5, 6]);

      final rlinkFile = File(
        _join(
          documentsDirectory.path,
          const <String>['archive.rlink'],
        ),
      );
      await rlinkFile.writeAsString(externalRoot.path);

      final result = await resources.resolve(
        _document(
          media: const RedleafMediaLink(
            state: RedleafMediaLinkState.linked,
            path: '/serve_doc/archive.rlink/episodes/video.mp4',
            type: 'video',
            source: 'local',
          ),
        ),
      );

      expect(
        result.state,
        RedleafMediaResourceState.localFileReady,
      );
      expect(result.isPlayerReady, isTrue);
      expect(
        result.virtualPath,
        'archive.rlink/episodes/video.mp4',
      );
      expect(result.resolvedResource, mediaFile.absolute.path);
    });

    test('preserves a web URL without calling it Player-ready', () async {
      const url = 'https://media.example.test/episode.mp3';

      final result = await resources.resolve(
        _document(
          media: const RedleafMediaLink(
            state: RedleafMediaLinkState.linked,
            path: url,
            type: 'audio',
            source: 'web',
          ),
        ),
      );

      expect(
        result.state,
        RedleafMediaResourceState.webUrlCandidate,
      );
      expect(result.isWebUrlCandidate, isTrue);
      expect(result.isPlayerReady, isFalse);
      expect(result.redleafReference, url);
      expect(result.resolvedResource, url);
      expect(result.virtualPath, isNull);
    });

    test('keeps transcript-only documents distinct from media failures', () async {
      final result = await resources.resolve(
        _document(
          media: const RedleafMediaLink.notLinked(),
        ),
      );

      expect(
        result.state,
        RedleafMediaResourceState.transcriptOnly,
      );
      expect(result.isPlayerReady, isFalse);
      expect(result.redleafReference, isNull);
      expect(result.resolvedResource, isNull);
    });

    test('reports missing local media instead of guessing', () async {
      final expectedPath = File(
        _join(
          documentsDirectory.path,
          const <String>['media', 'missing.mp3'],
        ),
      ).absolute.path;

      final result = await resources.resolve(
        _document(
          media: const RedleafMediaLink(
            state: RedleafMediaLinkState.linked,
            path: '/serve_doc/media/missing.mp3',
            type: 'audio',
            source: 'local',
          ),
        ),
      );

      expect(
        result.state,
        RedleafMediaResourceState.unavailable,
      );
      expect(result.isPlayerReady, isFalse);
      expect(result.virtualPath, 'media/missing.mp3');
      expect(result.resolvedResource, expectedPath);
      expect(
        result.message,
        contains('resolved file is not present'),
      );
    });
  });
}

RedleafSrtDocument _document({
  required RedleafMediaLink media,
}) {
  return RedleafSrtDocument(
    docId: 42,
    relativePath: 'transcripts/example.srt',
    status: 'Processed',
    media: media,
  );
}

Future<void> _serveRedleaf(
  HttpServer server, {
  required String baseDirectory,
}) async {
  await for (final request in server) {
    if (request.method == 'GET' && request.uri.path == '/login') {
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

    if (request.method == 'POST' && request.uri.path == '/login') {
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

    if (request.method == 'GET' &&
        request.uri.path == '/dashboard') {
      final cookie =
          request.headers.value(HttpHeaders.cookieHeader) ?? '';

      if (!cookie.contains('session=authed')) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/login',
        );
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(
          '<input type="hidden" '
          'name="csrf_token" value="csrf-session">',
        );
      }

      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        request.uri.path == '/api/system/info') {
      final cookie =
          request.headers.value(HttpHeaders.cookieHeader) ?? '';

      if (!cookie.contains('session=authed')) {
        request.response.statusCode = HttpStatus.unauthorized;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            <String, Object>{
              'project_name': 'Redleaf Resource Test',
              'instance_id': 'resource-test-instance',
              'base_dir': baseDirectory,
            },
          ),
        );
      }

      await request.response.close();
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

String _join(
  String base,
  Iterable<String> segments,
) {
  var result = base;

  for (final segment in segments) {
    if (result.endsWith(Platform.pathSeparator)) {
      result = '$result$segment';
    } else {
      result = '$result${Platform.pathSeparator}$segment';
    }
  }

  return result;
}
