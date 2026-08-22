// test/widget_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/models/media_info.dart';
import 'package:mlt_player/services/player_engine.dart';

MediaInfo _mediaForFps(double fps, {int frames = 2000001}) {
  return MediaInfo(
    path: '/tmp/frame-math-test.mov',
    width: 1920,
    height: 1080,
    displayAspect: 16 / 9,
    fps: fps,
    frames: frames,
    durationMs: ((frames * 1000.0) / fps).round(),
    fileSizeBytes: 0,
    hasAudio: true,
    isStill: false,
    streamCount: 0,
    streams: const <StreamInfo>[],
    videoStreamIndex: -1,
    audioStreamIndex: -1,
    videoCodecName: '',
    videoCodecLongName: '',
    audioCodecName: '',
    audioCodecLongName: '',
    videoPixelFormat: '',
    videoColorspace: -1,
    videoColorTrc: -1,
    videoColorRange: '',
    sourceTimecode: null,
  );
}

// Mirrors mlt_bridge_seek_ms(): C converts milliseconds to a frame with a
// truncating cast after multiplying by the producer FPS.
int _nativeSeekFrameFromMs(int milliseconds, double fps) {
  return ((milliseconds / 1000.0) * fps).truncate();
}

// Mirrors mlt_bridge_position_ms(): C converts an integer frame position to
// milliseconds with a truncating cast.
int _nativePositionMsFromFrame(int frame, double fps) {
  return ((frame / fps) * 1000.0).truncate();
}

void main() {
  group('frame/millisecond transport invariant', () {
    const rates = <double>[
      12.5,
      15.0,
      23.976,
      24000 / 1001,
      24.0,
      25.0,
      29.97,
      30000 / 1001,
      30.0,
      48.0,
      50.0,
      59.94,
      60000 / 1001,
      60.0,
      100.0,
      119.88,
      120000 / 1001,
      240.0,
    ];

    test('mid-frame seek survives the native truncating conversion', () {
      for (final fps in rates) {
        final media = _mediaForFps(fps);

        for (var frame = 0; frame <= 100000; frame++) {
          final targetMs =
              PlayerEngine.midpointMsForFrameForTesting(media, frame);
          final nativeFrame = _nativeSeekFrameFromMs(targetMs, fps);

          if (nativeFrame != frame) {
            fail(
              'Seek round-trip failed at $fps fps, frame $frame: '
              '$targetMs ms became frame $nativeFrame.',
            );
          }
        }

        // Also probe far into a long source without making the test loop
        // through millions of frames.
        for (final frame in const <int>[
          250000,
          500000,
          1000000,
          1500000,
          1999999,
        ]) {
          final targetMs =
              PlayerEngine.midpointMsForFrameForTesting(media, frame);
          final nativeFrame = _nativeSeekFrameFromMs(targetMs, fps);

          expect(
            nativeFrame,
            frame,
            reason: '$fps fps, frame $frame, target $targetMs ms',
          );
        }
      }
    });

    test('native integer frame position survives the Dart round-trip', () {
      for (final fps in rates) {
        final media = _mediaForFps(fps);

        for (var frame = 0; frame <= 100000; frame++) {
          final positionMs = _nativePositionMsFromFrame(frame, fps);
          final dartFrame =
              PlayerEngine.frameAtPositionForTesting(media, positionMs);

          if (dartFrame != frame) {
            fail(
              'Position round-trip failed at $fps fps, frame $frame: '
              '$positionMs ms became frame $dartFrame.',
            );
          }
        }

        for (final frame in const <int>[
          250000,
          500000,
          1000000,
          1500000,
          1999999,
        ]) {
          final positionMs = _nativePositionMsFromFrame(frame, fps);
          final dartFrame =
              PlayerEngine.frameAtPositionForTesting(media, positionMs);

          expect(
            dartFrame,
            frame,
            reason: '$fps fps, frame $frame, position $positionMs ms',
          );
        }
      }
    });

    test('the half-frame offset is load-bearing at fractional rates', () {
      const fps = 24000 / 1001;
      final media = _mediaForFps(fps);

      const frame = 1;
      final boundaryMs = ((frame * 1000.0) / fps).floor();
      final midpointMs =
          PlayerEngine.midpointMsForFrameForTesting(media, frame);

      expect(_nativeSeekFrameFromMs(boundaryMs, fps), frame - 1);
      expect(_nativeSeekFrameFromMs(midpointMs, fps), frame);
    });
  });
}
