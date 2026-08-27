// lib/services/redleaf_media_resource_service.dart

import 'dart:io';

import 'redleaf_connection_service.dart';
import 'redleaf_link_service.dart';
import 'redleaf_srt_service.dart';

enum RedleafMediaResourceState {
  transcriptOnly,
  unknown,
  localFileReady,
  webUrlCandidate,
  unavailable,
}

class RedleafMediaResourceResolution {
  const RedleafMediaResourceResolution({
    required this.state,
    required this.redleafReference,
    this.resolvedResource,
    this.virtualPath,
    this.message,
  });

  final RedleafMediaResourceState state;

  /// The exact path/reference returned by Redleaf's media_status endpoint.
  final String? redleafReference;

  /// A verified local filesystem path, or a preserved external URL candidate.
  ///
  /// `webUrlCandidate` is intentionally not considered Player-ready yet.
  final String? resolvedResource;

  /// Redleaf's virtual document path for local media, without `/serve_doc/`.
  final String? virtualPath;

  final String? message;

  bool get isLocalFileReady =>
      state == RedleafMediaResourceState.localFileReady;

  bool get isWebUrlCandidate =>
      state == RedleafMediaResourceState.webUrlCandidate;

  bool get isPlayerReady => isLocalFileReady;
}

class RedleafMediaResourceService {
  RedleafMediaResourceService({
    RedleafConnectionService? connection,
    RedleafLinkService? linkService,
  })  : _connection = connection ?? RedleafConnectionService.instance,
        _linkService = linkService ?? RedleafLinkService();

  static const String _serveDocumentSegment = 'serve_doc';

  final RedleafConnectionService _connection;
  final RedleafLinkService _linkService;

  Future<RedleafMediaResourceResolution> resolve(
    RedleafSrtDocument document,
  ) async {
    final media = document.media;
    final reference = media.path?.trim();

    if (media.state == RedleafMediaLinkState.unknown) {
      return RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.unknown,
        redleafReference: reference,
        message:
            'Redleaf media status is unknown, so no Player resource can be resolved.',
      );
    }

    if (!media.isLinked) {
      return RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.transcriptOnly,
        redleafReference: reference,
        message:
            'Redleaf reports no upstream media for this transcript.',
      );
    }

    if (reference == null || reference.isEmpty) {
      return const RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.unavailable,
        redleafReference: null,
        message:
            'Redleaf reports linked media but did not return a resource reference.',
      );
    }

    final source = media.source?.trim().toLowerCase();

    if (source == 'web') {
      return _resolveWeb(reference);
    }

    if (source == 'local') {
      return _resolveLocal(reference);
    }

    return RedleafMediaResourceResolution(
      state: RedleafMediaResourceState.unavailable,
      redleafReference: reference,
      message:
          'Redleaf returned an unsupported media source: ${media.source ?? 'unknown'}.',
    );
  }

  RedleafMediaResourceResolution _resolveWeb(String reference) {
    final uri = Uri.tryParse(reference);
    final scheme = uri?.scheme.toLowerCase();

    if (uri == null ||
        (scheme != 'http' && scheme != 'https') ||
        uri.host.isEmpty) {
      return RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.unavailable,
        redleafReference: reference,
        message:
            'Redleaf identifies this as web media, but the returned reference is not an HTTP(S) URL.',
      );
    }

    return RedleafMediaResourceResolution(
      state: RedleafMediaResourceState.webUrlCandidate,
      redleafReference: reference,
      resolvedResource: reference,
      message:
          'Redleaf supplied an external web URL. It is preserved exactly, but native MLT playback has not been verified yet.',
    );
  }

  Future<RedleafMediaResourceResolution> _resolveLocal(
    String reference,
  ) async {
    final baseDirectory = _connection.baseDirectory.trim();
    if (baseDirectory.isEmpty) {
      return RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.unavailable,
        redleafReference: reference,
        message:
            'Redleaf did not provide its base directory, so local media cannot be resolved safely.',
      );
    }

    final virtualSegments = _readServeDocumentSegments(reference);
    if (virtualSegments == null || virtualSegments.isEmpty) {
      return RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.unavailable,
        redleafReference: reference,
        message:
            'The local Redleaf media reference is not a valid /serve_doc/... resource.',
      );
    }

    if (virtualSegments.any(_isUnsafeSegment)) {
      return RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.unavailable,
        redleafReference: reference,
        message:
            'The local Redleaf media reference contains an unsafe path segment.',
      );
    }

    final virtualPath = virtualSegments.join('/');
    final documentsRoot = _joinPath(
      Directory(baseDirectory).absolute.path,
      const <String>['documents'],
    );

    String physicalPath;

    if (virtualSegments.first.toLowerCase().endsWith(
          RedleafLinkService.extension,
        )) {
      final rlinkPath = _joinPath(
        documentsRoot,
        <String>[virtualSegments.first],
      );

      try {
        final link = await _linkService.readLink(rlinkPath);
        if (!link.targetExists) {
          return RedleafMediaResourceResolution(
            state: RedleafMediaResourceState.unavailable,
            redleafReference: reference,
            virtualPath: virtualPath,
            message:
                'Redleaf resolves this media through ${virtualSegments.first}, but that linked directory is unavailable.',
          );
        }

        physicalPath = _joinPath(
          link.targetPath,
          virtualSegments.skip(1),
        );
      } on FileSystemException catch (error) {
        return RedleafMediaResourceResolution(
          state: RedleafMediaResourceState.unavailable,
          redleafReference: reference,
          virtualPath: virtualPath,
          message:
              'Could not read the Redleaf .rlink used by this media: ${error.message}',
        );
      } on FormatException catch (error) {
        return RedleafMediaResourceResolution(
          state: RedleafMediaResourceState.unavailable,
          redleafReference: reference,
          virtualPath: virtualPath,
          message:
              'The Redleaf .rlink used by this media is invalid: ${error.message}',
        );
      }
    } else {
      physicalPath = _joinPath(
        documentsRoot,
        virtualSegments,
      );
    }

    final file = File(physicalPath);
    if (!await file.exists()) {
      return RedleafMediaResourceResolution(
        state: RedleafMediaResourceState.unavailable,
        redleafReference: reference,
        virtualPath: virtualPath,
        resolvedResource: file.absolute.path,
        message:
            'Redleaf identifies this local media, but the resolved file is not present on this machine.',
      );
    }

    return RedleafMediaResourceResolution(
      state: RedleafMediaResourceState.localFileReady,
      redleafReference: reference,
      resolvedResource: file.absolute.path,
      virtualPath: virtualPath,
      message:
          'Resolved through Redleaf’s local media rules and verified as an existing file.',
    );
  }

  List<String>? _readServeDocumentSegments(String reference) {
    final uri = Uri.tryParse(reference);
    if (uri == null) {
      return null;
    }

    final segments = uri.pathSegments;
    if (segments.isEmpty || segments.first != _serveDocumentSegment) {
      return null;
    }

    return segments.skip(1).toList(growable: false);
  }

  bool _isUnsafeSegment(String segment) {
    return segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains(r'\');
  }

  String _joinPath(
    String base,
    Iterable<String> segments,
  ) {
    var result = base;

    for (final segment in segments) {
      if (result.endsWith(Platform.pathSeparator)) {
        result = '$result$segment';
      } else {
        result = '$result${Platform.pathSeparator}$segment';
      }
    }

    return result;
  }
}
