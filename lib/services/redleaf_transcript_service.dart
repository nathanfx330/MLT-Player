// lib/services/redleaf_transcript_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'redleaf_connection_service.dart';
import 'redleaf_srt_service.dart';
import 'srt_subtitle_service.dart';

class RedleafTranscript {
  const RedleafTranscript({
    required this.instanceId,
    required this.docId,
    required this.relativePath,
    required this.track,
    this.metadataJson,
  });

  final String instanceId;
  final int docId;
  final String relativePath;
  final SubtitleTrack track;
  final String? metadataJson;

  String get sourceKey => 'redleaf:$instanceId:document:$docId';

  int get cueCount => track.cues.length;
}

class RedleafTranscriptService {
  RedleafTranscriptService({
    RedleafConnectionService? connection,
  }) : _connection = connection ?? RedleafConnectionService.instance;

  static const Duration _requestTimeout = Duration(seconds: 10);

  final RedleafConnectionService _connection;

  Future<RedleafTranscript> loadForDocument(
    RedleafSrtDocument document,
  ) async {
    if (!_connection.isConnected) {
      throw StateError(
        'Connect to Redleaf before loading a transcript.',
      );
    }

    final instanceId = _connection.instanceId;
    if (instanceId.isEmpty) {
      throw StateError(
        'The connected Redleaf server did not provide an instance ID.',
      );
    }

    final relativePath = _normalizePath(document.relativePath);
    if (relativePath.isEmpty) {
      throw FormatException(
        'Redleaf transcript document ${document.docId} '
        'did not provide an SRT path.',
      );
    }

    final pathSegments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);

    if (pathSegments.isEmpty ||
        pathSegments.any(
          (segment) => segment == '.' || segment == '..',
        )) {
      throw FormatException(
        'Redleaf transcript document ${document.docId} '
        'contains an unsafe SRT path.',
      );
    }

    final uri = _servedDocumentUri(pathSegments);
    final client = HttpClient()..connectionTimeout = _requestTimeout;

    try {
      final request = await client.getUrl(uri).timeout(_requestTimeout);
      request.followRedirects = false;

      if (_connection.sessionCookie.isNotEmpty) {
        request.headers.set(
          HttpHeaders.cookieHeader,
          _connection.sessionCookie,
        );
      }

      final response = await request.close().timeout(_requestTimeout);
      final bytes = <int>[];

      await for (final chunk in response.timeout(_requestTimeout)) {
        bytes.addAll(chunk);
      }

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Redleaf returned HTTP ${response.statusCode} '
          'while loading SRT document ${document.docId}.',
          uri: uri,
        );
      }

      if (!_connection.isConnected ||
          _connection.instanceId != instanceId) {
        throw StateError(
          'The active Redleaf project changed while the transcript was loading.',
        );
      }

      final source = _decodeSrtBytes(bytes);
      final sourceKey =
          'redleaf:$instanceId:document:${document.docId}';
      final track = SrtSubtitleService.parse(
        source,
        path: sourceKey,
      );

      return RedleafTranscript(
        instanceId: instanceId,
        docId: document.docId,
        relativePath: relativePath,
        track: track,
      );
    } on TimeoutException {
      throw TimeoutException(
        'Timed out while loading Redleaf SRT '
        'document ${document.docId}.',
        _requestTimeout,
      );
    } finally {
      client.close(force: true);
    }
  }

  Uri _servedDocumentUri(List<String> relativePathSegments) {
    final base = Uri.parse(_connection.serverUrl);
    final baseSegments = base.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);

    return base.replace(
      pathSegments: <String>[
        ...baseSegments,
        'serve_doc',
        ...relativePathSegments,
      ],
      query: null,
      fragment: null,
    );
  }

  static String _normalizePath(String path) {
    return path.replaceAll(r'\', '/').trim();
  }

  static String _decodeSrtBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return _decodeWindows1252(bytes) ?? latin1.decode(bytes);
    }
  }

  static const List<int?> _windows1252ControlCodePoints = <int?>[
    0x20AC,
    null,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    null,
    0x017D,
    null,
    null,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x02DC,
    0x2122,
    0x0161,
    0x203A,
    0x0153,
    null,
    0x017E,
    0x0178,
  ];

  static String? _decodeWindows1252(List<int> bytes) {
    final codePoints = <int>[];

    for (final byte in bytes) {
      if (byte < 0 || byte > 0xFF) {
        return null;
      }

      if (byte >= 0x80 && byte <= 0x9F) {
        final mapped =
            _windows1252ControlCodePoints[byte - 0x80];
        if (mapped == null) {
          return null;
        }
        codePoints.add(mapped);
      } else {
        codePoints.add(byte);
      }
    }

    return String.fromCharCodes(codePoints);
  }
}
