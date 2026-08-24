// test/layer_order_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_engine.dart';

CompositionLayerState _layer({
  required int index,
  required String path,
  required int startFrame,
  required int endFrame,
  required int sourceInFrame,
  required int sourceOutFrame,
  required int sourceFrameCount,
  required double opacity,
  required double x,
  required double y,
  required double scale,
  required bool visible,
  required bool hasAlpha,
  required int alphaMode,
  required bool hasAudio,
  required double audioGain,
}) {
  return CompositionLayerState(
    index: index,
    present: true,
    path: path,
    startFrame: startFrame,
    endFrame: endFrame,
    sourceInFrame: sourceInFrame,
    sourceOutFrame: sourceOutFrame,
    sourceFrameCount: sourceFrameCount,
    opacity: opacity,
    x: x,
    y: y,
    scale: scale,
    visible: visible,
    isStill: false,
    hasAlpha: hasAlpha,
    alphaMode: alphaMode,
    hasAudio: hasAudio,
    audioGain: audioGain,
  );
}

CompositionLayerState _base() {
  return const CompositionLayerState(
    index: 0,
    present: true,
    path: '/tmp/base.mov',
    startFrame: 0,
    endFrame: 149,
    sourceInFrame: 0,
    sourceOutFrame: 149,
    sourceFrameCount: 150,
    opacity: 1.0,
    x: 0.0,
    y: 0.0,
    scale: 1.0,
    visible: true,
    isStill: false,
    hasAlpha: false,
    alphaMode: 0,
    hasAudio: true,
    audioGain: 0.9,
  );
}

Object _initialState() {
  return PlayerEngine.editStateForTesting(
    trimInFrame: 3,
    trimOutFrame: 140,
    inFrame: 12,
    outFrame: 130,
    visualOrder: const <int>[0, 1, 2],
    layers: <CompositionLayerState>[
      _base(),
      _layer(
        index: 1,
        path: '/tmp/red.mov',
        startFrame: 20,
        endFrame: 64,
        sourceInFrame: 5,
        sourceOutFrame: 49,
        sourceFrameCount: 120,
        opacity: 0.35,
        x: 11.0,
        y: 19.0,
        scale: 0.55,
        visible: false,
        hasAlpha: true,
        alphaMode: 2,
        hasAudio: true,
        audioGain: 0.25,
      ),
      _layer(
        index: 2,
        path: '/tmp/blue.mov',
        startFrame: 70,
        endFrame: 109,
        sourceInFrame: 15,
        sourceOutFrame: 54,
        sourceFrameCount: 180,
        opacity: 0.82,
        x: 73.0,
        y: 41.0,
        scale: 0.78,
        visible: true,
        hasAlpha: false,
        alphaMode: 0,
        hasAudio: true,
        audioGain: 0.65,
      ),
    ],
  );
}

Map<String, Object?> _values(CompositionLayerState layer) {
  return <String, Object?>{
    'path': layer.path,
    'startFrame': layer.startFrame,
    'endFrame': layer.endFrame,
    'sourceInFrame': layer.sourceInFrame,
    'sourceOutFrame': layer.sourceOutFrame,
    'sourceFrameCount': layer.sourceFrameCount,
    'opacity': layer.opacity,
    'x': layer.x,
    'y': layer.y,
    'scale': layer.scale,
    'visible': layer.visible,
    'isStill': layer.isStill,
    'hasAlpha': layer.hasAlpha,
    'alphaMode': layer.alphaMode,
    'hasAudio': layer.hasAudio,
    'audioGain': layer.audioGain,
  };
}

void main() {
  group('generalized layer visual ordering', () {
    late PlayerEngine engine;

    setUp(() async {
      engine = PlayerEngine.forEditStateTesting();
      await engine.applyEditStateForTesting(_initialState());
    });

    tearDown(() {
      engine.dispose();
    });

    test('only adjacent Layer 1/2 crossings request a base-role swap', () async {
      expect(
        engine.moveCrossesBaseSecondaryBoundaryForTesting(1, -1),
        isTrue,
      );
      expect(
        engine.moveCrossesBaseSecondaryBoundaryForTesting(1, 1),
        isFalse,
      );
      expect(
        engine.moveCrossesBaseSecondaryBoundaryForTesting(2, -1),
        isFalse,
      );

      // Test mode deliberately performs visual-order changes only. Put Layer 2
      // below Layer 1 and prove the opposite-direction crossing is detected too.
      expect(await engine.moveLayerUp(0), isTrue);
      expect(engine.visualOrder, <int>[1, 0, 2]);
      expect(
        engine.moveCrossesBaseSecondaryBoundaryForTesting(1, 1),
        isTrue,
      );
      expect(
        engine.moveCrossesBaseSecondaryBoundaryForTesting(0, -1),
        isTrue,
      );
      expect(
        engine.moveCrossesBaseSecondaryBoundaryForTesting(0, 1),
        isFalse,
      );
    });

    test('Layer 3 requests role promotion only when adjacent to Layer 1', () async {
      expect(
        engine.moveCrossesBaseTertiaryBoundaryForTesting(2, -1),
        isFalse,
      );

      // In test mode this first move is visual-only: Layer 3 crosses Layer 2
      // and becomes adjacent to the base without exchanging identities.
      expect(await engine.moveLayerDown(2), isTrue);
      expect(engine.visualOrder, <int>[0, 2, 1]);

      expect(
        engine.moveCrossesBaseTertiaryBoundaryForTesting(2, -1),
        isTrue,
      );
      expect(
        engine.moveCrossesBaseTertiaryBoundaryForTesting(0, 1),
        isTrue,
      );
      expect(
        engine.moveCrossesBaseSecondaryBoundaryForTesting(2, -1),
        isFalse,
      );

      // Walk the base visually across Layer 3 and prove the reverse adjacency
      // is recognized too. Production mode dispatches this crossing to the
      // true Layer 1 <-> Layer 3 role exchange.
      expect(await engine.moveLayerUp(0), isTrue);
      expect(engine.visualOrder, <int>[2, 0, 1]);
      expect(
        engine.moveCrossesBaseTertiaryBoundaryForTesting(2, 1),
        isTrue,
      );
      expect(
        engine.moveCrossesBaseTertiaryBoundaryForTesting(0, -1),
        isTrue,
      );
    });

    test('overlay reorder changes Z-order without exchanging logical state', () async {
      final baseBefore = _values(engine.layerState(0));
      final layer2Before = _values(engine.layerState(1));
      final layer3Before = _values(engine.layerState(2));

      expect(engine.visualOrder, <int>[0, 1, 2]);
      expect(await engine.moveLayerUp(1), isTrue);

      expect(engine.visualOrder, <int>[0, 2, 1]);
      expect(_values(engine.layerState(0)), baseBefore);
      expect(_values(engine.layerState(1)), layer2Before);
      expect(_values(engine.layerState(2)), layer3Before);
    });

    test('Layer 1 can move visually while retaining base identity', () async {
      final baseBefore = _values(engine.layerState(0));
      final layer2Before = _values(engine.layerState(1));
      final layer3Before = _values(engine.layerState(2));

      expect(engine.canMoveLayerUp(0), isTrue);
      expect(engine.canMoveLayerDown(0), isFalse);

      expect(await engine.moveLayerUp(0), isTrue);
      expect(engine.visualOrder, <int>[1, 0, 2]);
      expect(engine.layerState(0).visualPosition, 1);

      expect(await engine.moveLayerUp(0), isTrue);
      expect(engine.visualOrder, <int>[1, 2, 0]);
      expect(engine.layerState(0).visualPosition, 2);

      expect(_values(engine.layerState(0)), baseBefore);
      expect(_values(engine.layerState(1)), layer2Before);
      expect(_values(engine.layerState(2)), layer3Before);
    });

    test('Move Down walks the base back through the stack', () async {
      expect(await engine.moveLayerUp(0), isTrue);
      expect(await engine.moveLayerUp(0), isTrue);
      expect(engine.visualOrder, <int>[1, 2, 0]);

      expect(await engine.moveLayerDown(0), isTrue);
      expect(engine.visualOrder, <int>[1, 0, 2]);
      expect(await engine.moveLayerDown(0), isTrue);
      expect(engine.visualOrder, <int>[0, 1, 2]);
    });

    test('Undo and Redo restore visual order with all properties intact', () async {
      final baseBefore = _values(engine.layerState(0));
      final layer2Before = _values(engine.layerState(1));
      final layer3Before = _values(engine.layerState(2));

      expect(await engine.moveLayerUp(0), isTrue);
      expect(engine.visualOrder, <int>[1, 0, 2]);

      await engine.undoEditStateForTesting();
      expect(engine.visualOrder, <int>[0, 1, 2]);
      expect(_values(engine.layerState(0)), baseBefore);
      expect(_values(engine.layerState(1)), layer2Before);
      expect(_values(engine.layerState(2)), layer3Before);

      await engine.redoEditStateForTesting();
      expect(engine.visualOrder, <int>[1, 0, 2]);
      expect(_values(engine.layerState(0)), baseBefore);
      expect(_values(engine.layerState(1)), layer2Before);
      expect(_values(engine.layerState(2)), layer3Before);
    });
  });
}
