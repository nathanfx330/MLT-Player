// lib/services/redleaf_shared_credential_vault.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Credentials are shared between Redleaf Hub and MLT Player using the
/// desktop user's Secret Service keyring (GNOME Keyring / KWallet).
///
/// Never use command-line arguments, environment variables, project files,
/// SharedPreferences, or application logs to carry the password.
/// The secret-tool subprocess accepts the JSON secret ONLY through stdin.
/// Attribute values are non-secret and scoped to one Redleaf instance ID.
///
/// This first implementation is Linux-only. Other platforms must provide
/// their own native credential-vault backend, not a plaintext fallback.
class RedleafSavedCredentials {
  const RedleafSavedCredentials({
    required this.username,
    required this.password,
    required this.serverUrl,
  });

  final String username;
  final String password;
  /// The exact trusted login origin. Secrets are NEVER sent elsewhere.
  final String serverUrl;
}

class SecretToolResult {
  const SecretToolResult(this.exitCode, this.stdout);

  final int exitCode;
  final String stdout;
}

typedef SecretToolRunner = Future<SecretToolResult> Function(
  List<String> arguments, {
  String? secret,
});

class RedleafSharedCredentialVault {
  RedleafSharedCredentialVault({SecretToolRunner? runner})
      : _runner = runner ?? _runSecretTool;

  // Both desktop applications MUST use the same versioned namespace.
  static const String namespace = 'redleaf-hub-mlt-auth-v1';
  static const String _label = 'Redleaf Hub / MLT Player login';
  static const Duration _timeout = Duration(seconds: 20);
  static const String defaultServerUrl = 'http://127.0.0.1:5000';

  static String normalizeServerUrl(String raw) {
    final value = Uri.tryParse(raw.trim());
    if (value == null ||
        (value.scheme != 'http' && value.scheme != 'https') ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        (value.path.isNotEmpty && value.path != '/')) {
      throw ArgumentError('Use a Redleaf server origin such as http://127.0.0.1:5000.');
    }
    return value.origin;
  }

  final SecretToolRunner _runner;

  static List<String> attributesFor(String instanceId) {
    final normalized = instanceId.trim();
    if (normalized.isEmpty ||
        normalized.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Expected a valid Redleaf database instance ID.',
      );
    }
    return <String>[
      'application',
      namespace,
      'instance_id',
      normalized,
    ];
  }

  Future<void> save({
    required String instanceId,
    required String username,
    required String password,
    String serverUrl = defaultServerUrl,
  }) async {
    final user = username.trim();
    if (user.isEmpty || password.isEmpty) {
      throw ArgumentError('Enter a Redleaf username and password.');
    }

    final result = await _runner(
      <String>['store', '--label=$_label', ...attributesFor(instanceId)],
      secret: jsonEncode(<String, String>{
        'username': user,
        'password': password,
        'serverUrl': normalizeServerUrl(serverUrl),
      }),
    );
    if (result.exitCode != 0) {
      throw StateError('Could not save Redleaf credentials in the login keyring.');
    }
  }

  Future<RedleafSavedCredentials?> read(String instanceId) async {
    final result = await _runner(
      <String>['lookup', ...attributesFor(instanceId)],
    );
    if (result.exitCode != 0) {
      throw StateError('Could not read the Redleaf login keyring.');
    }
    final secret = result.stdout.trim();
    if (secret.isEmpty) return null;

    try {
      final record = jsonDecode(secret);
      if (record is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final username = record['username'];
      final password = record['password'];
      final serverUrl = record['serverUrl'];
      if (username is! String ||
          username.trim().isEmpty ||
          password is! String ||
          password.isEmpty ||
          serverUrl is! String) {
        throw const FormatException();
      }
      return RedleafSavedCredentials(
        username: username.trim(),
        password: password,
        serverUrl: normalizeServerUrl(serverUrl),
      );
    } on FormatException {
      throw StateError('Saved Redleaf credentials are invalid. Replace them in Hub.');
    } on ArgumentError {
      throw StateError('Saved Redleaf login server is invalid. Replace it in Hub.');
    }
  }

  Future<void> delete(String instanceId) async {
    final result = await _runner(
      <String>['clear', ...attributesFor(instanceId)],
    );
    if (result.exitCode != 0) {
      throw StateError('Could not remove Redleaf credentials from the login keyring.');
    }
  }

  static Future<SecretToolResult> _runSecretTool(
    List<String> arguments, {
    String? secret,
  }) async {
    if (!Platform.isLinux) {
      throw UnsupportedError(
        'Shared Redleaf credentials currently require a Linux desktop keyring.',
      );
    }

    Process process;
    try {
      process = await Process.start(
        'secret-tool',
        arguments,
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
    } on ProcessException {
      throw StateError(
        'Linux keyring support is not installed. Install libsecret-tools '
        'and use an unlocked GNOME Keyring or KWallet session.',
      );
    }

    try {
      // Capture streams, but never report their contents (or the secret)
      // through logs, exceptions or UI errors.
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.drain<void>();
      if (secret != null) process.stdin.write(secret);
      await process.stdin.close();
      final code = await process.exitCode.timeout(_timeout);
      final output = await stdout.timeout(_timeout);
      await stderr.timeout(_timeout);
      return SecretToolResult(code, output);
    } on TimeoutException {
      process.kill();
      throw StateError('The desktop keyring did not respond.');
    } catch (_) {
      process.kill();
      throw StateError('The desktop keyring operation failed.');
    }
  }
}
