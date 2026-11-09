// test/player_settings_redleaf_import_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_settings_service.dart';
import 'package:mlt_player/services/project_catalog_service.dart';
import 'package:mlt_player/services/redleaf_project_registry_service.dart';
import 'package:mlt_player/services/workspace_project_service.dart';
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
            onImportConnectedRedleaf: (name, restore) async {},
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
    String? requestedName;
    bool? requestedRestore;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MltPlayerSettingsButton(
            settings: settings,
            mltVersion: '7.22',
            redleaf: connection,
            onImportConnectedRedleaf: (name, restore) async {
              imports += 1;
              requestedName = name;
              requestedRestore = restore;
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

    final nameField = find.byWidgetPredicate(
      (widget) => widget is TextField &&
          widget.decoration?.labelText == 'MLT Player project name',
    );
    await tester.ensureVisible(nameField);
    await tester.pumpAndSettle();
    await tester.enterText(nameField, 'My Documentary Archive');
    await tester.pumpAndSettle();

    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(imports, 1);
    expect(requestedName, 'My Documentary Archive');
    expect(requestedRestore, isFalse);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('empty project name cannot create a cloud project',
      (tester) async {
    connection.connect();
    var imports = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MltPlayerSettingsButton(
            settings: settings,
            mltVersion: '7.22',
            redleaf: connection,
            onImportConnectedRedleaf: (name, restore) async {
              imports += 1;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final nameField = find.byWidgetPredicate(
      (widget) => widget is TextField &&
          widget.decoration?.labelText == 'MLT Player project name',
    );
    await tester.ensureVisible(nameField);
    await tester.pumpAndSettle();
    await tester.enterText(nameField, ' ');
    await tester.pumpAndSettle();

    final create = find.text(
      'CREATE NEW REDLEAF CLOUD PROJECT',
      skipOffstage: false,
    );
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(imports, 0);
    expect(
      find.text('Enter a project name before importing.'),
      findsOneWidget,
    );

    await tester.ensureVisible(nameField);
    await tester.pumpAndSettle();
    await tester.enterText(nameField, 'Valid Project');
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(imports, 1);
  });

  testWidgets('Cloud Trash hides a project and Restore returns it',
      (tester) async {
    // Widget tests use fake asynchronous time. Test the UI with an in-memory
    // workspace; real registry writes and restart are covered separately in
    // redleaf_project_trash_test.dart using ordinary Dart tests.
    connection.connect();
    final workspace = _FakeWorkspaceProjectService(
      directory: tempDirectory,
      redleafConnection: connection,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MltPlayerSettingsButton(
            settings: settings,
            mltVersion: '7.22',
            redleaf: connection,
            workspaceProjects: workspace,
            onImportConnectedRedleaf: (name, restore) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final trash = find.byTooltip('Move My Cloud Archive to Trash');
    await tester.ensureVisible(trash);
    await tester.pumpAndSettle();
    await tester.tap(trash);
    await tester.pumpAndSettle();
    expect(find.text('Move Redleaf project to Trash?'), findsOneWidget);
    await tester.tap(find.text('MOVE TO TRASH'));
    await tester.pumpAndSettle();

    expect(workspace.savedRedleafProjects, isEmpty);
    expect(workspace.trashedRedleafProjects, hasLength(1));
    expect(workspace.activeIsLocal, isTrue);
    expect(find.text('TRASH (1)', skipOffstage: false), findsOneWidget);

    final restore = find.text('RESTORE', skipOffstage: false);
    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pumpAndSettle();

    expect(workspace.savedRedleafProjects, hasLength(1));
    expect(workspace.trashedRedleafProjects, isEmpty);
    expect(workspace.trashCalls, 1);
    expect(workspace.restoreCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    workspace.dispose();
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
            onImportConnectedRedleaf: (name, restore) async {
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

/// In-memory workspace for widget tests. Registry persistence is exercised
/// by normal Dart tests, never inside the widget test's simulated async clock.
class _FakeWorkspaceProjectService extends WorkspaceProjectService {
  _FakeWorkspaceProjectService({
    required Directory directory,
    required RedleafConnectionService redleafConnection,
  }) : super(
          localProjects: ProjectCatalogService(
            configDirectory: Directory('${directory.path}/local'),
          ),
          redleafConnection: redleafConnection,
          redleafProjects: RedleafProjectRegistryService(
            configDirectory: Directory('${directory.path}/registry'),
          ),
        );

  late final RedleafProjectRecord _record = RedleafProjectRecord(
    instanceId: 'settings-import-test',
    name: 'My Cloud Archive',
    serverUrl: RedleafConnectionService.defaultServerUrl,
    createdAt: DateTime.utc(2026, 11, 9),
    updatedAt: DateTime.utc(2026, 11, 9),
  );

  bool _trashed = false;
  int trashCalls = 0;
  int restoreCalls = 0;

  @override
  bool get loaded => true;

  @override
  List<RedleafProjectRecord> get savedRedleafProjects =>
      _trashed ? <RedleafProjectRecord>[] : <RedleafProjectRecord>[_record];

  @override
  List<RedleafProjectRecord> get trashedRedleafProjects =>
      _trashed
          ? <RedleafProjectRecord>[
              _record.copyWith(trashedAt: DateTime.utc(2026, 11, 9))
            ]
          : <RedleafProjectRecord>[];

  @override
  RedleafProjectRecord? get connectedRedleafRecord =>
      _trashed ? trashedRedleafProjects.single : _record;

  @override
  bool get activeIsLocal => _trashed;

  @override
  Future<void> trashRedleafProject(String instanceId) async {
    expect(instanceId, _record.instanceId);
    trashCalls += 1;
    _trashed = true;
    notifyListeners();
  }

  @override
  Future<void> restoreRedleafProject(String instanceId) async {
    expect(instanceId, _record.instanceId);
    restoreCalls += 1;
    _trashed = false;
    notifyListeners();
  }
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
