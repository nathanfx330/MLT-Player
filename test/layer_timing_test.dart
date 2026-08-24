// test/layer_timing_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_engine.dart';

CompositionLayerState _layer({
  required int index,
  required bool present,
  required String? path,
  required int? startFrame,
  required int? endFrame,
  bool isStill = false,
}) {
  return CompositionLayerState(
    index: index,
    present: present,
    path: path,
    startFrame: startFrame,
    endFrame: endFrame,
    opacity: 1.0,
    x: 0.0,
    y: 0.0,
    scale: 1.0,
    visible: true,
    isStill: isStill,
    hasAlpha: isStill,
    alphaMode: 0,
    hasAudio: !isStill,
    audioGain: 1.0,
  );
}

Object _state({
  required int layer2Start,
  required int layer2End,
  required int layer3Start,
  required int layer3End,
}) {
  return PlayerEngine.editStateForTesting(
    trimInFrame: 0,
    trimOutFrame: 149,
    inFrame: null,
    outFrame: null,
    layers: <CompositionLayerState>[
      _layer(
        index: 0,
        present: true,
        path: '/tmp/base.mov',
        startFrame: 0,
        endFrame: 149,
      ),
      _layer(
        index: 1,
        present: true,
        path: '/tmp/layer-2.mov',
        startFrame: layer2Start,
        endFrame: layer2End,
      ),
      _layer(
        index: 2,
        present: true,
        path: '/tmp/layer-3.png',
        startFrame: layer3Start,
        endFrame: layer3End,
        isStill: true,
      ),
    ],
  );
}

void main() {
  group('bounded layer timing edit state', () {
    late PlayerEngine engine;

    setUp(() {
      engine = PlayerEngine.forEditStateTesting();
    });

    tearDown(() {
      engine.dispose();
    });

    test('start and end frames survive capture/apply', () async {
      final expected = _state(
        layer2Start: 25,
        layer2End: 74,
        layer3Start: 60,
        layer3End: 99,
      );

      await engine.applyEditStateForTesting(expected);

      expect(engine.layerState(1).startFrame, 25);
      expect(engine.layerState(1).endFrame, 74);
      expect(engine.layerState(2).startFrame, 60);
      expect(engine.layerState(2).endFrame, 99);

      expect(
        PlayerEngine.editStateValuesForTesting(
          engine.captureEditStateForTesting(),
        ),
        PlayerEngine.editStateValuesForTesting(expected),
      );
    });

    test('undo/redo restores bounded timing exactly', () async {
      final before = _state(
        layer2Start: 25,
        layer2End: 74,
        layer3Start: 60,
        layer3End: 99,
      );
      final after = _state(
        layer2Start: 31,
        layer2End: 88,
        layer3Start: 55,
        layer3End: 112,
      );

      await engine.applyEditStateForTesting(before);
      engine.recordCurrentEditStateForTesting();
      await engine.applyEditStateForTesting(after);

      await engine.undoEditStateForTesting();
      expect(engine.layerState(1).startFrame, 25);
      expect(engine.layerState(1).endFrame, 74);
      expect(engine.layerState(2).startFrame, 60);
      expect(engine.layerState(2).endFrame, 99);

      await engine.redoEditStateForTesting();
      expect(engine.layerState(1).startFrame, 31);
      expect(engine.layerState(1).endFrame, 88);
      expect(engine.layerState(2).startFrame, 55);
      expect(engine.layerState(2).endFrame, 112);
    });
  });
}
