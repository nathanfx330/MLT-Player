// test/redleaf_hub_onboarding_dialog_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_connection_service.dart';
import 'package:mlt_player/ui/widgets/redleaf_hub_onboarding_dialog.dart';

class _FakeConnection extends RedleafConnectionService {
  _FakeConnection({required super.configDirectory});

  String answeredInstanceId = 'expected-instance';
  String currentInstanceId = '';
  bool connected = false;
  int signInCalls = 0;
  int disconnectCalls = 0;

  @override
  bool get isConnected => connected;

  @override
  String get instanceId => currentInstanceId;

  @override
  String get username => '';

  @override
  String get serverUrl => RedleafConnectionService.defaultServerUrl;

  @override
  String? get lastError => null;

  @override
  Future<bool> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    signInCalls += 1;
    connected = true;
    currentInstanceId = answeredInstanceId;
    notifyListeners();
    return true;
  }

  @override
  void disconnect() {
    disconnectCalls += 1;
    connected = false;
    currentInstanceId = '';
    notifyListeners();
  }
}

void main() {
  late Directory temp;
  late _FakeConnection connection;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hub_onboarding_test_');
    connection = _FakeConnection(configDirectory: temp);
  });

  tearDown(() async {
    connection.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> open(
    WidgetTester tester, {
    required Future<void> Function(String, bool) onImport,
    bool trashed = false,
    bool cached = false,
    Future<void> Function()? onRestoreCached,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => RedleafHubOnboardingDialog(
                  expectedInstanceId: 'expected-instance',
                  suggestedName: 'Hub Research',
                  serverUrl: 'http://127.0.0.1:5000',
                  connection: connection,
                  onImport: onImport,
                  existingInTrash: trashed,
                  hasCachedSnapshot: cached,
                  onRestoreCached: onRestoreCached,
                ),
              ),
              child: const Text('OPEN HUB PROJECT'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN HUB PROJECT'));
    await tester.pumpAndSettle();
  }

  testWidgets('onboarding requires password, confirms identity and name',
      (tester) async {
    String? importedName;
    bool? restored;
    await open(
      tester,
      onImport: (name, restore) async {
        importedName = name;
        restored = restore;
      },
    );

    expect(find.text('Hub Research'), findsOneWidget);
    expect(find.text('Add Redleaf project to MLT Player'), findsOneWidget);

    final submit = find.text('SIGN IN AND IMPORT');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('Enter your Redleaf username and password.'),
        findsOneWidget);
    expect(connection.signInCalls, 0);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'My MLT Research');
    await tester.enterText(fields.at(2), 'researcher');
    await tester.enterText(fields.at(3), 'private-password');
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(importedName, 'My MLT Research');
    expect(restored, isFalse);
    expect(connection.signInCalls, 1);
    expect(find.text('Add Redleaf project to MLT Player'), findsNothing);
  });

  testWidgets('a different signed-in instance is rejected before import',
      (tester) async {
    connection.answeredInstanceId = 'wrong-database';
    var imports = 0;
    await open(
      tester,
      onImport: (name, restore) async => imports += 1,
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(2), 'researcher');
    await tester.enterText(fields.at(3), 'password');
    await tester.tap(find.text('SIGN IN AND IMPORT'));
    await tester.pumpAndSettle();

    expect(imports, 0);
    expect(connection.disconnectCalls, 1);
    expect(connection.isConnected, isFalse);
    expect(
      find.textContaining('not the project selected in Redleaf Hub'),
      findsOneWidget,
    );
  });

  testWidgets('cached Trash project offers explicit offline restore',
      (tester) async {
    var restores = 0;
    var imports = 0;
    await open(
      tester,
      trashed: true,
      cached: true,
      onImport: (name, restore) async => imports += 1,
      onRestoreCached: () async => restores += 1,
    );

    await tester.tap(find.text('RESTORE SAVED PROJECT'));
    await tester.pumpAndSettle();
    expect(restores, 1);
    expect(imports, 0);
    expect(connection.signInCalls, 0);
    expect(find.text('Restore Redleaf project'), findsNothing);
  });
}
