// test/redleaf_shared_credential_vault_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_shared_credential_vault.dart';

void main() {
  late Directory temp;
  late Directory vaultFolder;
  late RedleafSharedCredentialVault vault;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('redleaf_vault_test_');
    vaultFolder = Directory('${temp.path}/shared-vault');
    vault = RedleafSharedCredentialVault(storageDirectory: vaultFolder);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('encrypted records can be opened by both desktop apps', () async {
    await vault.save(
      instanceId: 'archive-a',
      username: 'researcher',
      password: 'my-secret-password',
    );

    // A new vault instance represents the second desktop application.
    final otherApp = RedleafSharedCredentialVault(
      storageDirectory: vaultFolder,
    );
    final found = await otherApp.read('archive-a');
    expect(found?.username, 'researcher');
    expect(found?.password, 'my-secret-password');
    expect(found?.serverUrl, 'http://127.0.0.1:5000');
    expect(await otherApp.read('archive-b'), isNull);

    // The encrypted record and key do not contain the cleartext login.
    final key = File('${vaultFolder.path}/vault.key');
    final encrypted = (await Directory('${vaultFolder.path}/entries')
            .list()
            .first) as File;
    final jsonBytes = await encrypted.readAsBytes();
    expect(utf8.decode(jsonBytes), isNot(contains('my-secret-password')));
    expect(utf8.decode(jsonBytes), isNot(contains('researcher')));
    expect(await key.length(), 32);
    expect(await key.readAsBytes(), isNot(contains('my-secret-password')));
  });

  test('vault creates private Linux directories and files without chmod command',
      () async {
    await vault.save(
      instanceId: 'archive',
      username: 'editor',
      password: 'secret',
    );

    final dir = await vaultFolder.stat();
    final entriesDir =
        await Directory('${vaultFolder.path}/entries').stat();
    final key = await File('${vaultFolder.path}/vault.key').stat();
    final entry = await Directory('${vaultFolder.path}/entries')
        .list()
        .first as File;
    final entryStat = await entry.stat();

    expect(dir.mode & 0x1ff, 0x1c0); // 0700
    expect(entriesDir.mode & 0x1ff, 0x1c0);
    expect(key.mode & 0x1ff, 0x180); // 0600
    expect(entryStat.mode & 0x1ff, 0x180);
  });

  test('deletion and replacement are isolated to one instance', () async {
    await vault.save(
      instanceId: 'archive-a',
      username: 'editor',
      password: 'old-password',
    );
    await vault.save(
      instanceId: 'archive-b',
      username: 'visitor',
      password: 'different-password',
    );
    await vault.save(
      instanceId: 'archive-a',
      username: 'editor-new',
      password: 'new-password',
    );
    expect((await vault.read('archive-a'))?.password, 'new-password');
    expect((await vault.read('archive-b'))?.password, 'different-password');

    await vault.delete('archive-a');
    expect(await vault.read('archive-a'), isNull);
    expect((await vault.read('archive-b'))?.username, 'visitor');
    await vault.delete('archive-a');
  });

  test('modified ciphertext fails authentication, never returns credentials',
      () async {
    await vault.save(
      instanceId: 'archive',
      username: 'editor',
      password: 'secret',
    );

    final file = (await Directory('${vaultFolder.path}/entries')
            .list()
            .first) as File;
    final decoded = jsonDecode(await file.readAsString())
        as Map<String, dynamic>;
    decoded['ciphertext'] = base64Encode(<int>[1, 2, 3, 4, 5]);
    await file.writeAsString(jsonEncode(decoded));

    await expectLater(
      vault.read('archive'),
      throwsA(isA<StateError>()),
    );
  });

  test('server origin is recorded and dangerous URLs are rejected', () async {
    await vault.save(
      instanceId: 'archive',
      username: 'editor',
      password: 'secret',
      serverUrl: 'https://redleaf.example.com/',
    );
    expect((await vault.read('archive'))?.serverUrl,
        'https://redleaf.example.com');

    expect(
      () => RedleafSharedCredentialVault.normalizeServerUrl(
        'http://user:password@127.0.0.1:5000',
      ),
      throwsArgumentError,
    );
    expect(
      () => RedleafSharedCredentialVault.normalizeServerUrl(
        'file:///tmp/credentials',
      ),
      throwsArgumentError,
    );
  });

  test('invalid login and database ID are rejected before writing', () async {
    await expectLater(
      vault.save(instanceId: 'archive', username: '', password: 'secret'),
      throwsArgumentError,
    );
    await expectLater(
      vault.save(instanceId: 'wrong\\ninstance', username: 'a', password: 'b'),
      throwsArgumentError,
    );
    expect(await vaultFolder.exists(), isFalse);
  });

  test('symlinked vault entries cannot be used', () async {
    await vault.save(
      instanceId: 'archive',
      username: 'editor',
      password: 'secret',
    );
    final original = (await Directory('${vaultFolder.path}/entries')
            .list()
            .first) as File;
    final backup = File('${temp.path}/outside.json');
    await original.rename(backup.path);
    await Link(original.path).create(backup.path);
    await expectLater(
      vault.read('archive'),
      throwsA(isA<StateError>()),
    );
  });
}
