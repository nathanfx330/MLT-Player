// lib/services/mlt_bridge.dart

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

final class _NativeMltBridgeEngine extends Opaque {}

typedef _EngineCreateNative = Pointer<_NativeMltBridgeEngine> Function();
typedef _EngineCreateDart = Pointer<_NativeMltBridgeEngine> Function();
typedef _EngineIntNative = Int32 Function(Pointer<_NativeMltBridgeEngine>);
typedef _EngineIntDart = int Function(Pointer<_NativeMltBridgeEngine>);
typedef _EngineVoidNative = Void Function(Pointer<_NativeMltBridgeEngine>);
typedef _EngineVoidDart = void Function(Pointer<_NativeMltBridgeEngine>);

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

typedef _Int64Native = Int64 Function();
typedef _Int64Dart = int Function();

typedef _DoubleNative = Double Function();
typedef _DoubleDart = double Function();

typedef _StringNative = Pointer<Utf8> Function();
typedef _StringDart = Pointer<Utf8> Function();

typedef _IndexedIntNative = Int32 Function(Int32);
typedef _IndexedIntDart = int Function(int);

typedef _IndexedInt64Native = Int64 Function(Int32);
typedef _IndexedInt64Dart = int Function(int);

typedef _CopyStringNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _CopyStringDart = int Function(Pointer<Utf8>, int);

typedef _IndexedCopyStringNative = Int32 Function(
  Int32,
  Pointer<Utf8>,
  Int32,
);
typedef _IndexedCopyStringDart = int Function(
  int,
  Pointer<Utf8>,
  int,
);

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _OpenNative = Int32 Function(Pointer<Utf8>);
typedef _OpenDart = int Function(Pointer<Utf8>);

typedef _AddTrackNative = Int32 Function(Pointer<Utf8>, Int64);
typedef _AddTrackDart = int Function(Pointer<Utf8>, int);

typedef _SeekNative = Int32 Function(Int64);
typedef _SeekDart = int Function(int);

typedef _SetVolumeNative = Void Function(Double);
typedef _SetVolumeDart = void Function(double);

typedef _SetSpeedNative = Int32 Function(Double);
typedef _SetSpeedDart = int Function(double);

typedef _SetOpacityNative = Int32 Function(Double);
typedef _SetOpacityDart = int Function(double);

typedef _SetIntNative = Int32 Function(Int32);
typedef _SetIntDart = int Function(int);

typedef _ExportStartNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int64,
  Int64,
);
typedef _ExportStartDart = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
);

typedef _FrameExportStartNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int64,
);
typedef _FrameExportStartDart = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
);

/// Thin wrapper over libmlt_bridge.so.
///
/// The library is resolved out of the running process rather than opened
/// by path. The Linux runner already links it, so it is loaded before Dart
/// starts, and looking it up this way guarantees Dart and the runner share
/// one copy of the bridge's state. Opening it by path would work only as
/// long as the path resolved to the same file the runner linked, and the
/// failure mode when it does not is silent: two independent players, one
/// of which owns the texture and the other of which owns the media.
class MltBridge {
  MltBridge() : this._internal();

  MltBridge.attach(int engineAddress)
      : this._internal(engineAddress: engineAddress);

  MltBridge._internal({int? engineAddress})
      : _library = DynamicLibrary.process(),
        _ownsEngine = engineAddress == null {
    if (engineAddress != null) {
      _engine = Pointer<_NativeMltBridgeEngine>.fromAddress(engineAddress);
    }
    _init = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_init');
    _shutdown =
        _library.lookupFunction<_VoidNative, _VoidDart>('mlt_bridge_shutdown');
    _engineCreate = _library.lookupFunction<_EngineCreateNative, _EngineCreateDart>(
        'mlt_bridge_engine_create');
    _engineActivate = _library.lookupFunction<_EngineIntNative, _EngineIntDart>(
        'mlt_bridge_engine_activate');
    _engineDestroy = _library.lookupFunction<_EngineVoidNative, _EngineVoidDart>(
        'mlt_bridge_engine_destroy');
    _engineSetTextureSource =
        _library.lookupFunction<_EngineIntNative, _EngineIntDart>(
            'mlt_bridge_engine_set_texture_source');
    _version = _library
        .lookupFunction<_StringNative, _StringDart>('mlt_bridge_version');
    _lastError = _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
        'mlt_bridge_last_error_copy');

    _textureId = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_texture_id');

    _open = _library.lookupFunction<_OpenNative, _OpenDart>('mlt_bridge_open');
    _addTrack = _library.lookupFunction<_AddTrackNative, _AddTrackDart>(
        'mlt_bridge_add_track');
    _trackCount = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_track_count');
    _secondaryStartFrame = _library.lookupFunction<_Int64Native, _Int64Dart>(
        'mlt_bridge_secondary_start_frame');
    _setSecondaryOpacity =
        _library.lookupFunction<_SetOpacityNative, _SetOpacityDart>(
            'mlt_bridge_set_secondary_opacity');
    _secondaryOpacity = _library.lookupFunction<_DoubleNative, _DoubleDart>(
        'mlt_bridge_secondary_opacity');
    _closeMedia = _library
        .lookupFunction<_VoidNative, _VoidDart>('mlt_bridge_close_media');

    _play = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_play');
    _pause = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_pause');
    _seek = _library.lookupFunction<_SeekNative, _SeekDart>('mlt_bridge_seek_ms');
    _seekFrame = _library.lookupFunction<_SeekNative, _SeekDart>(
        'mlt_bridge_seek_frame');
    _setSpeed = _library.lookupFunction<_SetSpeedNative, _SetSpeedDart>(
        'mlt_bridge_set_speed');
    _speed =
        _library.lookupFunction<_DoubleNative, _DoubleDart>('mlt_bridge_speed');
    _setPlayAllFrames = _library.lookupFunction<_SetIntNative, _SetIntDart>(
        'mlt_bridge_set_play_all_frames');
    _playAllFrames = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_play_all_frames');

    _positionMs = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_position_ms');
    _positionFrame = _library.lookupFunction<_Int64Native, _Int64Dart>(
        'mlt_bridge_position_frame');
    _isPlaying =
        _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_is_playing');
    _isEof = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_is_eof');

    _setVolume = _library.lookupFunction<_SetVolumeNative, _SetVolumeDart>(
        'mlt_bridge_set_volume');
    _volume = _library
        .lookupFunction<_DoubleNative, _DoubleDart>('mlt_bridge_volume');
    _hasAudio =
        _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_has_audio');

    _streamCount = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_stream_count');
    _videoStreamIndex = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_video_stream_index');
    _audioStreamIndex = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_audio_stream_index');
    _videoCodecName = _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
        'mlt_bridge_video_codec_name_copy');
    _videoCodecLongName =
        _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
            'mlt_bridge_video_codec_long_name_copy');
    _audioCodecName = _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
        'mlt_bridge_audio_codec_name_copy');
    _audioCodecLongName =
        _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
            'mlt_bridge_audio_codec_long_name_copy');
    _streamType = _library
        .lookupFunction<_IndexedCopyStringNative, _IndexedCopyStringDart>(
            'mlt_bridge_stream_type_copy');
    _streamCodecName = _library
        .lookupFunction<_IndexedCopyStringNative, _IndexedCopyStringDart>(
            'mlt_bridge_stream_codec_name_copy');
    _streamCodecLongName = _library
        .lookupFunction<_IndexedCopyStringNative, _IndexedCopyStringDart>(
            'mlt_bridge_stream_codec_long_name_copy');
    _streamLanguage = _library
        .lookupFunction<_IndexedCopyStringNative, _IndexedCopyStringDart>(
            'mlt_bridge_stream_language_copy');
    _streamChannels =
        _library.lookupFunction<_IndexedIntNative, _IndexedIntDart>(
            'mlt_bridge_stream_channels');
    _streamSampleRate =
        _library.lookupFunction<_IndexedIntNative, _IndexedIntDart>(
            'mlt_bridge_stream_sample_rate');
    _streamWidth =
        _library.lookupFunction<_IndexedIntNative, _IndexedIntDart>(
            'mlt_bridge_stream_width');
    _streamHeight =
        _library.lookupFunction<_IndexedIntNative, _IndexedIntDart>(
            'mlt_bridge_stream_height');
    _streamBitRate =
        _library.lookupFunction<_IndexedInt64Native, _IndexedInt64Dart>(
            'mlt_bridge_stream_bit_rate');
    _videoPixelFormat = _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
        'mlt_bridge_video_pixel_format_copy');
    _videoColorspace = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_video_colorspace');
    _videoColorTrc = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_video_color_trc');
    _videoColorRange = _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
        'mlt_bridge_video_color_range_copy');
    _sourceTimecode = _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
        'mlt_bridge_source_timecode_copy');

    _exportStart = _library.lookupFunction<_ExportStartNative, _ExportStartDart>(
        'mlt_bridge_export_start');
    _frameExportStart =
        _library.lookupFunction<_FrameExportStartNative, _FrameExportStartDart>(
            'mlt_bridge_export_frame_start');
    _pngSequenceExportStart =
        _library.lookupFunction<_ExportStartNative, _ExportStartDart>(
            'mlt_bridge_export_png_sequence_start');
    _audioExportStart =
        _library.lookupFunction<_ExportStartNative, _ExportStartDart>(
            'mlt_bridge_export_audio_start');
    _exportCancel = _library.lookupFunction<_VoidNative, _VoidDart>(
        'mlt_bridge_export_cancel');
    _exportIsRunning = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_export_is_running');
    _exportProgress = _library.lookupFunction<_DoubleNative, _DoubleDart>(
        'mlt_bridge_export_progress');
    _exportSucceeded = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_export_succeeded');
    _exportError = _library.lookupFunction<_CopyStringNative, _CopyStringDart>(
        'mlt_bridge_export_error_copy');
    _durationFrames = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_duration_frames');
    _durationMs = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_duration_ms');
    _fps = _library.lookupFunction<_DoubleNative, _DoubleDart>('mlt_bridge_fps');
    _width = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_width');
    _height = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_height');
    _displayAspect = _library.lookupFunction<_DoubleNative, _DoubleDart>(
        'mlt_bridge_display_aspect');
    _isStill =
        _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_is_still');
  }

  final DynamicLibrary _library;
  final bool _ownsEngine;

  Pointer<_NativeMltBridgeEngine> _engine = nullptr;

  late final _IntDart _init;
  late final _VoidDart _shutdown;
  late final _EngineCreateDart _engineCreate;
  late final _EngineIntDart _engineActivate;
  late final _EngineVoidDart _engineDestroy;
  late final _EngineIntDart _engineSetTextureSource;
  late final _StringDart _version;
  late final _CopyStringDart _lastError;
  late final _Int64Dart _textureId;
  late final _OpenDart _open;
  late final _AddTrackDart _addTrack;
  late final _IntDart _trackCount;
  late final _Int64Dart _secondaryStartFrame;
  late final _SetOpacityDart _setSecondaryOpacity;
  late final _DoubleDart _secondaryOpacity;
  late final _VoidDart _closeMedia;
  late final _IntDart _play;
  late final _IntDart _pause;
  late final _SeekDart _seek;
  late final _SeekDart _seekFrame;
  late final _SetSpeedDart _setSpeed;
  late final _DoubleDart _speed;
  late final _SetIntDart _setPlayAllFrames;
  late final _IntDart _playAllFrames;
  late final _Int64Dart _positionMs;
  late final _Int64Dart _positionFrame;
  late final _IntDart _isPlaying;
  late final _IntDart _isEof;
  late final _SetVolumeDart _setVolume;
  late final _DoubleDart _volume;
  late final _IntDart _hasAudio;
  late final _IntDart _streamCount;
  late final _IntDart _videoStreamIndex;
  late final _IntDart _audioStreamIndex;
  late final _CopyStringDart _videoCodecName;
  late final _CopyStringDart _videoCodecLongName;
  late final _CopyStringDart _audioCodecName;
  late final _CopyStringDart _audioCodecLongName;
  late final _IndexedCopyStringDart _streamType;
  late final _IndexedCopyStringDart _streamCodecName;
  late final _IndexedCopyStringDart _streamCodecLongName;
  late final _IndexedCopyStringDart _streamLanguage;
  late final _IndexedIntDart _streamChannels;
  late final _IndexedIntDart _streamSampleRate;
  late final _IndexedIntDart _streamWidth;
  late final _IndexedIntDart _streamHeight;
  late final _IndexedInt64Dart _streamBitRate;
  late final _CopyStringDart _videoPixelFormat;
  late final _IntDart _videoColorspace;
  late final _IntDart _videoColorTrc;
  late final _CopyStringDart _videoColorRange;
  late final _CopyStringDart _sourceTimecode;
  late final _ExportStartDart _exportStart;
  late final _FrameExportStartDart _frameExportStart;
  late final _ExportStartDart _pngSequenceExportStart;
  late final _ExportStartDart _audioExportStart;
  late final _VoidDart _exportCancel;
  late final _IntDart _exportIsRunning;
  late final _DoubleDart _exportProgress;
  late final _IntDart _exportSucceeded;
  late final _CopyStringDart _exportError;
  late final _Int64Dart _durationFrames;
  late final _Int64Dart _durationMs;
  late final _DoubleDart _fps;
  late final _IntDart _width;
  late final _IntDart _height;
  late final _DoubleDart _displayAspect;
  late final _IntDart _isStill;

  String _readCopiedString(_CopyStringDart reader) {
    var required = reader(Pointer<Utf8>.fromAddress(0), 0);
    if (required <= 1) {
      return '';
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      final buffer = malloc<Uint8>(required).cast<Utf8>();
      try {
        final actual = reader(buffer, required);
        if (actual <= required) {
          return buffer.toDartString();
        }
        required = actual;
      } finally {
        malloc.free(buffer);
      }
    }

    return '';
  }

  String _readIndexedCopiedString(
    _IndexedCopyStringDart reader,
    int index,
  ) {
    var required = reader(index, Pointer<Utf8>.fromAddress(0), 0);
    if (required <= 1) {
      return '';
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      final buffer = malloc<Uint8>(required).cast<Utf8>();
      try {
        final actual = reader(index, buffer, required);
        if (actual <= required) {
          return buffer.toDartString();
        }
        required = actual;
      } finally {
        malloc.free(buffer);
      }
    }

    return '';
  }

  bool _activate() {
    return _engine != nullptr && _engineActivate(_engine) != 0;
  }

  T _withEngine<T>(T fallback, T Function() call) {
    if (!_activate()) {
      return fallback;
    }
    return call();
  }

  void _withEngineVoid(void Function() call) {
    if (_activate()) {
      call();
    }
  }

  bool initialize() {
    if (_engine != nullptr) {
      return _activate();
    }

    if (_init() == 0) {
      return false;
    }

    final engine = _engineCreate();
    if (engine == nullptr) {
      _shutdown();
      return false;
    }

    _engine = engine;

    if (!_activate() || _engineSetTextureSource(_engine) == 0) {
      _engineDestroy(_engine);
      _engine = nullptr;
      _shutdown();
      return false;
    }

    return true;
  }

  void shutdown() {
    if (!_ownsEngine) {
      return;
    }

    // Join the process-wide export worker first. Native shutdown defers
    // mlt_factory_close() while this engine still exists.
    _shutdown();

    if (_engine != nullptr) {
      _engineActivate(_engine);
      _engineDestroy(_engine);
      _engine = nullptr;
    }
  }

  int get engineAddress => _engine.address;

  String get version => _version().toDartString();

  String get lastError {
    if (_engine != nullptr) {
      _activate();
    }
    return _readCopiedString(_lastError);
  }

  int get textureId => _textureId();

  bool open(String path) {
    if (!_activate()) {
      return false;
    }

    final nativePath = path.toNativeUtf8(allocator: malloc);
    try {
      return _open(nativePath) != 0;
    } finally {
      malloc.free(nativePath);
    }
  }

  bool addTrack(String path, {required int startFrame}) {
    if (!_activate()) {
      return false;
    }

    final nativePath = path.toNativeUtf8(allocator: malloc);
    try {
      return _addTrack(nativePath, startFrame) != 0;
    } finally {
      malloc.free(nativePath);
    }
  }

  int get trackCount => _withEngine(0, _trackCount);
  int get secondaryStartFrame => _withEngine(-1, _secondaryStartFrame);

  bool setSecondaryOpacity(double opacity) =>
      _withEngine(false, () => _setSecondaryOpacity(opacity) != 0);

  double get secondaryOpacity => _withEngine(1.0, _secondaryOpacity);

  void closeMedia() => _withEngineVoid(_closeMedia);

  bool startExport({
    required String sourcePath,
    required String outputPath,
    required int inFrame,
    required int outFrame,
  }) {
    final nativeSource = sourcePath.toNativeUtf8(allocator: malloc);
    final nativeOutput = outputPath.toNativeUtf8(allocator: malloc);

    try {
      return _exportStart(
            nativeSource,
            nativeOutput,
            inFrame,
            outFrame,
          ) !=
          0;
    } finally {
      malloc.free(nativeSource);
      malloc.free(nativeOutput);
    }
  }

  bool startFrameExport({
    required String sourcePath,
    required String outputPath,
    required int frame,
  }) {
    final nativeSource = sourcePath.toNativeUtf8(allocator: malloc);
    final nativeOutput = outputPath.toNativeUtf8(allocator: malloc);

    try {
      return _frameExportStart(
            nativeSource,
            nativeOutput,
            frame,
          ) !=
          0;
    } finally {
      malloc.free(nativeSource);
      malloc.free(nativeOutput);
    }
  }

  bool startPngSequenceExport({
    required String sourcePath,
    required String outputDirectory,
    required int inFrame,
    required int outFrame,
  }) {
    final nativeSource = sourcePath.toNativeUtf8(allocator: malloc);
    final nativeOutput = outputDirectory.toNativeUtf8(allocator: malloc);

    try {
      return _pngSequenceExportStart(
            nativeSource,
            nativeOutput,
            inFrame,
            outFrame,
          ) !=
          0;
    } finally {
      malloc.free(nativeSource);
      malloc.free(nativeOutput);
    }
  }

  bool startAudioExport({
    required String sourcePath,
    required String outputPath,
    required int inFrame,
    required int outFrame,
  }) {
    final nativeSource = sourcePath.toNativeUtf8(allocator: malloc);
    final nativeOutput = outputPath.toNativeUtf8(allocator: malloc);

    try {
      return _audioExportStart(
            nativeSource,
            nativeOutput,
            inFrame,
            outFrame,
          ) !=
          0;
    } finally {
      malloc.free(nativeSource);
      malloc.free(nativeOutput);
    }
  }

  void cancelExport() => _exportCancel();
  bool get exportIsRunning => _exportIsRunning() != 0;
  double get exportProgress => _exportProgress();
  bool get exportSucceeded => _exportSucceeded() != 0;
  String get exportError => _readCopiedString(_exportError);

  bool play() => _withEngine(false, () => _play() != 0);
  bool pause() => _withEngine(false, () => _pause() != 0);
  bool seekMs(int milliseconds) =>
      _withEngine(false, () => _seek(milliseconds) != 0);
  bool seekFrame(int frame) =>
      _withEngine(false, () => _seekFrame(frame) != 0);
  bool setSpeed(double value) =>
      _withEngine(false, () => _setSpeed(value) != 0);
  bool setPlayAllFrames(bool enabled) =>
      _withEngine(false, () => _setPlayAllFrames(enabled ? 1 : 0) != 0);

  double get speed => _withEngine(0.0, _speed);
  bool get playAllFrames => _withEngine(false, () => _playAllFrames() != 0);
  int get positionMs => _withEngine(0, _positionMs);
  int get positionFrame => _withEngine(0, _positionFrame);
  bool get isPlaying => _withEngine(false, () => _isPlaying() != 0);
  bool get isEof => _withEngine(false, () => _isEof() != 0);

  set volume(double value) => _withEngineVoid(() => _setVolume(value));
  double get volume => _withEngine(0.0, _volume);
  bool get hasAudio => _withEngine(false, () => _hasAudio() != 0);

  int get streamCount => _withEngine(0, _streamCount);
  int get videoStreamIndex => _withEngine(-1, _videoStreamIndex);
  int get audioStreamIndex => _withEngine(-1, _audioStreamIndex);
  String get videoCodecName =>
      _withEngine('', () => _readCopiedString(_videoCodecName));
  String get videoCodecLongName =>
      _withEngine('', () => _readCopiedString(_videoCodecLongName));
  String get audioCodecName =>
      _withEngine('', () => _readCopiedString(_audioCodecName));
  String get audioCodecLongName =>
      _withEngine('', () => _readCopiedString(_audioCodecLongName));
  String streamType(int index) => _withEngine(
        '',
        () => _readIndexedCopiedString(_streamType, index),
      );
  String streamCodecName(int index) => _withEngine(
        '',
        () => _readIndexedCopiedString(_streamCodecName, index),
      );
  String streamCodecLongName(int index) => _withEngine(
        '',
        () => _readIndexedCopiedString(_streamCodecLongName, index),
      );
  String streamLanguage(int index) => _withEngine(
        '',
        () => _readIndexedCopiedString(_streamLanguage, index),
      );
  int streamChannels(int index) =>
      _withEngine(0, () => _streamChannels(index));
  int streamSampleRate(int index) =>
      _withEngine(0, () => _streamSampleRate(index));
  int streamWidth(int index) => _withEngine(0, () => _streamWidth(index));
  int streamHeight(int index) => _withEngine(0, () => _streamHeight(index));
  int streamBitRate(int index) => _withEngine(0, () => _streamBitRate(index));
  String get videoPixelFormat =>
      _withEngine('', () => _readCopiedString(_videoPixelFormat));
  int get videoColorspace => _withEngine(-1, _videoColorspace);
  int get videoColorTrc => _withEngine(-1, _videoColorTrc);
  String get videoColorRange =>
      _withEngine('', () => _readCopiedString(_videoColorRange));
  String get sourceTimecode =>
      _withEngine('', () => _readCopiedString(_sourceTimecode));
  int get durationFrames => _withEngine(0, _durationFrames);
  int get durationMs => _withEngine(0, _durationMs);
  double get fps => _withEngine(0.0, _fps);
  int get width => _withEngine(0, _width);
  int get height => _withEngine(0, _height);
  double get displayAspect => _withEngine(0.0, _displayAspect);
  bool get isStill => _withEngine(false, () => _isStill() != 0);

}

/// Opens media on a helper isolate so native probing does not stall Flutter's
/// frame pump.
///
/// DynamicLibrary.process() resolves the same already-loaded bridge in the
/// process. The helper isolate attaches to the exact opaque engine handle
/// owned by the viewer, and that engine's native mutex serializes probing.
Future<bool> openMediaOnHelperIsolate(
  String path,
  int engineAddress,
) {
  return Isolate.run(() {
    final bridge = MltBridge.attach(engineAddress);
    return bridge.open(path);
  });
}

/// Adds the POC 10.3 secondary track away from Flutter's frame pump. The
/// exact primary-timeline start frame is passed with the edit so native can
/// build a blank lead-in without consulting transport from another isolate.
Future<bool> addTrackOnHelperIsolate(
  String path,
  int startFrame,
  int engineAddress,
) {
  return Isolate.run(() {
    final bridge = MltBridge.attach(engineAddress);
    return bridge.addTrack(path, startFrame: startFrame);
  });
}
