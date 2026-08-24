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

CompositionLayerState _layer({
  required int index,
  required bool present,
  required String? path,
  required int? startFrame,
  double opacity = 1.0,
  double x = 0.0,
  double y = 0.0,
  double scale = 1.0,
  bool visible = true,
  bool isStill = false,
  bool hasAlpha = false,
  int alphaMode = 0,
  bool hasAudio = false,
  double audioGain = 1.0,
}) {
  return CompositionLayerState(
    index: index,
    present: present,
    path: path,
    startFrame: startFrame,
    opacity: opacity,
    x: x,
    y: y,
    scale: scale,
    visible: visible,
    isStill: isStill,
    hasAlpha: hasAlpha,
    alphaMode: alphaMode,
    hasAudio: hasAudio,
    audioGain: audioGain,
  );
}

Object _editStateA() {
  return PlayerEngine.editStateForTesting(
    trimInFrame: 11,
    trimOutFrame: 188,
    inFrame: 23,
    outFrame: 144,
    layers: <CompositionLayerState>[
      _layer(
        index: 0,
        present: true,
        path: '/tmp/base-a.mov',
        startFrame: 0,
        hasAudio: true,
        audioGain: 0.82,
      ),
      _layer(
        index: 1,
        present: true,
        path: '/tmp/layer-2-a.mov',
        startFrame: 31,
        opacity: 0.37,
        x: 17.25,
        y: -8.5,
        scale: 1.42,
        visible: false,
        hasAlpha: true,
        alphaMode: 2,
        hasAudio: true,
        audioGain: 0.43,
      ),
      _layer(
        index: 2,
        present: true,
        path: '/tmp/layer-3-a.png',
        startFrame: 72,
        opacity: 0.64,
        x: -19.5,
        y: 44.25,
        scale: 0.55,
        isStill: true,
        hasAlpha: true,
        alphaMode: 1,
        audioGain: 0.19,
      ),
    ],
  );
}

Object _editStateB() {
  return PlayerEngine.editStateForTesting(
    trimInFrame: 3,
    trimOutFrame: 170,
    inFrame: 14,
    outFrame: 155,
    layers: <CompositionLayerState>[
      _layer(
        index: 0,
        present: true,
        path: '/tmp/base-b.mov',
        startFrame: 0,
        hasAudio: false,
        audioGain: 0.35,
      ),
      _layer(
        index: 1,
        present: true,
        path: '/tmp/layer-2-b.mov',
        startFrame: 9,
        opacity: 0.91,
        x: -33.0,
        y: 26.75,
        scale: 0.88,
        isStill: true,
        alphaMode: 1,
        audioGain: 0.76,
      ),
      _layer(
        index: 2,
        present: true,
        path: '/tmp/layer-3-b.mov',
        startFrame: 101,
        opacity: 0.28,
        x: 63.5,
        y: -21.0,
        scale: 2.15,
        visible: false,
        hasAlpha: true,
        alphaMode: 2,
        hasAudio: true,
        audioGain: 0.58,
      ),
    ],
  );
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

  group('composition edit-state regression net', () {
    late PlayerEngine engine;

    setUp(() {
      engine = PlayerEngine.forEditStateTesting();
    });

    tearDown(() {
      engine.dispose();
    });

    test('Dart layer slots align exactly with native 0/1/2', () {
      final values = PlayerEngine.editStateValuesForTesting(_editStateA());
      final layers = values['layers']! as List<Object?>;

      expect(layers, hasLength(3));

      final base = layers[0]! as Map<String, Object?>;
      final layer2 = layers[1]! as Map<String, Object?>;
      final layer3 = layers[2]! as Map<String, Object?>;

      expect(base['path'], '/tmp/base-a.mov');
      expect(base['audioGain'], 0.82);
      expect(layer2['path'], '/tmp/layer-2-a.mov');
      expect(layer2['startFrame'], 31);
      expect(layer3['path'], '/tmp/layer-3-a.png');
      expect(layer3['startFrame'], 72);
    });

    test('public layer view is fixed-slot and index aligned', () async {
      await engine.applyEditStateForTesting(_editStateA());

      final layers = engine.layerStates;
      expect(layers, hasLength(3));
      expect(layers.map((layer) => layer.index).toList(), <int>[0, 1, 2]);
      expect(layers[0].path, '/tmp/base-a.mov');
      expect(layers[1].path, '/tmp/layer-2-a.mov');
      expect(layers[2].path, '/tmp/layer-3-a.png');
      expect(engine.hasLayer(0), isTrue);
      expect(engine.hasLayer(1), isTrue);
      expect(engine.hasLayer(2), isTrue);
    });

    test('capture -> apply -> capture preserves every tracked field', () async {
      final expected = _editStateA();

      await engine.applyEditStateForTesting(expected);

      final captured = engine.captureEditStateForTesting();

      expect(
        PlayerEngine.editStateValuesForTesting(captured),
        PlayerEngine.editStateValuesForTesting(expected),
      );
    });

    test('undo then redo returns the exact three-layer state', () async {
      final before = _editStateA();
      final after = _editStateB();

      await engine.applyEditStateForTesting(before);
      engine.recordCurrentEditStateForTesting();
      await engine.applyEditStateForTesting(after);

      expect(engine.canUndo, isTrue);
      expect(engine.canRedo, isFalse);

      await engine.undoEditStateForTesting();

      expect(
        PlayerEngine.editStateValuesForTesting(
          engine.captureEditStateForTesting(),
        ),
        PlayerEngine.editStateValuesForTesting(before),
      );
      expect(engine.canUndo, isFalse);
      expect(engine.canRedo, isTrue);

      await engine.redoEditStateForTesting();

      expect(
        PlayerEngine.editStateValuesForTesting(
          engine.captureEditStateForTesting(),
        ),
        PlayerEngine.editStateValuesForTesting(after),
      );
      expect(engine.canUndo, isTrue);
      expect(engine.canRedo, isFalse);
    });
  });
}
