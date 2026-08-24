// test/export_preset_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/mlt_export_preset_bridge.dart';

void main() {
  test('video export preset ids and file extensions stay ABI-stable', () {
    expect(VideoExportPreset.h264Delivery.nativeValue, 0);
    expect(VideoExportPreset.h264Delivery.extension, 'mp4');

    expect(VideoExportPreset.proRes422HqMaster.nativeValue, 1);
    expect(VideoExportPreset.proRes422HqMaster.extension, 'mov');
  });
}
