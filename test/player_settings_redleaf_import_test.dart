// test/player_settings_redleaf_import_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_settings_service.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/ui/widgets/player_settings_button.dart';

void main() {
  late Directory tempDirectory;
  late PlayerSettingsService settings;
  late RedleafConnectionService connection;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'mlt_player_settings_redleaf_import_test_',
    );
    settings = PlayerSettingsService(configDirectory: tempDirectory);
    connection = RedleafConnectionService(configDirectory: tempDirectory);
    await connection.load();
  });

  tearDown(() async {
    settings.dispose();
    connection.dispose();
    await tempDirectory.delete(recursive: true);
  });

  testWidgets('Cloud import action requires a connected Redleaf account',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MltPlayerSettingsButton(
            settings: settings,
            mltVersion: '7.22',
            redleaf: connection,
            onImportConnectedRedleaf: () async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('SIGN IN'), findsOneWidget);
    expect(
      find.text('CREATE NEW REDLEAF CLOUD PROJECT', skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets('Settings can explicitly create and import a connected project',
      (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serveRedleaf(server));

    try {
      final success = await connection.signIn(
        serverUrl: 'http://${server.address.address}:${server.port}',
        username: 'tester',
        password: 'secret',
      );
      expect(success, isTrue);

      var imports = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MltPlayerSettingsButton(
              settings: settings,
              mltVersion: '7.22',
              redleaf: connection,
              onImportConnectedRedleaf: () async {
                imports += 1;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      final create = find.text(
        'CREATE NEW REDLEAF CLOUD PROJECT',
        skipOffstage: false,
      );
      expect(create, findsOneWidget);

      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();

      expect(imports, 1);
      expect(find.text('Settings'), findsNothing);
    } finally {
      await server.close(force: true);
    }
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
        '<input type="hidden" name="csrf_token" value="csrf-login">',
      );
    } else if (request.method == 'POST' && path == '/login') {
      final data = await utf8.decoder.bind(request).join();
      final values = Uri.splitQueryString(data);
      final valid = values['csrf_token'] == 'csrf-login' &&
          values['username'] == 'tester' &&
          values['password'] == 'secret';
      if (valid) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/dashboard');
        request.response.cookies.add(Cookie('session', 'authed'));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('Invalid login');
      }
    } else if (request.method == 'GET' && path == '/dashboard') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<input type="hidden" name="csrf_token" value="csrf-session">',
      );
    } else if (request.method == 'GET' && path == '/api/system/info') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, String>{
          'instance_id': 'settings-import-test',
          'project_name': 'Imported Redleaf',
          'base_dir': '/tmp/remote',
        }),
      );
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
}
