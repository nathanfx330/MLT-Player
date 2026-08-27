// test/redleaf_catalog_service_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_catalog_service.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';

void main() {
  group('RedleafCatalogService', () {
    late Directory tempDirectory;
    late HttpServer server;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_player_redleaf_catalog_test_',
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDirectory.delete(recursive: true);
    });

    test(
      'loads catalogs and keeps only explicit SRT membership',
      () async {
        var membershipRequests = 0;
        unawaited(
          _serveRedleaf(
            server,
            onMembershipRequest: () => membershipRequests += 1,
          ),
        );

        final connection = RedleafConnectionService(
          configDirectory: tempDirectory,
        );
        final baseUrl =
            'http://${server.address.address}:${server.port}';

        expect(
          await connection.signIn(
            serverUrl: baseUrl,
            username: 'tester',
            password: 'secret',
          ),
          isTrue,
        );
        expect(connection.isConnected, isTrue);

        final catalogs = RedleafCatalogService(
          connection: connection,
        );

        expect(await catalogs.refreshCatalogs(), isTrue);
        expect(catalogs.loaded, isTrue);
        expect(catalogs.lastError, isNull);

        expect(
          catalogs.catalogs.map((catalog) => catalog.name).toList(),
          <String>[
            'Interviews',
            'Radio Archive',
            '⭐ Favorites',
          ],
        );

        final favorites = catalogs.catalogs.singleWhere(
          (catalog) => catalog.name == '⭐ Favorites',
        );
        final interviews = catalogs.catalogs.singleWhere(
          (catalog) => catalog.name == 'Interviews',
        );
        final radio = catalogs.catalogs.singleWhere(
          (catalog) => catalog.name == 'Radio Archive',
        );

        expect(favorites.id, 2);
        expect(favorites.isFavorites, isTrue);

        expect(interviews.id, 9);
        expect(interviews.isPodcast, isTrue);

        expect(radio.id, 7);
        expect(radio.isUser, isTrue);

        final first = await catalogs.srtDocumentIdsForCatalog(
          radio.id,
        );

        expect(first, <int>{11, 12});
        expect(membershipRequests, 1);

        // The response deliberately includes:
        // - an MP3,
        // - an untyped row whose filename ends in .srt,
        // - and a duplicate SRT row.
        // Only explicit file_type == SRT rows may survive.
        expect(first.contains(50), isFalse);
        expect(first.contains(99), isFalse);
        expect(first.length, 2);

        final cached = await catalogs.srtDocumentIdsForCatalog(
          radio.id,
        );

        expect(cached, <int>{11, 12});
        expect(membershipRequests, 1);

        final refreshed = await catalogs.srtDocumentIdsForCatalog(
          radio.id,
          forceRefresh: true,
        );

        expect(refreshed, <int>{11, 12});
        expect(membershipRequests, 2);

        catalogs.dispose();
      },
    );

    test(
      'disconnect clears catalog state',
      () async {
        unawaited(_serveRedleaf(server));

        final connection = RedleafConnectionService(
          configDirectory: tempDirectory,
        );
        final baseUrl =
            'http://${server.address.address}:${server.port}';

        expect(
          await connection.signIn(
            serverUrl: baseUrl,
            username: 'tester',
            password: 'secret',
          ),
          isTrue,
        );

        final catalogs = RedleafCatalogService(
          connection: connection,
        );

        expect(await catalogs.refreshCatalogs(), isTrue);
        expect(catalogs.loaded, isTrue);
        expect(catalogs.catalogs, isNotEmpty);

        connection.disconnect();

        expect(connection.isConnected, isFalse);
        expect(catalogs.loaded, isFalse);
        expect(catalogs.catalogs, isEmpty);
        expect(catalogs.lastError, isNull);

        expect(await catalogs.refreshCatalogs(), isFalse);
        expect(
          catalogs.lastError,
          contains('Connect to Redleaf in Settings'),
        );

        catalogs.dispose();
      },
    );
  });
}

Future<void> _serveRedleaf(
  HttpServer server, {
  void Function()? onMembershipRequest,
}) async {
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
          '<input type="hidden" '
          'name="csrf_token" '
          'value="csrf-session">',
        );
      }
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        path == '/api/system/info') {
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

    if (request.method == 'GET' &&
        path == '/api/dashboard/status') {
      if (!_isAuthenticated(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        continue;
      }

      final filtered =
          request.uri.queryParameters['filtered'] == '1';
      final type = request.uri.queryParameters['type'];

      var totalDocuments = 4;
      if (filtered &&
          type ==
              '__MLT_PLAYER_INVENTORY_NULL_PROBE__') {
        totalDocuments = 0;
      } else if (filtered && type == 'MP3') {
        totalDocuments = 1;
      } else if (filtered && type == 'SRT') {
        totalDocuments = 3;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'documents': const <Object>[],
          'total_documents': totalDocuments,
          'page': 1,
          'per_page': 1,
          'all_types': const <String>['MP3', 'SRT'],
          'selected_types':
              type == null ? const <String>['MP3', 'SRT'] : <String>[type],
          'selected_statuses': null,
          'queue_size': 0,
          'task_states': const <String, Object>{},
        }),
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        path == '/api/catalogs/all') {
      if (!_isAuthenticated(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        continue;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<Map<String, Object>>[
          <String, Object>{
            'id': 7,
            'name': 'Radio Archive',
            'catalog_type': 'user',
          },
          <String, Object>{
            'id': 2,
            'name': '⭐ Favorites',
            'catalog_type': 'favorites',
          },
          <String, Object>{
            'id': 9,
            'name': 'Interviews',
            'catalog_type': 'podcast',
          },
        ]),
      );
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' &&
        path == '/api/documents_by_tags') {
      if (!_isAuthenticated(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        continue;
      }

      onMembershipRequest?.call();

      final catalogId =
          request.uri.queryParameters['catalog_id'];

      if (catalogId != '7') {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write('[]');
        await request.response.close();
        continue;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'doc_id': 11,
            'relative_path': 'radio/episode-01.srt',
            'file_type': 'SRT',
          },
          <String, Object?>{
            'doc_id': 12,
            'relative_path': 'radio/episode-02.srt',
            'file_type': 'srt',
          },
          <String, Object?>{
            'doc_id': 50,
            'relative_path': 'radio/episode-01.mp3',
            'file_type': 'MP3',
          },
          <String, Object?>{
            'doc_id': 99,
            'relative_path': 'radio/looks-like-srt.srt',
            'file_type': null,
          },
          <String, Object?>{
            'doc_id': 11,
            'relative_path': 'radio/episode-01.srt',
            'file_type': 'SRT',
          },
        ]),
      );
      await request.response.close();
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

bool _isAuthenticated(HttpRequest request) {
  final cookie =
      request.headers.value(HttpHeaders.cookieHeader) ?? '';
  return cookie.contains('session=authed');
}

void _redirectToLogin(HttpRequest request) {
  request.response.statusCode = HttpStatus.found;
  request.response.headers.set(
    HttpHeaders.locationHeader,
    '/login',
  );
}
