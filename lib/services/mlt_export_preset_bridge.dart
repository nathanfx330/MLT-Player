// lib/services/mlt_export_preset_bridge.dart

import 'dart:ffi';

/// Purpose-named movie export choices.
///
/// These intentionally expose outcomes rather than raw encoder knobs. Output
/// frame rate is controlled independently; choosing a codec preset never
/// silently changes the selected output rate.
enum VideoExportPreset {
  h264Delivery(
    nativeValue: 0,
    label: 'H.264 Delivery',
    extension: 'mp4',
    typeLabel: 'MP4 Video',
    description: 'H.264 / AAC • high-quality delivery',
  ),
  proRes422HqMaster(
    nativeValue: 1,
    label: 'ProRes 422 HQ Master',
    extension: 'mov',
    typeLabel: 'QuickTime Movie',
    description: 'ProRes 422 HQ / PCM • edit master',
  );

  const VideoExportPreset({
    required this.nativeValue,
    required this.label,
    required this.extension,
    required this.typeLabel,
    required this.description,
  });

  final int nativeValue;
  final String label;
  final String extension;
  final String typeLabel;
  final String description;
}

typedef _SetVideoExportPresetNative = Int32 Function(Int32);
typedef _SetVideoExportPresetDart = int Function(int);

/// Tiny FFI surface for movie-output policy.
///
/// The native exporter snapshots this process-level choice into each export
/// job before launching its worker, so changing the UI selection later cannot
/// alter an export already in progress.
class MltExportPresetBridge {
  MltExportPresetBridge()
      : _setVideoExportPreset = DynamicLibrary.process().lookupFunction<
            _SetVideoExportPresetNative,
            _SetVideoExportPresetDart>(
          'mlt_bridge_export_set_video_preset',
        );

  final _SetVideoExportPresetDart _setVideoExportPreset;

  bool setVideoExportPreset(VideoExportPreset preset) =>
      _setVideoExportPreset(preset.nativeValue) != 0;
}
