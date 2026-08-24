// test/export_frame_rate_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/mlt_export_frame_rate_bridge.dart';

void main() {
  test('video export frame-rate rationals stay ABI-stable', () {
    expect(VideoExportFrameRate.source.numerator, 0);
    expect(VideoExportFrameRate.source.denominator, 1);

    expect(VideoExportFrameRate.fps23976.numerator, 24000);
    expect(VideoExportFrameRate.fps23976.denominator, 1001);
    expect(VideoExportFrameRate.fps24.numerator, 24);
    expect(VideoExportFrameRate.fps24.denominator, 1);
    expect(VideoExportFrameRate.fps25.numerator, 25);
    expect(VideoExportFrameRate.fps25.denominator, 1);
    expect(VideoExportFrameRate.fps2997.numerator, 30000);
    expect(VideoExportFrameRate.fps2997.denominator, 1001);
    expect(VideoExportFrameRate.fps30.numerator, 30);
    expect(VideoExportFrameRate.fps30.denominator, 1);
    expect(VideoExportFrameRate.fps50.numerator, 50);
    expect(VideoExportFrameRate.fps50.denominator, 1);
    expect(VideoExportFrameRate.fps5994.numerator, 60000);
    expect(VideoExportFrameRate.fps5994.denominator, 1001);
    expect(VideoExportFrameRate.fps60.numerator, 60);
    expect(VideoExportFrameRate.fps60.denominator, 1);
  });
}
