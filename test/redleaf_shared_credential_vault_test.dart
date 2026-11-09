// test/redleaf_shared_credential_vault_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/redleaf_shared_credential_vault.dart';

class _FakeKeyring {
  final Map<String, String> entries = <String, String>{};
  final List<List<String>> commands = <List<String>>[];
  String? mostRecentStdin;

  Future<SecretToolResult> run(
    List<String> arguments, {
    String? secret,
  }) async {
    commands.add(List<String>.of(arguments));
    mostRecentStdin = secret;
    final verb = arguments.first;
    final attributes = arguments.skip(verb == 'store' ? 2 : 1).join('|');
    switch (verb) {
      case 'store':
        entries[attributes] = secret!;
        return const SecretToolResult(0, '');
      case 'lookup':
        return SecretToolResult(0, entries[attributes] ?? '');
      case 'clear':
        entries.remove(attributes);
        return const SecretToolResult(0, '');
      default:
        return const SecretToolResult(1, '');
    }
  }
}

void main() {
  late _FakeKeyring fake;
  late RedleafSharedCredentialVault vault;

  setUp(() {
    fake = _FakeKeyring();
    vault = RedleafSharedCredentialVault(runner: fake.run);
  });

  test('stores username and password ONLY on stdin, never in arguments',
      () async {
    await vault.save(
      instanceId: 'research-instance',
      username: 'researcher',
      password: 'sensitive-password',
    );

    final args = fake.commands.single.join(' ');
    expect(args, contains('research-instance'));
    expect(args, isNot(contains('researcher')));
    expect(args, isNot(contains('sensitive-password')));

    final stored = jsonDecode(fake.mostRecentStdin!)
        as Map<String, dynamic>;
    expect(stored['username'], 'researcher');
    expect(stored['password'], 'sensitive-password');
    expect(stored['serverUrl'], 'http://127.0.0.1:5000');
  });

  test('both apps can read same versioned instance-scoped secret', () async {
    await vault.save(
      instanceId: 'archive-a',
      username: 'editor',
      password: 'correct-123',
    );
    final found = await vault.read('archive-a');
    expect(found?.username, 'editor');
    expect(found?.password, 'correct-123');
    expect(found?.serverUrl, 'http://127.0.0.1:5000');
    expect(await vault.read('archive-b'), isNull);

    await vault.delete('archive-a');
    expect(await vault.read('archive-a'), isNull);
  });

  test('server origin is bound and cannot include foreign or hidden paths',
      () async {
    await vault.save(
      instanceId: 'a',
      username: 'user',
      password: 'secret',
      serverUrl: 'https://redleaf.example.com/',
    );
    expect((await vault.read('a'))?.serverUrl,
        'https://redleaf.example.com');

    expect(
      () => RedleafSharedCredentialVault.normalizeServerUrl(
          'http://user:password@127.0.0.1:5000'),
      throwsArgumentError,
    );
    expect(
      () => RedleafSharedCredentialVault.normalizeServerUrl(
          'https://redleaf.example.com/hidden/login'),
      throwsArgumentError,
    );
    expect(
      () => RedleafSharedCredentialVault.normalizeServerUrl(
          'file:///tmp/password.txt'),
      throwsArgumentError,
    );
  });

  test('invalid or missing credentials are rejected', () async {
    await expectLater(
      vault.save(instanceId: 'a', username: '', password: 'pass'),
      throwsArgumentError,
    );
    expect(
      () => RedleafSharedCredentialVault.attributesFor('x\ny'),
      throwsArgumentError,
    );
    expect(fake.commands, isEmpty);
  });
}
