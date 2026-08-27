// lib/services/redleaf_catalog_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'redleaf_connection_service.dart';

class RedleafCatalog {
  const RedleafCatalog({
    required this.id,
    required this.name,
    required this.type,
  });

  final int id;
  final String name;
  final String type;

  bool get isFavorites => type.toLowerCase() == 'favorites';
  bool get isPodcast => type.toLowerCase() == 'podcast';
  bool get isUser => type.toLowerCase() == 'user';
}

class RedleafCatalogService extends ChangeNotifier {
  RedleafCatalogService({
    RedleafConnectionService? connection,
  }) : _connection =
            connection ?? RedleafConnectionService.instance {
    _connection.addListener(_onConnectionChanged);
  }

  static const Duration _requestTimeout = Duration(seconds: 10);

  final RedleafConnectionService _connection;

  List<RedleafCatalog> _catalogs = const <RedleafCatalog>[];
  final Map<int, Set<int>> _srtMembershipCache = <int, Set<int>>{};

  bool _loading = false;
  String? _lastError;
  String _loadedInstanceId = '';

  List<RedleafCatalog> get catalogs =>
      List<RedleafCatalog>.unmodifiable(_catalogs);

  bool get loading => _loading;
  String? get lastError => _lastError;
  String get loadedInstanceId => _loadedInstanceId;

  bool get loaded =>
      _loadedInstanceId.isNotEmpty &&
      _connection.isConnected &&
      _loadedInstanceId == _connection.instanceId;

  bool loadedFor(String instanceId) {
    final normalized = instanceId.trim();
    return normalized.isNotEmpty &&
        _loadedInstanceId == normalized;
  }

  Map<int, Set<int>> get cachedSrtMemberships {
    return Map<int, Set<int>>.unmodifiable(
      <int, Set<int>>{
        for (final entry in _srtMembershipCache.entries)
          entry.key: Set<int>.unmodifiable(entry.value),
      },
    );
  }

  void loadCachedCatalogs({
    required String instanceId,
    required Iterable<RedleafCatalog> catalogs,
    required Map<int, Set<int>> catalogMemberships,
  }) {
    final normalizedInstanceId = instanceId.trim();
    if (normalizedInstanceId.isEmpty) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Redleaf instance ID cannot be empty.',
      );
    }

    if (_loading) {
      throw StateError(
        'Cannot replace Redleaf catalog state while a live refresh is running.',
      );
    }

    final byId = <int, RedleafCatalog>{
      for (final catalog in catalogs) catalog.id: catalog,
    };

    final cachedCatalogs = byId.values.toList(growable: false)
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(
              b.name.toLowerCase(),
            ),
      );

    final knownCatalogIds =
        cachedCatalogs.map((catalog) => catalog.id).toSet();

    _catalogs = List<RedleafCatalog>.unmodifiable(
      cachedCatalogs,
    );
    _srtMembershipCache.clear();

    for (final entry in catalogMemberships.entries) {
      if (!knownCatalogIds.contains(entry.key)) {
        continue;
      }
      _srtMembershipCache[entry.key] =
          Set<int>.from(entry.value);
    }

    _loadedInstanceId = normalizedInstanceId;
    _loading = false;
    _lastError = null;
    notifyListeners();
  }

  Future<bool> refreshCatalogs() async {
    if (!_connection.isConnected) {
      _setError('Connect to Redleaf in Settings.');
      return false;
    }

    if (_loading) {
      return false;
    }

    _loading = true;
    _lastError = null;
    notifyListeners();

    final client = HttpClient()
      ..connectionTimeout = _requestTimeout;

    try {
      final decoded = await _getJson(
        client,
        Uri.parse('${_connection.serverUrl}/api/catalogs/all'),
      );

      if (decoded is! List) {
        throw const FormatException(
          'catalog list response was not a JSON array',
        );
      }

      final catalogs = <RedleafCatalog>[];

      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }

        final id = _readInteger(raw['id']);
        final name = raw['name']?.toString().trim() ?? '';
        final type = raw['catalog_type']?.toString().trim() ?? '';

        if (id == null || name.isEmpty) {
          continue;
        }

        catalogs.add(
          RedleafCatalog(
            id: id,
            name: name,
            type: type,
          ),
        );
      }

      catalogs.sort(
        (a, b) => a.name.toLowerCase().compareTo(
              b.name.toLowerCase(),
            ),
      );

      _catalogs = List<RedleafCatalog>.unmodifiable(catalogs);
      _srtMembershipCache.clear();
      _loadedInstanceId = _connection.instanceId;
      _lastError = null;
      return true;
    } on TimeoutException {
      _setError('Timed out while reading Redleaf catalogs.');
      return false;
    } on SocketException catch (error) {
      final detail = error.message.trim();
      _setError(
        detail.isEmpty
            ? 'Could not read Redleaf catalogs.'
            : 'Could not read Redleaf catalogs: $detail',
      );
      return false;
    } on FormatException catch (error) {
      _setError(
        'Redleaf returned an unexpected catalog response: '
        '${error.message}',
      );
      return false;
    } catch (error) {
      _setError('Could not read Redleaf catalogs: $error');
      return false;
    } finally {
      client.close(force: true);
      _loading = false;
      notifyListeners();
    }
  }

  Future<Set<int>> srtDocumentIdsForCatalog(
    int catalogId, {
    bool forceRefresh = false,
  }) async {
    if (_loadedInstanceId.isEmpty) {
      throw StateError(
        'Load Redleaf catalogs before requesting catalog membership.',
      );
    }

    if (!_catalogs.any((catalog) => catalog.id == catalogId)) {
      throw ArgumentError.value(
        catalogId,
        'catalogId',
        'Redleaf catalog is not in the current catalog list.',
      );
    }

    if (!forceRefresh) {
      final cached = _srtMembershipCache[catalogId];
      if (cached != null) {
        return Set<int>.unmodifiable(cached);
      }
    }

    if (!_connection.isConnected) {
      throw StateError(
        'Connect to Redleaf in Settings to refresh catalog membership.',
      );
    }

    if (_loadedInstanceId != _connection.instanceId) {
      throw StateError(
        'The loaded Redleaf catalogs belong to a different Redleaf instance.',
      );
    }

    final client = HttpClient()
      ..connectionTimeout = _requestTimeout;

    try {
      final uri = Uri.parse(
        '${_connection.serverUrl}/api/documents_by_tags',
      ).replace(
        queryParameters: <String, String>{
          'catalog_id': '$catalogId',
        },
      );

      final decoded = await _getJson(client, uri);

      if (decoded is! List) {
        throw const FormatException(
          'catalog membership response was not a JSON array',
        );
      }

      final docIds = <int>{};

      for (final raw in decoded) {
        if (raw is! Map) {
          continue;
        }

        final fileType =
            raw['file_type']?.toString().trim().toUpperCase() ?? '';

        // Keep the same forensic rule as SRT discovery:
        // only explicit SRT rows qualify. Do not infer by filename.
        if (fileType != 'SRT') {
          continue;
        }

        final docId = _readInteger(raw['doc_id']);
        if (docId != null) {
          docIds.add(docId);
        }
      }

      _srtMembershipCache[catalogId] = Set<int>.from(docIds);
      _lastError = null;
      notifyListeners();

      return Set<int>.unmodifiable(docIds);
    } on TimeoutException {
      const message =
          'Timed out while reading Redleaf catalog membership.';
      _setError(message);
      throw StateError(message);
    } on SocketException catch (error) {
      final detail = error.message.trim();
      final message = detail.isEmpty
          ? 'Could not read Redleaf catalog membership.'
          : 'Could not read Redleaf catalog membership: $detail';
      _setError(message);
      throw StateError(message);
    } on FormatException catch (error) {
      final message =
          'Redleaf returned an unexpected catalog-membership response: '
          '${error.message}';
      _setError(message);
      throw StateError(message);
    } catch (error) {
      if (error is StateError || error is ArgumentError) {
        rethrow;
      }

      final message =
          'Could not read Redleaf catalog membership: $error';
      _setError(message);
      throw StateError(message);
    } finally {
      client.close(force: true);
    }
  }

  void clear() {
    final changed = _catalogs.isNotEmpty ||
        _srtMembershipCache.isNotEmpty ||
        _loadedInstanceId.isNotEmpty ||
        _lastError != null;

    _catalogs = const <RedleafCatalog>[];
    _srtMembershipCache.clear();
    _loadedInstanceId = '';
    _lastError = null;

    if (changed) {
      notifyListeners();
    }
  }

  Future<dynamic> _getJson(
    HttpClient client,
    Uri uri,
  ) async {
    final request = await client.getUrl(uri).timeout(_requestTimeout);
    request.followRedirects = false;

    if (_connection.sessionCookie.isNotEmpty) {
      request.headers.set(
        HttpHeaders.cookieHeader,
        _connection.sessionCookie,
      );
    }

    final response = await request.close().timeout(_requestTimeout);
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(_requestTimeout);

    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Redleaf returned HTTP ${response.statusCode}.',
        uri: uri,
      );
    }

    if (body.trimLeft().startsWith('<')) {
      throw const FormatException(
        'received HTML instead of JSON',
      );
    }

    return jsonDecode(body);
  }

  void _onConnectionChanged() {
    final currentInstanceId =
        _connection.isConnected ? _connection.instanceId : '';

    // Cached state deliberately survives disconnect. A different connected
    // Redleaf instance invalidates the in-memory state so data from separate
    // databases can never be mixed.
    if (currentInstanceId.isNotEmpty &&
        _loadedInstanceId.isNotEmpty &&
        currentInstanceId != _loadedInstanceId) {
      clear();
    }
  }

  void _setError(String message) {
    _lastError = message;
    notifyListeners();
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

  @override
  void dispose() {
    _connection.removeListener(_onConnectionChanged);
    super.dispose();
  }
}
