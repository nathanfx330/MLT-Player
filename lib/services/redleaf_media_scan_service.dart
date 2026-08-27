// lib/services/redleaf_media_scan_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'redleaf_connection_service.dart';
import 'redleaf_srt_service.dart';

enum RedleafMediaScanResultType {
  videoLinked,
  audioLinked,
  noMatch,
}

class RedleafMediaScanResult {
  const RedleafMediaScanResult({
    required this.type,
    required this.message,
    this.mediaUrl,
  });

  final RedleafMediaScanResultType type;
  final String message;
  final String? mediaUrl;

  bool get linked =>
      type == RedleafMediaScanResultType.videoLinked ||
      type == RedleafMediaScanResultType.audioLinked;

  bool get linkedVideo =>
      type == RedleafMediaScanResultType.videoLinked;

  bool get linkedAudio =>
      type == RedleafMediaScanResultType.audioLinked;
}

class RedleafMediaScanService {
  RedleafMediaScanService({
    RedleafConnectionService? connection,
  }) : _connection =
            connection ?? RedleafConnectionService.instance;

  // Redleaf's local media search may walk large document/.rlink trees, so it
  // deliberately gets a longer timeout than ordinary metadata reads.
  static const Duration _requestTimeout = Duration(seconds: 60);

  final RedleafConnectionService _connection;

  Future<RedleafMediaScanResult> scanForDocument({
    required String instanceId,
    required RedleafSrtDocument document,
  }) async {
    final expectedInstanceId = instanceId.trim();
    if (expectedInstanceId.isEmpty) {
      throw ArgumentError.value(
        instanceId,
        'instanceId',
        'Redleaf instance ID cannot be empty.',
      );
    }

    _requireMatchingConnection(expectedInstanceId);

    if (document.media.state != RedleafMediaLinkState.notLinked) {
      throw StateError(
        'SCAN FOR MEDIA is only allowed when Redleaf explicitly reports '
        'that this transcript has no linked media.',
      );
    }

    final video = await _scanExact(
      expectedInstanceId: expectedInstanceId,
      docId: document.docId,
      mediaType: 'video',
    );

    if (video.found) {
      return RedleafMediaScanResult(
        type: RedleafMediaScanResultType.videoLinked,
        message: video.message,
        mediaUrl: video.mediaUrl,
      );
    }

    final audio = await _scanExact(
      expectedInstanceId: expectedInstanceId,
      docId: document.docId,
      mediaType: 'audio',
    );

    if (audio.found) {
      return RedleafMediaScanResult(
        type: RedleafMediaScanResultType.audioLinked,
        message: audio.message,
        mediaUrl: audio.mediaUrl,
      );
    }

    final messages = <String>[
      if (video.message.trim().isNotEmpty) video.message.trim(),
      if (audio.message.trim().isNotEmpty) audio.message.trim(),
    ];

    return RedleafMediaScanResult(
      type: RedleafMediaScanResultType.noMatch,
      message: messages.isEmpty
          ? 'Redleaf found no exact local .mp4 or .mp3 match.'
          : messages.join(' '),
    );
  }

  Future<_RedleafMediaScanAttempt> _scanExact({
    required String expectedInstanceId,
    required int docId,
    required String mediaType,
  }) async {
    _requireMatchingConnection(expectedInstanceId);

    final csrfReady =
        await _connection.refreshWriteCsrfForDocument(docId);
    if (!csrfReady) {
      throw StateError(
        'Could not refresh Redleaf write authorization for this document. '
        'Sign in again and retry.',
      );
    }

    _requireMatchingConnection(expectedInstanceId);

    final csrfToken = _connection.csrfToken.trim();
    if (csrfToken.isEmpty) {
      throw StateError(
        'Redleaf did not provide a CSRF token for this document.',
      );
    }

    final uri = Uri.parse(
      '${_connection.serverUrl}/api/document/$docId/find_$mediaType',
    );

    final client = HttpClient()
      ..connectionTimeout = _requestTimeout;

    try {
      final request = await client
          .postUrl(uri)
          .timeout(_requestTimeout);

      request.followRedirects = false;
      request.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      request.headers.set(
        'X-CSRFToken',
        csrfToken,
      );
      request.headers.set(
        HttpHeaders.cookieHeader,
        _connection.sessionCookie,
      );

      request.write(
        jsonEncode(
          const <String, dynamic>{
            'use_fuzzy': false,
            'fuzzy_threshold': 0.85,
          },
        ),
      );

      final response = await request.close().timeout(_requestTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);

      _requireMatchingConnection(expectedInstanceId);

      if (body.trimLeft().startsWith('<')) {
        throw const FormatException(
          'Redleaf returned HTML instead of JSON while scanning for media.',
        );
      }

      final decoded = body.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(body);

      if (decoded is! Map) {
        throw const FormatException(
          'Redleaf media scan response was not a JSON object.',
        );
      }

      final data = Map<String, dynamic>.from(decoded);
      final message =
          data['message']?.toString().trim() ?? '';
      final mediaUrl =
          data['media_url']?.toString().trim();

      if (response.statusCode == HttpStatus.ok &&
          data['success'] == true) {
        return _RedleafMediaScanAttempt(
          found: true,
          message: message.isEmpty
              ? 'Redleaf linked exact local $mediaType media.'
              : message,
          mediaUrl:
              mediaUrl == null || mediaUrl.isEmpty ? null : mediaUrl,
        );
      }

      if (response.statusCode == HttpStatus.notFound &&
          data['success'] == false) {
        return _RedleafMediaScanAttempt(
          found: false,
          message: message.isEmpty
              ? 'No exact local $mediaType match was found.'
              : message,
        );
      }

      final detail = message.isEmpty
          ? 'HTTP ${response.statusCode}'
          : 'HTTP ${response.statusCode}: $message';

      throw HttpException(
        'Redleaf media scan failed for $mediaType ($detail).',
        uri: uri,
      );
    } on TimeoutException {
      throw TimeoutException(
        'Timed out while Redleaf scanned for local $mediaType media.',
        _requestTimeout,
      );
    } finally {
      client.close(force: true);
    }
  }

  void _requireMatchingConnection(String expectedInstanceId) {
    if (!_connection.isConnected) {
      throw StateError(
        'Connect to Redleaf before scanning for media.',
      );
    }

    if (_connection.instanceId != expectedInstanceId) {
      throw StateError(
        'The connected Redleaf instance does not match the saved project.',
      );
    }

    if (_connection.sessionCookie.isEmpty) {
      throw StateError(
        'The Redleaf session is unavailable. Sign in again before scanning.',
      );
    }
  }
}

class _RedleafMediaScanAttempt {
  const _RedleafMediaScanAttempt({
    required this.found,
    required this.message,
    this.mediaUrl,
  });

  final bool found;
  final String message;
  final String? mediaUrl;
}
