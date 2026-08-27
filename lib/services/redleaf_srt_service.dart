// lib/services/redleaf_srt_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'redleaf_connection_service.dart';

enum RedleafMediaLinkState {
  unknown,
  notLinked,
  linked,
}

class RedleafMediaLink {
  const RedleafMediaLink({
    required this.state,
    this.path,
    this.type,
    this.source,
    this.positionSeconds,
    this.offsetSeconds,
  });

  const RedleafMediaLink.unknown()
      : state = RedleafMediaLinkState.unknown,
        path = null,
        type = null,
        source = null,
        positionSeconds = null,
        offsetSeconds = null;

  const RedleafMediaLink.notLinked()
      : state = RedleafMediaLinkState.notLinked,
        path = null,
        type = null,
        source = null,
        positionSeconds = null,
        offsetSeconds = null;

  final RedleafMediaLinkState state;
  final String? path;
  final String? type;
  final String? source;
  final double? positionSeconds;
  final double? offsetSeconds;

  bool get isKnown => state != RedleafMediaLinkState.unknown;
  bool get isLinked => state == RedleafMediaLinkState.linked;
  bool get isAudio => isLinked && type == 'audio';
  bool get isVideo => isLinked && type == 'video';

  RedleafMediaLink copyWith({
    RedleafMediaLinkState? state,
    String? path,
    String? type,
    String? source,
    double? positionSeconds,
    double? offsetSeconds,
  }) {
    return RedleafMediaLink(
      state: state ?? this.state,
      path: path ?? this.path,
      type: type ?? this.type,
      source: source ?? this.source,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      offsetSeconds: offsetSeconds ?? this.offsetSeconds,
    );
  }
}

class RedleafSrtDocument {
  const RedleafSrtDocument({
    required this.docId,
    required this.relativePath,
    required this.status,
    required this.media,
    this.statusMessage,
    this.processedAt,
    this.color,
    this.fileSizeBytes,
    this.durationSeconds,
    this.tagCount = 0,
  });

  final int docId;
  final String relativePath;
  final String status;
  final String? statusMessage;
  final String? processedAt;
  final String? color;
  final int? fileSizeBytes;
  final double? durationSeconds;
  final int tagCount;
  final RedleafMediaLink media;

  String get fileName {
    final normalized = relativePath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }

  bool get hasMedia => media.isLinked;

  RedleafSrtDocument copyWith({
    RedleafMediaLink? media,
  }) {
    return RedleafSrtDocument(
      docId: docId,
      relativePath: relativePath,
      status: status,
      statusMessage: statusMessage,
      processedAt: processedAt,
      color: color,
      fileSizeBytes: fileSizeBytes,
      durationSeconds: durationSeconds,
      tagCount: tagCount,
      media: media ?? this.media,
    );
  }
}

class RedleafSrtDiscoveryService extends ChangeNotifier {
  RedleafSrtDiscoveryService({
    RedleafConnectionService? connection,
  }) : _connection = connection ?? RedleafConnectionService.instance;

  static const Duration _requestTimeout = Duration(seconds: 10);
  static const int _pageSize = 100;
  static const int _mediaBatchSize = 12;

  final RedleafConnectionService _connection;

  List<RedleafSrtDocument> _documents = const <RedleafSrtDocument>[];
  bool _loading = false;
  bool _scanningMedia = false;
  String? _lastError;
  int _expectedSrtCount = 0;
  int _mediaCheckedCount = 0;
  String _loadedInstanceId = '';

  List<RedleafSrtDocument> get documents =>
      List<RedleafSrtDocument>.unmodifiable(_documents);

  bool get loading => _loading;
  bool get scanningMedia => _scanningMedia;
  String? get lastError => _lastError;
  int get expectedSrtCount => _expectedSrtCount;
  int get mediaCheckedCount => _mediaCheckedCount;
  String get loadedInstanceId => _loadedInstanceId;

  int get documentCount => _documents.length;

  int get linkedMediaCount =>
      _documents.where((document) => document.media.isLinked).length;

  int get transcriptOnlyCount => _documents
      .where((document) => document.media.state == RedleafMediaLinkState.notLinked)
      .length;

  int get unknownMediaCount => _documents
      .where((document) => document.media.state == RedleafMediaLinkState.unknown)
      .length;

  bool get hasCompleteMediaScan =>
      _documents.isNotEmpty &&
      _mediaCheckedCount == _documents.length &&
      unknownMediaCount == 0;

  Future<bool> refresh() async {
    if (_loading) {
      return false;
    }

    if (!_connection.isConnected) {
      _documents = const <RedleafSrtDocument>[];
      _expectedSrtCount = 0;
      _mediaCheckedCount = 0;
      _loadedInstanceId = '';
      _lastError = 'Connect to Redleaf in Settings before loading SRTs.';
      notifyListeners();
      return false;
    }

    _loading = true;
    _scanningMedia = false;
    _lastError = null;
    _mediaCheckedCount = 0;
    _expectedSrtCount = _readInventorySrtCount();
    notifyListeners();

    final client = HttpClient()..connectionTimeout = _requestTimeout;

    try {
      final fetched = await _fetchAllSrtDocuments(client);

      if (_expectedSrtCount > 0 && fetched.length != _expectedSrtCount) {
        throw StateError(
          'Redleaf reported $_expectedSrtCount SRTs in inventory, '
          'but discovery returned ${fetched.length}.',
        );
      }

      _documents = fetched;
      _loadedInstanceId = _connection.instanceId;
      _loading = false;
      _scanningMedia = fetched.isNotEmpty;
      notifyListeners();

      if (fetched.isNotEmpty) {
        await _scanMediaStatuses(client);
      }

      _scanningMedia = false;
      _lastError = null;
      notifyListeners();
      return true;
    } on TimeoutException {
      _lastError = 'Timed out while reading SRTs from Redleaf.';
    } on SocketException catch (error) {
      final detail = error.message.trim();
      _lastError = detail.isEmpty
          ? 'Could not read SRTs from Redleaf.'
          : 'Could not read SRTs from Redleaf: $detail';
    } on FormatException catch (error) {
      _lastError = 'Redleaf returned unexpected SRT data: ${error.message}';
    } catch (error) {
      _lastError = 'Could not read Redleaf SRTs: $error';
    } finally {
      _loading = false;
      _scanningMedia = false;
      client.close(force: true);
      notifyListeners();
    }

    return false;
  }

  Future<bool> refreshMediaStatusForDocument(int docId) async {
    if (_loading || _scanningMedia) {
      _lastError =
          'Wait for the current Redleaf refresh before checking one media link.';
      notifyListeners();
      return false;
    }

    if (!_connection.isConnected) {
      _lastError =
          'Connect to Redleaf before refreshing this media relationship.';
      notifyListeners();
      return false;
    }

    if (_loadedInstanceId.isEmpty ||
        _loadedInstanceId != _connection.instanceId) {
      _lastError =
          'The loaded SRTs belong to a different Redleaf instance.';
      notifyListeners();
      return false;
    }

    final index = _documents.indexWhere(
      (document) => document.docId == docId,
    );
    if (index < 0) {
      throw ArgumentError.value(
        docId,
        'docId',
        'Redleaf SRT is not in the current discovery set.',
      );
    }

    final client = HttpClient()..connectionTimeout = _requestTimeout;

    try {
      final media = await _fetchMediaStatus(client, docId);
      if (!media.isKnown) {
        _lastError =
            'Could not verify the updated Redleaf media relationship.';
        notifyListeners();
        return false;
      }

      final previous = _documents[index];
      final previousKnown = previous.media.isKnown;

      final updated = List<RedleafSrtDocument>.from(_documents);
      updated[index] = previous.copyWith(media: media);
      _documents = List<RedleafSrtDocument>.unmodifiable(updated);

      if (!previousKnown && media.isKnown) {
        _mediaCheckedCount += 1;
      }

      _lastError = null;
      notifyListeners();
      return true;
    } finally {
      client.close(force: true);
    }
  }

  void loadCachedDocuments({
    required String instanceId,
    required Iterable<RedleafSrtDocument> documents,
  }) {
    final normalizedInstanceId = instanceId.trim();
    if (normalizedInstanceId.isEmpty) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Redleaf instance ID cannot be empty.',
      );
    }

    if (_loading || _scanningMedia) {
      throw StateError(
        'Cannot replace Redleaf discovery state while a live refresh is running.',
      );
    }

    final byId = <int, RedleafSrtDocument>{
      for (final document in documents) document.docId: document,
    };

    final cached = byId.values.toList(growable: false)
      ..sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
              b.relativePath.toLowerCase(),
            ),
      );

    _documents = List<RedleafSrtDocument>.unmodifiable(cached);
    _loadedInstanceId = normalizedInstanceId;
    _loading = false;
    _scanningMedia = false;
    _lastError = null;
    _expectedSrtCount = cached.length;
    _mediaCheckedCount =
        cached.where((document) => document.media.isKnown).length;
    notifyListeners();
  }

  void clear() {
    _documents = const <RedleafSrtDocument>[];
    _loading = false;
    _scanningMedia = false;
    _lastError = null;
    _expectedSrtCount = 0;
    _mediaCheckedCount = 0;
    _loadedInstanceId = '';
    notifyListeners();
  }

  int _readInventorySrtCount() {
    for (final entry in _connection.fileTypeCounts.entries) {
      if (entry.key.trim().toUpperCase() == 'SRT') {
        return entry.value;
      }
    }
    return 0;
  }

  Future<List<RedleafSrtDocument>> _fetchAllSrtDocuments(
    HttpClient client,
  ) async {
    final byId = <int, RedleafSrtDocument>{};
    var page = 1;
    var dashboardTotal = 0;

    while (true) {
      final data = await _getJsonObject(
        client,
        Uri.parse('${_connection.serverUrl}/api/dashboard/status').replace(
          queryParameters: <String, String>{
            'page': '$page',
            'per_page': '$_pageSize',
            'sort_key': 'relative_path',
            'sort_dir': 'asc',
            'filtered': '1',
            'type': 'SRT',
          },
        ),
      );

      dashboardTotal = _readInt(data['total_documents']) ?? dashboardTotal;

      final rawDocuments = data['documents'];
      if (rawDocuments is! List) {
        throw const FormatException(
          'dashboard response did not include a documents list',
        );
      }

      for (final raw in rawDocuments) {
        if (raw is! Map) {
          continue;
        }

        final row = Map<String, dynamic>.from(raw);
        final fileType = (row['file_type'] ?? '').toString().trim().toUpperCase();

        // Redleaf's current dashboard filter intentionally includes NULL
        // file_type rows. Phase C is SRT-only, so only explicit SRT rows enter
        // the Redleaf workspace.
        if (fileType != 'SRT') {
          continue;
        }

        final document = _documentFromDashboardRow(row);
        byId[document.docId] = document;
      }

      final consumed = page * _pageSize;
      if (rawDocuments.isEmpty || consumed >= dashboardTotal) {
        break;
      }

      page += 1;
    }

    final result = byId.values.toList()
      ..sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
              b.relativePath.toLowerCase(),
            ),
      );

    return result;
  }

  RedleafSrtDocument _documentFromDashboardRow(
    Map<String, dynamic> row,
  ) {
    final docId = _readInt(row['id']);
    if (docId == null) {
      throw const FormatException('an SRT row did not include a document id');
    }

    final relativePath = (row['relative_path'] ?? '').toString().trim();
    if (relativePath.isEmpty) {
      throw FormatException('Redleaf document $docId did not include a path');
    }

    return RedleafSrtDocument(
      docId: docId,
      relativePath: relativePath,
      status: (row['status'] ?? '').toString(),
      statusMessage: _readOptionalString(row['status_message']),
      processedAt: _readOptionalString(row['processed_at']),
      color: _readOptionalString(row['color']),
      fileSizeBytes: _readInt(row['file_size_bytes']),
      durationSeconds: _readDouble(row['duration_seconds']),
      tagCount: _readInt(row['tag_count']) ?? 0,
      media: const RedleafMediaLink.unknown(),
    );
  }

  Future<void> _scanMediaStatuses(HttpClient client) async {
    var start = 0;

    while (start < _documents.length) {
      final end = (start + _mediaBatchSize < _documents.length)
          ? start + _mediaBatchSize
          : _documents.length;

      final batch = _documents.sublist(start, end);

      final results = await Future.wait(
        batch.map(
          (document) async {
            final media = await _fetchMediaStatus(client, document.docId);
            return (docId: document.docId, media: media);
          },
        ),
      );

      final updates = <int, RedleafMediaLink>{
        for (final result in results) result.docId: result.media,
      };

      _documents = [
        for (final document in _documents)
          if (updates.containsKey(document.docId))
            document.copyWith(media: updates[document.docId])
          else
            document,
      ];

      _mediaCheckedCount += batch.length;
      notifyListeners();

      start = end;
    }
  }

  Future<RedleafMediaLink> _fetchMediaStatus(
    HttpClient client,
    int docId,
  ) async {
    try {
      final data = await _getJsonObject(
        client,
        Uri.parse(
          '${_connection.serverUrl}/api/document/$docId/media_status',
        ),
      );

      final linked = data['linked'] == true;
      if (!linked) {
        return const RedleafMediaLink.notLinked();
      }

      return RedleafMediaLink(
        state: RedleafMediaLinkState.linked,
        path: _readOptionalString(data['path']),
        type: _readOptionalString(data['type'])?.toLowerCase(),
        source: _readOptionalString(data['source'])?.toLowerCase(),
        positionSeconds: _readDouble(data['position']),
        offsetSeconds: _readDouble(data['offset']),
      );
    } catch (_) {
      // A failed media-status read must not make an SRT look unlinked.
      // Unknown is deliberately distinct from Redleaf explicitly saying
      // linked:false.
      return const RedleafMediaLink.unknown();
    }
  }

  Future<Map<String, dynamic>> _getJsonObject(
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
    final body = await response.transform(utf8.decoder).join().timeout(
          _requestTimeout,
        );

    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Redleaf returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }

    if (body.trimLeft().startsWith('<')) {
      throw const FormatException('received HTML instead of JSON');
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('response was not a JSON object');
    }

    return decoded;
  }

  static int? _readInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _readDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static String? _readOptionalString(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}
