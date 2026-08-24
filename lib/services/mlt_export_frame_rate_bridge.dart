// lib/services/mlt_export_frame_rate_bridge.dart

import 'dart:ffi';

/// Explicit movie-output frame-rate choices.
///
/// `source` leaves the export graph at the base movie's native frame rate.
/// Every other choice rebuilds the export-only MLT profile at the requested
/// rational rate; preview playback is never changed.
enum VideoExportFrameRate {
  source(
    numerator: 0,
    denominator: 1,
    label: 'Source',
  ),
  fps23976(
    numerator: 24000,
    denominator: 1001,
    label: '23.976 fps',
  ),
  fps24(
    numerator: 24,
    denominator: 1,
    label: '24 fps',
  ),
  fps25(
    numerator: 25,
    denominator: 1,
    label: '25 fps',
  ),
  fps2997(
    numerator: 30000,
    denominator: 1001,
    label: '29.97 fps',
  ),
  fps30(
    numerator: 30,
    denominator: 1,
    label: '30 fps',
  ),
  fps50(
    numerator: 50,
    denominator: 1,
    label: '50 fps',
  ),
  fps5994(
    numerator: 60000,
    denominator: 1001,
    label: '59.94 fps',
  ),
  fps60(
    numerator: 60,
    denominator: 1,
    label: '60 fps',
  );

  const VideoExportFrameRate({
    required this.numerator,
    required this.denominator,
    required this.label,
  });

  final int numerator;
  final int denominator;
  final String label;

  bool get matchesSource => numerator == 0;
}

typedef _SetVideoExportFrameRateNative = Int32 Function(Int32, Int32);
typedef _SetVideoExportFrameRateDart = int Function(int, int);

/// Tiny FFI surface for export-only frame-rate policy.
///
/// Native snapshots the selected rational into each immutable ExportJob. The
/// source-rate sentinel is 0/1. A running export rejects policy changes.
class MltExportFrameRateBridge {
  MltExportFrameRateBridge()
      : _setVideoExportFrameRate = DynamicLibrary.process().lookupFunction<
            _SetVideoExportFrameRateNative,
            _SetVideoExportFrameRateDart>(
          'mlt_bridge_export_set_video_frame_rate',
        );

  final _SetVideoExportFrameRateDart _setVideoExportFrameRate;

  bool setVideoExportFrameRate(VideoExportFrameRate frameRate) =>
      _setVideoExportFrameRate(
        frameRate.numerator,
        frameRate.denominator,
      ) !=
      0;
}
