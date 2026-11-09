// lib/services/redleaf_shared_credential_vault.dart

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Private app-managed Redleaf login vault shared by Hub and MLT Player.
///
/// Uses AES-256-GCM and per-record random nonces. Both apps use the same
/// directory, key and record format. No system keyring executable, daemon,
/// shell invocation or manual OS package installation is needed.
///
/// The randomly generated encryption key must remain readable by both apps
/// for unattended login. It is held in a separate mode-0600 file alongside
/// the encrypted records in a mode-0700 directory. This is NOT equivalent
/// to a hardware-backed or separately unlocked operating-system keyring:
/// software with the same Linux user privileges can read the key and records.
class RedleafSavedCredentials {
  const RedleafSavedCredentials({
    required this.username,
    required this.password,
    required this.serverUrl,
  });

  final String username;
  final String password;
  final String serverUrl;
}

class RedleafSharedCredentialVault {
  RedleafSharedCredentialVault({Directory? storageDirectory})
      : _root = storageDirectory ?? _defaultStorageDirectory();

  static const String namespace = 'redleaf-hub-mlt-auth-v2';
  static const String defaultServerUrl = 'http://127.0.0.1:5000';
  static const int storageVersion = 2;
  static final AesGcm _cipher = AesGcm.with256bits();
  static final Random _random = Random.secure();

  final Directory _root;

  Directory get _entries => Directory('${_root.path}/entries');
  File get _keyFile => File('${_root.path}/vault.key');

  static Directory _defaultStorageDirectory() {
    final home = Platform.environment['HOME']?.trim();
    final xdg = Platform.environment['XDG_DATA_HOME']?.trim();
    if (xdg != null && xdg.isNotEmpty && xdg.startsWith('/')) {
      return Directory('$xdg/redleaf-hub-mlt-auth/v2');
    }
    if (home == null || !home.startsWith('/')) {
      throw StateError('A Linux home directory is required for saved Redleaf logins.');
    }
    return Directory('$home/.local/share/redleaf-hub-mlt-auth/v2');
  }

  static String normalizeServerUrl(String raw) {
    final url = Uri.tryParse(raw.trim());
    if (url == null ||
        (url.scheme != 'http' && url.scheme != 'https') ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        (url.path.isNotEmpty && url.path != '/')) {
      throw ArgumentError(
        'Use a Redleaf server origin such as http://127.0.0.1:5000.',
      );
    }
    return url.origin;
  }

  static String _validateInstanceId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw ArgumentError.value(
        value, 'instanceId', 'Expected a valid Redleaf database instance ID.',
      );
    }
    return normalized;
  }

  File _entryFile(String id) {
    final name = base64Url.encode(utf8.encode(id)).replaceAll('=', '');
    return File('${_entries.path}/$name.json');
  }

  static List<int> _randomBytes(int count) =>
      List<int>.generate(count, (_) => _random.nextInt(256));

  Future<void> _prepare({required bool create}) async {
    if (!Platform.isLinux) {
      throw UnsupportedError(
        'The shared Redleaf vault currently supports Linux desktops.',
      );
    }
    if (create) {
      await _LinuxPrivateFiles.ensureDirectory(_root);
      await _LinuxPrivateFiles.ensureDirectory(_entries);
      return;
    }
    if (await _root.exists()) {
      await _LinuxPrivateFiles.ensurePrivateExistingDirectory(_root);
    }
    if (await _entries.exists()) {
      await _LinuxPrivateFiles.ensurePrivateExistingDirectory(_entries);
    }
  }

  /// Create a key once per user. Atomic hard-link prevents two apps
  /// initializing the vault at the same time from overwriting each key.
  Future<SecretKey?> _getKey({required bool create}) async {
    final file = _keyFile;
    if (!await file.exists() && create) {
      final temp = File('${file.path}.tmp.$pid.${base64Url.encode(_randomBytes(12))}');
      await _LinuxPrivateFiles.writeNewFile(
        temp,
        _randomBytes(32),
      );
      try {
        _LinuxPrivateFiles.linkIfMissing(temp.path, file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }

    if (!await file.exists()) return null;
    await _LinuxPrivateFiles.ensurePrivateExistingFile(file);

    final bytes = await file.readAsBytes();
    if (bytes.length != 32) {
      throw StateError(
        'The local Redleaf vault key is incomplete or damaged. '
        'Saved logins cannot be decrypted.',
      );
    }
    return SecretKey(bytes);
  }

  Future<void> save({
    required String instanceId,
    required String username,
    required String password,
    String serverUrl = defaultServerUrl,
  }) async {
    final id = _validateInstanceId(instanceId);
    final user = username.trim();
    if (user.isEmpty || password.isEmpty) {
      throw ArgumentError('Enter a Redleaf username and password.');
    }
    final origin = normalizeServerUrl(serverUrl);
    await _prepare(create: true);
    final key = (await _getKey(create: true))!;

    final message = utf8.encode(jsonEncode(<String, Object>{
      'instanceId': id,
      'username': user,
      'password': password,
      'serverUrl': origin,
    }));

    final box = await _cipher.encrypt(
      message,
      secretKey: key,
      nonce: _randomBytes(_cipher.nonceLength),
      aad: utf8.encode('$namespace:$id'),
    );
    final envelope = utf8.encode(jsonEncode(<String, Object>{
      'version': storageVersion,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    }));

    await _LinuxPrivateFiles.atomicWrite(_entryFile(id), envelope);
  }

  Future<RedleafSavedCredentials?> read(String instanceId) async {
    final id = _validateInstanceId(instanceId);
    await _prepare(create: false);
    final entry = _entryFile(id);
    if (!await entry.exists()) return null;
    await _LinuxPrivateFiles.ensurePrivateExistingFile(entry);

    final key = await _getKey(create: false);
    if (key == null) {
      throw StateError('The Redleaf credential vault key is missing.');
    }
    try {
      final envelope = jsonDecode(await entry.readAsString());
      if (envelope is! Map<String, dynamic> ||
          envelope['version'] != storageVersion ||
          envelope['nonce'] is! String ||
          envelope['ciphertext'] is! String ||
          envelope['mac'] is! String) {
        throw const FormatException();
      }

      final box = SecretBox(
        base64Decode(envelope['ciphertext'] as String),
        nonce: base64Decode(envelope['nonce'] as String),
        mac: Mac(base64Decode(envelope['mac'] as String)),
      );
      final cleartext = await _cipher.decrypt(
        box,
        secretKey: key,
        aad: utf8.encode('$namespace:$id'),
      );
      final decoded = jsonDecode(utf8.decode(cleartext));
      if (decoded is! Map<String, dynamic> ||
          decoded['instanceId'] != id ||
          decoded['username'] is! String ||
          decoded['password'] is! String ||
          decoded['serverUrl'] is! String) {
        throw const FormatException();
      }
      final username = (decoded['username'] as String).trim();
      final password = decoded['password'] as String;
      if (username.isEmpty || password.isEmpty) throw const FormatException();

      return RedleafSavedCredentials(
        username: username,
        password: password,
        serverUrl: normalizeServerUrl(decoded['serverUrl'] as String),
      );
    } catch (_) {
      // Never leak a secret or cryptographic error into logs or UI.
      throw StateError(
        'This Redleaf saved login could not be decrypted. '
        'Replace it in Redleaf Hub.',
      );
    }
  }

  Future<void> delete(String instanceId) async {
    final id = _validateInstanceId(instanceId);
    await _prepare(create: false);
    final file = _entryFile(id);
    if (!await file.exists()) return;
    await _LinuxPrivateFiles.ensurePrivateExistingFile(file);
    await file.delete();
  }
}

/// Uses Linux libc for file mode enforcement. Dart's File.create defaults to
/// the user's umask, which can be world-readable; never use that for keys.
/// libc is part of the Linux runtime already required by Flutter desktop.
class _LinuxPrivateFiles {
  static final DynamicLibrary _libc = DynamicLibrary.open('libc.so.6');

  static final Pointer<Void> Function(int) _malloc = _libc.lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)>('malloc');
  static final void Function(Pointer<Void>) _free = _libc.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('free');
  static final int Function(Pointer<Uint8>, int) _mkdir =
      _libc.lookupFunction<
          Int32 Function(Pointer<Uint8>, Uint32),
          int Function(Pointer<Uint8>, int)>('mkdir');
  static final int Function(Pointer<Uint8>, int) _chmod =
      _libc.lookupFunction<
          Int32 Function(Pointer<Uint8>, Uint32),
          int Function(Pointer<Uint8>, int)>('chmod');
  static final int Function(Pointer<Uint8>, int, int) _open =
      _libc.lookupFunction<
          Int32 Function(Pointer<Uint8>, Int32, Uint32),
          int Function(Pointer<Uint8>, int, int)>('open');
  static final int Function(int) _close =
      _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final int Function(Pointer<Uint8>, Pointer<Uint8>) _link =
      _libc.lookupFunction<
          Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
          int Function(Pointer<Uint8>, Pointer<Uint8>)>('link');

  static const int _directoryMode = 0x1c0; // 0700
  static const int _fileMode = 0x180; // 0600
  // Linux O_CREAT|O_EXCL refuses an existing target, including a symlink.
  // Do not hardcode O_NOFOLLOW: its numerical value differs by architecture.
  // O_WRONLY | O_CREAT | O_EXCL is portable across Linux x86_64 and aarch64.
  static const int _writeExclusive = 1 | 0x40 | 0x80;

  static T _withPath<T>(String path, T Function(Pointer<Uint8>) action) {
    final utf8Bytes = utf8.encode(path);
    final memory = _malloc(utf8Bytes.length + 1);
    if (memory.address == 0) {
      throw StateError('Cannot allocate a private file path.');
    }
    final pointer = memory.cast<Uint8>();
    try {
      pointer.asTypedList(utf8Bytes.length + 1)
        ..setAll(0, utf8Bytes)
        ..[utf8Bytes.length] = 0;
      return action(pointer);
    } finally {
      _free(memory);
    }
  }

  static void _assertNoLink(String path) {
    final entity = FileSystemEntity.typeSync(path, followLinks: false);
    if (entity == FileSystemEntityType.link) {
      throw StateError('The Redleaf vault refuses symbolic links.');
    }
  }

  static Future<void> ensureDirectory(Directory directory) async {
    await directory.parent.create(recursive: true);
    _assertNoLink(directory.path);
    if (!await directory.exists()) {
      final result = _withPath(directory.path, (path) =>
          _mkdir(path, _directoryMode));
      if (result != 0 && !await directory.exists()) {
        throw StateError('Could not create the private Redleaf vault directory.');
      }
    }
    await ensurePrivateExistingDirectory(directory);
  }

  static Future<void> ensurePrivateExistingDirectory(
    Directory directory,
  ) async {
    _assertNoLink(directory.path);
    final stat = await directory.stat();
    if (stat.type != FileSystemEntityType.directory) {
      throw StateError('Redleaf vault directory path is not a directory.');
    }
    if ((stat.mode & 0x1ff) != _directoryMode) {
      final result =
          _withPath(directory.path, (path) => _chmod(path, _directoryMode));
      if (result != 0) {
        throw StateError('Could not secure Redleaf vault folder permissions.');
      }
    }
  }

  static Future<void> ensurePrivateExistingFile(File file) async {
    _assertNoLink(file.path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw StateError('Redleaf vault entry is not a regular file.');
    }
    if ((stat.mode & 0x1ff) != _fileMode) {
      final result =
          _withPath(file.path, (path) => _chmod(path, _fileMode));
      if (result != 0) {
        throw StateError('Could not secure Redleaf vault file permissions.');
      }
    }
  }

  static Future<void> writeNewFile(File file, List<int> bytes) async {
    _assertNoLink(file.path);
    final fd = _withPath(file.path, (path) =>
        _open(path, _writeExclusive, _fileMode));
    if (fd < 0) {
      throw StateError('Could not create a private Redleaf vault file.');
    }
    _close(fd);
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  static void linkIfMissing(String existing, String destination) {
    _assertNoLink(destination);
    final linked = _withPath(existing, (source) =>
        _withPath(destination, (target) => _link(source, target)));
    if (linked != 0 && !File(destination).existsSync()) {
      throw StateError('Could not initialize Redleaf vault encryption key.');
    }
  }

  static Future<void> atomicWrite(File target, List<int> bytes) async {
    _assertNoLink(target.path);
    final temporary = File(
      '${target.path}.tmp.$pid.${base64Url.encode(RedleafSharedCredentialVault._randomBytes(12))}',
    );
    await writeNewFile(temporary, bytes);
    try {
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
