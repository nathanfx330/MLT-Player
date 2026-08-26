// test/redleaf_connection_service_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';

void main() {
  group('RedleafConnectionService', () {
    late Directory tempDirectory;
    late HttpServer server;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'mlt_player_redleaf_connection_test_',
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDirectory.delete(recursive: true);
    });

    test('signs in, reads instance identity, and does not save password', () async {
      unawaited(_serveRedleaf(server, acceptedPassword: 'secret'));

      final service = RedleafConnectionService(configDirectory: tempDirectory);
      final baseUrl = 'http://${server.address.address}:${server.port}';

      final ok = await service.signIn(
        serverUrl: baseUrl,
        username: 'tester',
        password: 'secret',
      );

      expect(ok, isTrue);
      expect(service.status, RedleafConnectionStatus.connected);
      expect(service.isConnected, isTrue);
      expect(service.instanceId, 'test-instance-1234');
      expect(service.projectName, 'Redleaf Test');
      expect(service.baseDirectory, '/srv/redleaf-test');
      expect(service.sessionCookie, contains('session=authed'));

      final saved = await File(
        '${tempDirectory.path}/redleaf_connection.json',
      ).readAsString();
      expect(saved, contains(baseUrl));
      expect(saved, contains('tester'));
      expect(saved, isNot(contains('secret')));
    });

    test('reports an authentication failure', () async {
      unawaited(_serveRedleaf(server, acceptedPassword: 'right-password'));

      final service = RedleafConnectionService(configDirectory: tempDirectory);
      final baseUrl = 'http://${server.address.address}:${server.port}';

      final ok = await service.signIn(
        serverUrl: baseUrl,
        username: 'tester',
        password: 'wrong-password',
      );

      expect(ok, isFalse);
      expect(service.status, RedleafConnectionStatus.error);
      expect(service.isConnected, isFalse);
      expect(service.lastError, contains('sign-in failed'));
    });

    test('reloads saved server and username but never restores a session', () async {
      final file = File('${tempDirectory.path}/redleaf_connection.json');
      await file.writeAsString(
        jsonEncode(<String, Object>{
          'version': 1,
          'serverUrl': 'http://192.168.1.20:5000',
          'username': 'researcher',
        }),
      );

      final service = RedleafConnectionService(configDirectory: tempDirectory);
      await service.load();

      expect(service.serverUrl, 'http://192.168.1.20:5000');
      expect(service.username, 'researcher');
      expect(service.status, RedleafConnectionStatus.disconnected);
      expect(service.sessionCookie, isEmpty);
      expect(service.isConnected, isFalse);
    });
  });
}

Future<void> _serveRedleaf(
  HttpServer server, {
  required String acceptedPassword,
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
      final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
      final accepted =
          cookie.contains('session=preauth') &&
          values['csrf_token'] == 'csrf-login' &&
          values['username'] == 'tester' &&
          values['password'] == acceptedPassword;

      if (accepted) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/dashboard');
        request.response.cookies.add(Cookie('session', 'authed'));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('Sign in failed');
      }
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' && request.uri.path == '/dashboard') {
      final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
      if (!cookie.contains('session=authed')) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/login');
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write(
          '<input type="hidden" name="csrf_token" value="csrf-session">',
        );
      }
      await request.response.close();
      continue;
    }

    if (request.method == 'GET' && request.uri.path == '/api/system/info') {
      final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
      if (!cookie.contains('session=authed')) {
        request.response.statusCode = HttpStatus.unauthorized;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object>{
            'project_name': 'Redleaf Test',
            'instance_id': 'test-instance-1234',
            'base_dir': '/srv/redleaf-test',
          }),
        );
      }
      await request.response.close();
      continue;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}
