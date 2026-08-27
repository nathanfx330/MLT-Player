// lib/models/redleaf_player_handoff.dart

import '../services/redleaf_transcript_service.dart';
import '../services/srt_subtitle_service.dart';

class RedleafPlayerHandoff {
  const RedleafPlayerHandoff({
    required this.mediaPath,
    required this.instanceId,
    required this.docId,
    required this.relativeSrtPath,
    required this.subtitleTrack,
  });

  factory RedleafPlayerHandoff.fromTranscript({
    required String mediaPath,
    required RedleafTranscript transcript,
  }) {
    return RedleafPlayerHandoff(
      mediaPath: mediaPath,
      instanceId: transcript.instanceId,
      docId: transcript.docId,
      relativeSrtPath: transcript.relativePath,
      subtitleTrack: transcript.track,
    );
  }

  /// Verified physical filesystem path already accepted by MLT Player.
  final String mediaPath;

  /// Canonical Redleaf project/database identity.
  final String instanceId;

  /// Canonical Redleaf document identity.
  final int docId;

  /// Exact Redleaf SRT path associated with [docId].
  final String relativeSrtPath;

  /// Exact transcript already loaded from Redleaf and parsed through the
  /// existing SRT subtitle engine.
  final SubtitleTrack subtitleTrack;

  String get transcriptSourceKey =>
      'redleaf:$instanceId:document:$docId';

  bool get hasTranscript => subtitleTrack.isNotEmpty;
}
