// test/player_settings_redleaf_import_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_settings_service.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/ui/widgets/player_settings_button.dart';

void main() {
  late Directory tempDirectory;
  late PlayerSettingsService settings;
  late _FakeRedleafConnectionService connection;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'mlt_player_settings_redleaf_import_test_',
    );
    settings = PlayerSettingsService(configDirectory: tempDirectory);
    connection = _FakeRedleafConnectionService(
      configDirectory: Directory('${tempDirectory.path}/redleaf'),
    );
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

  testWidgets('Settings explicitly imports a connected Redleaf project',
      (tester) async {
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

    // Simulate sign-in through a deterministic fake. HTTP authentication has
    // its own service tests and must not run inside a widget test's fake clock.
    final signIn = find.text('SIGN IN', skipOffstage: false);
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn);
    await tester.pumpAndSettle();
    expect(connection.signInCalls, 1);
    expect(connection.isConnected, isTrue);

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
  });

  testWidgets('failed project import leaves Settings open with an error',
      (tester) async {
    connection.connect();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MltPlayerSettingsButton(
            settings: settings,
            mltVersion: '7.22',
            redleaf: connection,
            onImportConnectedRedleaf: () async {
              throw StateError('Archive import was rejected');
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
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.textContaining('Archive import was rejected'),
      findsOneWidget,
    );
  });
}

/// Widget-test double. Real Redleaf login HTTP behavior is covered by the
/// connection and workspace service tests with their own async server fixture.
class _FakeRedleafConnectionService extends RedleafConnectionService {
  _FakeRedleafConnectionService({required super.configDirectory});

  bool _connected = false;
  int signInCalls = 0;

  @override
  Future<void> load() async {}

  @override
  bool get isConnected => _connected;

  @override
  RedleafConnectionStatus get status => _connected
      ? RedleafConnectionStatus.connected
      : RedleafConnectionStatus.disconnected;

  @override
  String get serverUrl => RedleafConnectionService.defaultServerUrl;

  @override
  String get username => 'tester';

  @override
  String get instanceId => _connected ? 'settings-import-test' : '';

  @override
  String get projectName => _connected ? 'Imported Redleaf' : '';

  @override
  Future<bool> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    signInCalls += 1;
    connect();
    return true;
  }

  void connect() {
    _connected = true;
    notifyListeners();
  }

  @override
  void disconnect() {
    _connected = false;
    notifyListeners();
  }
}
