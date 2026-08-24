// test/layer_source_trim_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_engine.dart';

CompositionLayerState _layer({
  required int index,
  required bool present,
  required String? path,
  required int? startFrame,
  required int? endFrame,
  int? sourceInFrame,
  int? sourceOutFrame,
  int? sourceFrameCount,
  bool isStill = false,
}) {
  return CompositionLayerState(
    index: index,
    present: present,
    path: path,
    startFrame: startFrame,
    endFrame: endFrame,
    sourceInFrame: sourceInFrame,
    sourceOutFrame: sourceOutFrame,
    sourceFrameCount: sourceFrameCount,
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
  required int layer2SourceIn,
  required int layer2SourceOut,
  required int layer3SourceIn,
  required int layer3SourceOut,
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
        sourceInFrame: 0,
        sourceOutFrame: 149,
        sourceFrameCount: 150,
      ),
      _layer(
        index: 1,
        present: true,
        path: '/tmp/layer-2.mov',
        startFrame: 20,
        endFrame: 49,
        sourceInFrame: layer2SourceIn,
        sourceOutFrame: layer2SourceOut,
        sourceFrameCount: 150,
      ),
      _layer(
        index: 2,
        present: true,
        path: '/tmp/layer-3.mov',
        startFrame: 80,
        endFrame: 99,
        sourceInFrame: layer3SourceIn,
        sourceOutFrame: layer3SourceOut,
        sourceFrameCount: 150,
      ),
    ],
  );
}

void main() {
  group('overlay source trim edit state', () {
    late PlayerEngine engine;

    setUp(() {
      engine = PlayerEngine.forEditStateTesting();
    });

    tearDown(() {
      engine.dispose();
    });

    test('source In/Out survive capture and apply', () async {
      final expected = _state(
        layer2SourceIn: 30,
        layer2SourceOut: 99,
        layer3SourceIn: 10,
        layer3SourceOut: 29,
      );

      await engine.applyEditStateForTesting(expected);

      expect(engine.layerState(1).sourceInFrame, 30);
      expect(engine.layerState(1).sourceOutFrame, 99);
      expect(engine.layerState(1).sourceFrameCount, 150);
      expect(engine.layerState(2).sourceInFrame, 10);
      expect(engine.layerState(2).sourceOutFrame, 29);
      expect(engine.layerState(2).sourceFrameCount, 150);

      expect(
        PlayerEngine.editStateValuesForTesting(
          engine.captureEditStateForTesting(),
        ),
        PlayerEngine.editStateValuesForTesting(expected),
      );
    });

    test('undo/redo restores source trim independently of timeline timing', () async {
      final before = _state(
        layer2SourceIn: 30,
        layer2SourceOut: 99,
        layer3SourceIn: 10,
        layer3SourceOut: 29,
      );
      final after = _state(
        layer2SourceIn: 42,
        layer2SourceOut: 110,
        layer3SourceIn: 18,
        layer3SourceOut: 44,
      );

      await engine.applyEditStateForTesting(before);
      engine.recordCurrentEditStateForTesting();
      await engine.applyEditStateForTesting(after);

      await engine.undoEditStateForTesting();
      expect(engine.layerState(1).sourceInFrame, 30);
      expect(engine.layerState(1).sourceOutFrame, 99);
      expect(engine.layerState(1).startFrame, 20);
      expect(engine.layerState(1).endFrame, 49);
      expect(engine.layerState(2).sourceInFrame, 10);
      expect(engine.layerState(2).sourceOutFrame, 29);

      await engine.redoEditStateForTesting();
      expect(engine.layerState(1).sourceInFrame, 42);
      expect(engine.layerState(1).sourceOutFrame, 110);
      expect(engine.layerState(1).startFrame, 20);
      expect(engine.layerState(1).endFrame, 49);
      expect(engine.layerState(2).sourceInFrame, 18);
      expect(engine.layerState(2).sourceOutFrame, 44);
    });
  });
}
