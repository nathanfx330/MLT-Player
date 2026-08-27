// lib/services/redleaf_connection_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum RedleafConnectionStatus {
  disconnected,
  signingIn,
  connected,
  error,
}

class RedleafConnectionService extends ChangeNotifier {
  RedleafConnectionService({Directory? configDirectory})
      : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  static final RedleafConnectionService instance = RedleafConnectionService();

  static const String defaultServerUrl = 'http://127.0.0.1:5000';
  static const Duration _requestTimeout = Duration(seconds: 10);
  static const String _inventoryNullProbeType =
      '__MLT_PLAYER_INVENTORY_NULL_PROBE__';

  final Directory _configDirectory;

  bool _loaded = false;
  String _serverUrl = defaultServerUrl;
  String _username = '';
  String _sessionCookie = '';
  String _csrfToken = '';
  String _instanceId = '';
  String _projectName = '';
  String _baseDirectory = '';
  int _totalDocumentCount = 0;
  int _unknownFileTypeCount = 0;
  Map<String, int> _fileTypeCounts = <String, int>{};
  bool _inventoryLoaded = false;
  String? _inventoryError;
  String? _lastError;
  RedleafConnectionStatus _status = RedleafConnectionStatus.disconnected;

  String get serverUrl => _serverUrl;
  String get username => _username;
  String get sessionCookie => _sessionCookie;
  String get csrfToken => _csrfToken;
  String get instanceId => _instanceId;
  String get projectName => _projectName;
  String get baseDirectory => _baseDirectory;
  int get totalDocumentCount => _totalDocumentCount;
  int get unknownFileTypeCount => _unknownFileTypeCount;
  Map<String, int> get fileTypeCounts =>
      Map<String, int>.unmodifiable(_fileTypeCounts);
  bool get inventoryLoaded => _inventoryLoaded;
  String? get inventoryError => _inventoryError;
  String? get lastError => _lastError;
  RedleafConnectionStatus get status => _status;

  bool get isConnected =>
      _status == RedleafConnectionStatus.connected &&
      _sessionCookie.isNotEmpty &&
      _instanceId.isNotEmpty;

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;

    final file = _stateFile;
    if (!await file.exists()) {
      return;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final rawServer = decoded['serverUrl'];
      final rawUsername = decoded['username'];

      if (rawServer is String && rawServer.trim().isNotEmpty) {
        _serverUrl = _normalizeServerUrl(rawServer);
      }
      if (rawUsername is String) {
        _username = rawUsername.trim();
      }

      // A saved server and username are convenience state only. Sessions are
      // deliberately not persisted, so every application launch starts in a
      // disconnected state until the user signs in again.
      _status = RedleafConnectionStatus.disconnected;
      _lastError = null;
      notifyListeners();
    } catch (_) {
      // A damaged convenience file must never prevent MLT Player from opening.
      _serverUrl = defaultServerUrl;
      _username = '';
      _status = RedleafConnectionStatus.disconnected;
      _lastError = null;
    }
  }

  Future<bool> signIn({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    if (_status == RedleafConnectionStatus.signingIn) {
      return false;
    }

    String normalizedServer;
    try {
      normalizedServer = _normalizeServerUrl(serverUrl);
    } on FormatException catch (error) {
      _setError(error.message);
      return false;
    }

    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty || password.isEmpty) {
      _setError('Enter your Redleaf username and password.');
      return false;
    }

    _serverUrl = normalizedServer;
    _username = normalizedUsername;
    _sessionCookie = '';
    _csrfToken = '';
    _instanceId = '';
    _projectName = '';
    _baseDirectory = '';
    _clearInventory();
    _lastError = null;
    _status = RedleafConnectionStatus.signingIn;
    notifyListeners();

    final client = HttpClient()..connectionTimeout = _requestTimeout;

    try {
      final loginUri = Uri.parse('$_serverUrl/login');

      final getRequest = await client.getUrl(loginUri).timeout(_requestTimeout);
      getRequest.followRedirects = false;
      final getResponse = await getRequest.close().timeout(_requestTimeout);
      _captureSessionCookie(getResponse);
      final loginHtml = await _readBody(getResponse).timeout(_requestTimeout);

      if (getResponse.statusCode != HttpStatus.ok) {
        _setError(
          'Redleaf returned HTTP ${getResponse.statusCode} while opening the sign-in page.',
        );
        return false;
      }

      _csrfToken = _extractCsrfToken(loginHtml);
      if (_csrfToken.isEmpty) {
        _setError(
          'The Redleaf sign-in page did not provide a CSRF token. Check that this is a Redleaf server.',
        );
        return false;
      }

      final postRequest =
          await client.postUrl(loginUri).timeout(_requestTimeout);
      postRequest.followRedirects = false;
      if (_sessionCookie.isNotEmpty) {
        postRequest.headers.set(HttpHeaders.cookieHeader, _sessionCookie);
      }
      postRequest.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      postRequest.write(
        Uri(
          queryParameters: <String, String>{
            'csrf_token': _csrfToken,
            'username': _username,
            'password': password,
          },
        ).query,
      );

      final postResponse = await postRequest.close().timeout(_requestTimeout);
      _captureSessionCookie(postResponse);
      await _readBody(postResponse).timeout(_requestTimeout);

      if (!_isRedirect(postResponse.statusCode) || _sessionCookie.isEmpty) {
        _setError('Redleaf sign-in failed. Check your username and password.');
        return false;
      }

      await _refreshCsrfToken(client);

      final info = await _fetchSystemInfo(client);
      if (info == null) {
        _setError(
          'Signed in, but Redleaf did not return system information. Check the server and try again.',
        );
        return false;
      }

      final instanceId = (info['instance_id'] ?? '').toString().trim();
      if (instanceId.isEmpty) {
        _setError(
          'The server responded, but it did not identify a Redleaf database instance.',
        );
        return false;
      }

      _instanceId = instanceId;
      _projectName = (info['project_name'] ?? 'Redleaf').toString().trim();
      _baseDirectory = (info['base_dir'] ?? '').toString().trim();

      // Sign-in establishes identity and session only. Project inventory is
      // refreshed explicitly by the Redleaf project's SYNC NOW action.
      _lastError = null;
      _status = RedleafConnectionStatus.connected;
      notifyListeners();

      await _saveConnectionHint();
      return true;
    } on TimeoutException {
      _setError('Timed out while contacting Redleaf at $_serverUrl.');
      return false;
    } on SocketException catch (error) {
      final detail = error.message.trim();
      _setError(
        detail.isEmpty
            ? 'Could not connect to Redleaf at $_serverUrl.'
            : 'Could not connect to Redleaf: $detail',
      );
      return false;
    } on HandshakeException catch (error) {
      _setError('TLS connection to Redleaf failed: ${error.message}');
      return false;
    } on FormatException catch (error) {
      _setError('Redleaf returned an unexpected response: ${error.message}');
      return false;
    } catch (error) {
      _setError('Could not sign in to Redleaf: $error');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> refreshInventory() async {
    if (!isConnected) {
      return;
    }

    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      await _fetchInventory(client);
      notifyListeners();
    } finally {
      client.close(force: true);
    }
  }

  void disconnect() {
    _sessionCookie = '';
    _csrfToken = '';
    _instanceId = '';
    _projectName = '';
    _baseDirectory = '';
    _clearInventory();
    _lastError = null;
    _status = RedleafConnectionStatus.disconnected;
    notifyListeners();
  }

  Future<void> _refreshCsrfToken(HttpClient client) async {
    try {
      final request = await client
          .getUrl(Uri.parse('$_serverUrl/dashboard'))
          .timeout(_requestTimeout);
      request.followRedirects = false;
      if (_sessionCookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, _sessionCookie);
      }

      final response = await request.close().timeout(_requestTimeout);
      _captureSessionCookie(response);
      final body = await _readBody(response).timeout(_requestTimeout);
      if (response.statusCode == HttpStatus.ok) {
        final token = _extractCsrfToken(body);
        if (token.isNotEmpty) {
          _csrfToken = token;
        }
      }
    } catch (_) {
      // GET-only Redleaf Media discovery can still work if this refresh fails.
      // A later write operation can explicitly refresh before posting.
    }
  }

  Future<Map<String, dynamic>?> _fetchSystemInfo(HttpClient client) async {
    final request = await client
        .getUrl(Uri.parse('$_serverUrl/api/system/info'))
        .timeout(_requestTimeout);
    request.followRedirects = false;
    if (_sessionCookie.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, _sessionCookie);
    }

    final response = await request.close().timeout(_requestTimeout);
    _captureSessionCookie(response);
    final body = await _readBody(response).timeout(_requestTimeout);

    if (response.statusCode != HttpStatus.ok) {
      return null;
    }

    if (body.trimLeft().startsWith('<')) {
      throw const FormatException(
        'received HTML instead of the Redleaf system-info JSON',
      );
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('system-info response was not a JSON object');
    }
    return decoded;
  }

  Future<void> _fetchInventory(HttpClient client) async {
    try {
      final summary = await _fetchDashboardStatus(
        client,
        const <String, String>{
          'page': '1',
          'per_page': '1',
        },
      );

      if (summary == null) {
        _inventoryLoaded = false;
        _inventoryError =
            'Connected, but Redleaf did not provide file inventory.';
        return;
      }

      final totalDocuments = _readInteger(summary['total_documents']);
      if (totalDocuments == null) {
        throw const FormatException(
          'dashboard inventory did not include total_documents',
        );
      }

      final rawTypes = summary['all_types'];
      if (rawTypes is! List) {
        throw const FormatException(
          'dashboard inventory did not include all_types',
        );
      }

      final fileTypes = rawTypes
          .map((value) => value?.toString() ?? '')
          .where((value) => value != _inventoryNullProbeType)
          .toSet()
          .toList()
        ..sort((a, b) => a.toUpperCase().compareTo(b.toUpperCase()));

      final nullProbe = await _fetchDashboardStatus(
        client,
        const <String, String>{
          'page': '1',
          'per_page': '1',
          'filtered': '1',
          'type': _inventoryNullProbeType,
        },
      );
      final nullTypeCount =
          _readInteger(nullProbe?['total_documents']) ?? 0;

      final counts = <String, int>{};
      var blankTypeCount = 0;

      for (final fileType in fileTypes) {
        final typeSummary = await _fetchDashboardStatus(
          client,
          <String, String>{
            'page': '1',
            'per_page': '1',
            'filtered': '1',
            'type': fileType,
          },
        );

        final filteredTotal = _readInteger(typeSummary?['total_documents']);
        if (filteredTotal == null) {
          throw FormatException(
            'dashboard inventory did not return a count for ${fileType.isEmpty ? 'files without an extension' : fileType}',
          );
        }

        final actualCount = filteredTotal > nullTypeCount
            ? filteredTotal - nullTypeCount
            : 0;

        if (fileType.trim().isEmpty) {
          blankTypeCount += actualCount;
        } else {
          counts[fileType] = actualCount;
        }
      }

      _totalDocumentCount = totalDocuments;
      _unknownFileTypeCount = nullTypeCount + blankTypeCount;
      _fileTypeCounts = counts;
      _inventoryLoaded = true;
      _inventoryError = null;
    } on TimeoutException {
      _inventoryLoaded = false;
      _inventoryError = 'Timed out while reading Redleaf file inventory.';
    } on SocketException catch (error) {
      final detail = error.message.trim();
      _inventoryLoaded = false;
      _inventoryError = detail.isEmpty
          ? 'Could not read Redleaf file inventory.'
          : 'Could not read Redleaf file inventory: $detail';
    } on FormatException catch (error) {
      _inventoryLoaded = false;
      _inventoryError = 'Could not read Redleaf file inventory: ${error.message}';
    } catch (error) {
      _inventoryLoaded = false;
      _inventoryError = 'Could not read Redleaf file inventory: $error';
    }
  }

  Future<Map<String, dynamic>?> _fetchDashboardStatus(
    HttpClient client,
    Map<String, String> queryParameters,
  ) async {
    final uri = Uri.parse('$_serverUrl/api/dashboard/status').replace(
      queryParameters: queryParameters,
    );

    final request = await client.getUrl(uri).timeout(_requestTimeout);
    request.followRedirects = false;
    if (_sessionCookie.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, _sessionCookie);
    }

    final response = await request.close().timeout(_requestTimeout);
    _captureSessionCookie(response);
    final body = await _readBody(response).timeout(_requestTimeout);

    if (response.statusCode != HttpStatus.ok) {
      return null;
    }

    if (body.trimLeft().startsWith('<')) {
      return null;
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'dashboard inventory response was not a JSON object',
      );
    }
    return decoded;
  }

  static int? _readInteger(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  void _clearInventory() {
    _totalDocumentCount = 0;
    _unknownFileTypeCount = 0;
    _fileTypeCounts = <String, int>{};
    _inventoryLoaded = false;
    _inventoryError = null;
  }

  void _captureSessionCookie(HttpClientResponse response) {
    for (final cookie in response.cookies) {
      if (cookie.name != 'session') {
        continue;
      }
      final value = cookie.value.trim();
      if (value.isEmpty || value == 'deleted') {
        continue;
      }
      _sessionCookie = 'session=$value';
    }
  }

  static Future<String> _readBody(HttpClientResponse response) =>
      response.transform(utf8.decoder).join();

  static String _extractCsrfToken(String html) {
    final inputPattern = RegExp(
      r'<input\b[^>]*>',
      caseSensitive: false,
    );
    final namePattern = RegExp(
      "name\\s*=\\s*['\"]csrf_token['\"]",
      caseSensitive: false,
    );
    final valuePattern = RegExp(
      "value\\s*=\\s*['\"]([^'\"]+)['\"]",
      caseSensitive: false,
    );

    for (final match in inputPattern.allMatches(html)) {
      final tag = match.group(0) ?? '';
      if (!namePattern.hasMatch(tag)) {
        continue;
      }
      return valuePattern.firstMatch(tag)?.group(1) ?? '';
    }
    return '';
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == HttpStatus.movedPermanently ||
      statusCode == HttpStatus.found ||
      statusCode == HttpStatus.seeOther ||
      statusCode == HttpStatus.temporaryRedirect ||
      statusCode == HttpStatus.permanentRedirect;

  static String _normalizeServerUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Enter the Redleaf server address.');
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException(
        'Use a full Redleaf address such as http://127.0.0.1:5000.',
      );
    }

    var normalized = trimmed;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  void _setError(String message) {
    _sessionCookie = '';
    _csrfToken = '';
    _instanceId = '';
    _projectName = '';
    _baseDirectory = '';
    _clearInventory();
    _lastError = message;
    _status = RedleafConnectionStatus.error;
    notifyListeners();
  }

  Future<void> _saveConnectionHint() async {
    final contents = jsonEncode(<String, Object>{
      'version': 1,
      'serverUrl': _serverUrl,
      'username': _username,
    });

    try {
      await _configDirectory.create(recursive: true);
      await _stateFile.writeAsString(contents, flush: true);
    } catch (_) {
      // Being connected is more important than saving convenience fields.
    }
  }

  File get _stateFile =>
      File('${_configDirectory.path}/redleaf_connection.json');

  static Directory _defaultConfigDirectory() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.trim().isNotEmpty) {
      return Directory('${xdg.trim()}/mlt_player');
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return Directory('${home.trim()}/.config/mlt_player');
    }

    return Directory('${Directory.systemTemp.path}/mlt_player');
  }
}
