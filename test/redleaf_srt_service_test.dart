// test/redleaf_srt_service_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/redleaf_srt_service.dart';

void main() {
  group('RedleafSrtDiscoveryService', () {
    late Directory tempDirectory;
    late HttpServer server;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_player_redleaf_srt_test_',
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDirectory.delete(recursive: true);
    });

    test(
      'discovers only SRT documents and preserves Redleaf document IDs',
      () async {
        unawaited(_serveRedleaf(server));

        final connection = RedleafConnectionService(
          configDirectory: tempDirectory,
        );
        final baseUrl = 'http://${server.address.address}:${server.port}';

        final signedIn = await connection.signIn(
          serverUrl: baseUrl,
          username: 'tester',
          password: 'secret',
        );

        expect(signedIn, isTrue);
        expect(connection.isConnected, isTrue);
        expect(connection.fileTypeCounts['SRT'], 3);

        final discovery = RedleafSrtDiscoveryService(
          connection: connection,
        );

        final ok = await discovery.refresh();

        expect(ok, isTrue);
        expect(discovery.expectedSrtCount, 3);
        expect(discovery.documentCount, 3);
        expect(
          discovery.documents.map((document) => document.docId),
          <int>[11, 12, 13],
        );
        expect(
          discovery.documents.every(
            (document) => document.relativePath.toLowerCase().endsWith('.srt'),
          ),
          isTrue,
        );
      },
    );

    test(
      'uses Redleaf media_status instead of filename guessing',
      () async {
        unawaited(_serveRedleaf(server));

        final connection = RedleafConnectionService(
          configDirectory: tempDirectory,
        );
        final baseUrl = 'http://${server.address.address}:${server.port}';

        expect(
          await connection.signIn(
            serverUrl: baseUrl,
            username: 'tester',
            password: 'secret',
          ),
          isTrue,
        );

        final discovery = RedleafSrtDiscoveryService(
          connection: connection,
        );

        expect(await discovery.refresh(), isTrue);

        final linked = discovery.documents.singleWhere(
          (document) => document.docId == 11,
        );
        final transcriptOnly = discovery.documents.singleWhere(
          (document) => document.docId == 12,
        );
        final unknown = discovery.documents.singleWhere(
          (document) => document.docId == 13,
        );

        expect(linked.hasMedia, isTrue);
        expect(linked.media.state, RedleafMediaLinkState.linked);
        expect(linked.media.type, 'audio');
        expect(linked.media.source, 'local');
        expect(linked.media.path, '/documents/radio/episode-01.mp3');

        expect(transcriptOnly.hasMedia, isFalse);
        expect(
          transcriptOnly.media.state,
          RedleafMediaLinkState.notLinked,
        );

        // The mock server deliberately fails the media-status request for
        // document 13. A failed check must remain UNKNOWN rather than being
        // silently converted into "not linked".
        expect(unknown.hasMedia, isFalse);
        expect(unknown.media.state, RedleafMediaLinkState.unknown);

        expect(discovery.linkedMediaCount, 1);
        expect(discovery.transcriptOnlyCount, 1);
        expect(discovery.unknownMediaCount, 1);
        expect(discovery.mediaCheckedCount, 3);
        expect(discovery.hasCompleteMediaScan, isFalse);
      },
    );

    test(
      'refuses discovery when Redleaf is not connected',
      () async {
        final connection = RedleafConnectionService(
          configDirectory: tempDirectory,
        );
        final discovery = RedleafSrtDiscoveryService(
          connection: connection,
        );

        final ok = await discovery.refresh();

        expect(ok, isFalse);
        expect(discovery.documentCount, 0);
        expect(
          discovery.lastError,
          contains('Connect to Redleaf in Settings'),
        );
      },
    );
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

      final filtered = request.uri.queryParameters['filtered'] == '1';
      final type = request.uri.queryParameters['type'];

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;

      if (!filtered) {
        request.response.write(
          jsonEncode(<String, Object?>{
            'documents': const <Object>[],
            'total_documents': 5,
            'page': 1,
            'per_page': 1,
            'all_types': const <String>['MP3', 'SRT'],
            'selected_types': const <String>['MP3', 'SRT'],
            'selected_statuses': null,
            'queue_size': 0,
            'task_states': const <String, Object>{},
          }),
        );
        await request.response.close();
        continue;
      }

      if (type == '__MLT_PLAYER_INVENTORY_NULL_PROBE__') {
        request.response.write(
          jsonEncode(<String, Object?>{
            'documents': const <Object>[],
            'total_documents': 1,
            'page': 1,
            'per_page': 1,
            'all_types': const <String>['MP3', 'SRT'],
            'selected_types': const <String>[
              '__MLT_PLAYER_INVENTORY_NULL_PROBE__',
            ],
            'selected_statuses': null,
            'queue_size': 0,
            'task_states': const <String, Object>{},
          }),
        );
        await request.response.close();
        continue;
      }

      if (type == 'MP3') {
        // Current Redleaf dashboard filtering includes NULL file_type rows,
        // so this total is 1 MP3 + 1 untyped row.
        request.response.write(
          jsonEncode(<String, Object?>{
            'documents': const <Object>[],
            'total_documents': 2,
            'page': 1,
            'per_page': 1,
            'all_types': const <String>['MP3', 'SRT'],
            'selected_types': const <String>['MP3'],
            'selected_statuses': null,
            'queue_size': 0,
            'task_states': const <String, Object>{},
          }),
        );
        await request.response.close();
        continue;
      }

      if (type == 'SRT') {
        final requestedPerPage =
            int.tryParse(request.uri.queryParameters['per_page'] ?? '') ?? 1;

        // Current Redleaf dashboard filtering includes the untyped row here
        // too. The discovery service must explicitly discard it.
        final documents = <Map<String, Object?>>[
          _documentRow(
            id: 11,
            relativePath: 'radio/episode-01.srt',
            color: 'yellow',
            tagCount: 2,
          ),
          _documentRow(
            id: 12,
            relativePath: 'radio/episode-02.srt',
            color: 'blue',
            tagCount: 1,
          ),
          _documentRow(
            id: 13,
            relativePath: 'radio/episode-03.srt',
            color: null,
            tagCount: 0,
          ),
          <String, Object?>{
            'id': 99,
            'relative_path': 'radio/untyped-record',
            'file_type': null,
            'status': 'Indexed',
            'status_message': null,
            'processed_at': '2026-08-01T00:00:00',
            'color': null,
            'file_size_bytes': 500,
            'duration_seconds': null,
            'linked_audio_path': null,
            'linked_video_path': null,
            'comment_count': 0,
            'tag_count': 0,
            'has_personal_note': null,
            'is_podcast_episode': null,
          },
        ];

        request.response.write(
          jsonEncode(<String, Object?>{
            'documents':
                requestedPerPage >= 4 ? documents : documents.take(1).toList(),
            'total_documents': 4,
            'page': 1,
            'per_page': requestedPerPage,
            'all_types': const <String>['MP3', 'SRT'],
            'selected_types': const <String>['SRT'],
            'selected_statuses': null,
            'queue_size': 0,
            'task_states': const <String, Object>{},
          }),
        );
        await request.response.close();
        continue;
      }

      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        path == '/api/document/11/media_status') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'linked': true,
          'path': '/documents/radio/episode-01.mp3',
          'type': 'audio',
          'source': 'local',
          'position': 12.5,
          'offset': 0.25,
        }),
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        path == '/api/document/12/media_status') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object>{
          'linked': false,
        }),
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        path == '/api/document/13/media_status') {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('deliberate test failure');
      await request.response.close();
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

Map<String, Object?> _documentRow({
  required int id,
  required String relativePath,
  required String? color,
  required int tagCount,
}) {
  return <String, Object?>{
    'id': id,
    'relative_path': relativePath,
    'file_type': 'SRT',
    'status': 'Indexed',
    'status_message': null,
    'processed_at': '2026-08-01T00:00:00',
    'color': color,
    'file_size_bytes': 1200 + id,
    'duration_seconds': 3600.0,
    'linked_audio_path': null,
    'linked_video_path': null,
    'comment_count': 0,
    'tag_count': tagCount,
    'has_personal_note': null,
    'is_podcast_episode': null,
  };
}

bool _isAuthenticated(HttpRequest request) {
  final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
  return cookie.contains('session=authed');
}

void _redirectToLogin(HttpRequest request) {
  request.response.statusCode = HttpStatus.found;
  request.response.headers.set(HttpHeaders.locationHeader, '/login');
}
