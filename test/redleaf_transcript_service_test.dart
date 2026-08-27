// test/redleaf_transcript_service_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/services/redleaf_srt_service.dart';
import 'package:mlt_player/services/redleaf_transcript_service.dart';

void main() {
  group('RedleafTranscriptService', () {
    late Directory tempDirectory;
    late HttpServer server;
    late RedleafConnectionService connection;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_player_redleaf_transcript_test_',
      );
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );

      connection = RedleafConnectionService(
        configDirectory: tempDirectory,
      );
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDirectory.delete(recursive: true);
    });

    test(
      'loads the exact selected Redleaf SRT through serve_doc',
      () async {
        final servedPaths = <String>[];

        unawaited(
          _serveRedleaf(
            server,
            onServeDocument: (relativePath) {
              servedPaths.add(relativePath);

              if (relativePath ==
                  'rustbelt_radio/01-02-2012 - Rustbelt Radio for Jan 1 2012.srt') {
                return const _DocumentResponse(
                  statusCode: HttpStatus.ok,
                  body: '''
1
00:00:01,000 --> 00:00:03,500
First line
Second line

2
00:00:04.000 --> 00:00:05.250
<i>Hello</i> &amp; goodbye
''',
                );
              }

              return const _DocumentResponse(
                statusCode: HttpStatus.notFound,
                body: 'not found',
              );
            },
          ),
        );

        await _signIn(connection, server);

        final service = RedleafTranscriptService(
          connection: connection,
        );

        final transcript = await service.loadForDocument(
          _document(
            docId: 18,
            relativePath:
                'rustbelt_radio/01-02-2012 - Rustbelt Radio for Jan 1 2012.srt',
          ),
        );

        expect(
          servedPaths,
          <String>[
            'rustbelt_radio/01-02-2012 - Rustbelt Radio for Jan 1 2012.srt',
          ],
        );

        expect(transcript.instanceId, 'transcript-test-instance');
        expect(transcript.docId, 18);
        expect(
          transcript.sourceKey,
          'redleaf:transcript-test-instance:document:18',
        );
        expect(
          transcript.relativePath,
          'rustbelt_radio/01-02-2012 - Rustbelt Radio for Jan 1 2012.srt',
        );
        expect(transcript.cueCount, 2);

        expect(
          transcript.track.path,
          'redleaf:transcript-test-instance:document:18',
        );
        expect(transcript.track.cues.first.startMs, 1000);
        expect(transcript.track.cues.first.endMs, 3500);
        expect(
          transcript.track.cues.first.text,
          'First line\nSecond line',
        );
        expect(
          transcript.track.cues[1].text,
          'Hello & goodbye',
        );
        expect(
          transcript.track.textAt(2000),
          'First line\nSecond line',
        );
        expect(
          transcript.track.textAt(4500),
          'Hello & goodbye',
        );
      },
    );

    test(
      'uses the exact Redleaf relative path instead of inferring from media',
      () async {
        final servedPaths = <String>[];

        unawaited(
          _serveRedleaf(
            server,
            onServeDocument: (relativePath) {
              servedPaths.add(relativePath);

              return const _DocumentResponse(
                statusCode: HttpStatus.ok,
                body: '''
1
00:00:10,000 --> 00:00:11,000
Exact Redleaf document
''',
              );
            },
          ),
        );

        await _signIn(connection, server);

        final service = RedleafTranscriptService(
          connection: connection,
        );

        final transcript = await service.loadForDocument(
          _document(
            docId: 777,
            relativePath: 'collection/not-the-media-name.srt',
          ),
        );

        expect(
          servedPaths,
          <String>['collection/not-the-media-name.srt'],
        );
        expect(transcript.docId, 777);
        expect(
          transcript.track.textAt(10500),
          'Exact Redleaf document',
        );
      },
    );

    test(
      'rejects unsafe parent traversal in the selected Redleaf path',
      () async {
        unawaited(
          _serveRedleaf(
            server,
            onServeDocument: (_) {
              return const _DocumentResponse(
                statusCode: HttpStatus.ok,
                body: 'should not be requested',
              );
            },
          ),
        );

        await _signIn(connection, server);

        final service = RedleafTranscriptService(
          connection: connection,
        );

        expect(
          () => service.loadForDocument(
            _document(
              docId: 42,
              relativePath: '../outside.srt',
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('unsafe SRT path'),
            ),
          ),
        );
      },
    );

    test(
      'decodes Windows-1252 SRT bytes served by Redleaf',
      () async {
        unawaited(
          _serveRedleaf(
            server,
            onServeDocument: (relativePath) {
              if (relativePath != 'archive/legacy.srt') {
                return const _DocumentResponse(
                  statusCode: HttpStatus.notFound,
                  body: 'not found',
                );
              }

              return _DocumentResponse(
                statusCode: HttpStatus.ok,
                bytes: <int>[
                  ...ascii.encode(
                    '1\n00:00:00,000 --> 00:00:02,000\nIt',
                  ),
                  0x92,
                  ...ascii.encode('s '),
                  0x93,
                  ...ascii.encode('fine'),
                  0x94,
                  ...ascii.encode(' '),
                  0x96,
                  ...ascii.encode(' really '),
                  0x97,
                  ...ascii.encode(' yes'),
                  0x85,
                  ...ascii.encode('\n'),
                ],
              );
            },
          ),
        );

        await _signIn(connection, server);

        final service = RedleafTranscriptService(
          connection: connection,
        );

        final transcript = await service.loadForDocument(
          _document(
            docId: 91,
            relativePath: 'archive/legacy.srt',
          ),
        );

        expect(
          transcript.track.textAt(1000),
          'It’s “fine” – really — yes…',
        );
      },
    );
  });
}

RedleafSrtDocument _document({
  required int docId,
  required String relativePath,
}) {
  return RedleafSrtDocument(
    docId: docId,
    relativePath: relativePath,
    status: 'Processed',
    media: const RedleafMediaLink.notLinked(),
  );
}

Future<void> _signIn(
  RedleafConnectionService connection,
  HttpServer server,
) async {
  final baseUrl =
      'http://${server.address.address}:${server.port}';

  final signedIn = await connection.signIn(
    serverUrl: baseUrl,
    username: 'tester',
    password: 'secret',
  );

  expect(signedIn, isTrue);
  expect(connection.instanceId, 'transcript-test-instance');
}

class _DocumentResponse {
  const _DocumentResponse({
    required this.statusCode,
    this.body,
    this.bytes,
  });

  final int statusCode;
  final String? body;
  final List<int>? bytes;
}

Future<void> _serveRedleaf(
  HttpServer server, {
  required _DocumentResponse Function(String relativePath)
      onServeDocument,
}) async {
  await for (final request in server) {
    if (request.method == 'GET' &&
        request.uri.path == '/login') {
      request.response.cookies.add(
        Cookie('session', 'preauth'),
      );
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<html><body><form>'
        '<input type="hidden" '
        'name="csrf_token" value="csrf-login">'
        '</form></body></html>',
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'POST' &&
        request.uri.path == '/login') {
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
        request.response.cookies.add(
          Cookie('session', 'authed'),
        );
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
            const <String, Object>{
              'project_name': 'Redleaf Transcript Test',
              'instance_id': 'transcript-test-instance',
              'base_dir': '/tmp/redleaf-transcript-test',
            },
          ),
        );
      }

      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        request.uri.pathSegments.isNotEmpty &&
        request.uri.pathSegments.first == 'serve_doc') {
      final cookie =
          request.headers.value(HttpHeaders.cookieHeader) ?? '';

      if (!cookie.contains('session=authed')) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        continue;
      }

      final relativePath =
          request.uri.pathSegments.skip(1).join('/');
      final result = onServeDocument(relativePath);

      request.response.statusCode = result.statusCode;
      request.response.headers.contentType =
          ContentType('application', 'x-subrip');

      final bytes = result.bytes;
      if (bytes != null) {
        request.response.add(bytes);
      } else if (result.body != null) {
        request.response.write(result.body);
      }

      await request.response.close();
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}
