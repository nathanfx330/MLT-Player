// lib/services/mlt_bridge.dart

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';


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

typedef _IndexedStringNative = Pointer<Utf8> Function(Int32);
typedef _IndexedStringDart = Pointer<Utf8> Function(int);

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _OpenNative = Int32 Function(Pointer<Utf8>);
typedef _OpenDart = int Function(Pointer<Utf8>);

typedef _SeekNative = Int32 Function(Int64);
typedef _SeekDart = int Function(int);

typedef _SetVolumeNative = Void Function(Double);
typedef _SetVolumeDart = void Function(double);

typedef _SetSpeedNative = Int32 Function(Double);
typedef _SetSpeedDart = int Function(double);

typedef _SetIntNative = Int32 Function(Int32);
typedef _SetIntDart = int Function(int);

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
  MltBridge() : _library = DynamicLibrary.process() {
    _init = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_init');
    _shutdown =
        _library.lookupFunction<_VoidNative, _VoidDart>('mlt_bridge_shutdown');
    _version = _library
        .lookupFunction<_StringNative, _StringDart>('mlt_bridge_version');
    _lastError = _library
        .lookupFunction<_StringNative, _StringDart>('mlt_bridge_last_error');

    _textureId = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_texture_id');

    _open = _library.lookupFunction<_OpenNative, _OpenDart>('mlt_bridge_open');
    _closeMedia = _library
        .lookupFunction<_VoidNative, _VoidDart>('mlt_bridge_close_media');

    _play = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_play');
    _pause = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_pause');
    _seek = _library.lookupFunction<_SeekNative, _SeekDart>('mlt_bridge_seek_ms');
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
    _videoCodecName = _library.lookupFunction<_StringNative, _StringDart>(
        'mlt_bridge_video_codec_name');
    _videoCodecLongName =
        _library.lookupFunction<_StringNative, _StringDart>(
            'mlt_bridge_video_codec_long_name');
    _audioCodecName = _library.lookupFunction<_StringNative, _StringDart>(
        'mlt_bridge_audio_codec_name');
    _audioCodecLongName =
        _library.lookupFunction<_StringNative, _StringDart>(
            'mlt_bridge_audio_codec_long_name');
    _streamType =
        _library.lookupFunction<_IndexedStringNative, _IndexedStringDart>(
            'mlt_bridge_stream_type');
    _streamCodecName =
        _library.lookupFunction<_IndexedStringNative, _IndexedStringDart>(
            'mlt_bridge_stream_codec_name');
    _streamCodecLongName =
        _library.lookupFunction<_IndexedStringNative, _IndexedStringDart>(
            'mlt_bridge_stream_codec_long_name');
    _streamLanguage =
        _library.lookupFunction<_IndexedStringNative, _IndexedStringDart>(
            'mlt_bridge_stream_language');
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
    _videoPixelFormat = _library.lookupFunction<_StringNative, _StringDart>(
        'mlt_bridge_video_pixel_format');
    _videoColorspace = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_video_colorspace');
    _videoColorTrc = _library.lookupFunction<_IntNative, _IntDart>(
        'mlt_bridge_video_color_trc');
    _videoColorRange = _library.lookupFunction<_StringNative, _StringDart>(
        'mlt_bridge_video_color_range');
    _sourceTimecode = _library.lookupFunction<_StringNative, _StringDart>(
        'mlt_bridge_source_timecode');
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

  late final _IntDart _init;
  late final _VoidDart _shutdown;
  late final _StringDart _version;
  late final _StringDart _lastError;
  late final _Int64Dart _textureId;
  late final _OpenDart _open;
  late final _VoidDart _closeMedia;
  late final _IntDart _play;
  late final _IntDart _pause;
  late final _SeekDart _seek;
  late final _SetSpeedDart _setSpeed;
  late final _DoubleDart _speed;
  late final _SetIntDart _setPlayAllFrames;
  late final _IntDart _playAllFrames;
  late final _Int64Dart _positionMs;
  late final _IntDart _isPlaying;
  late final _IntDart _isEof;
  late final _SetVolumeDart _setVolume;
  late final _DoubleDart _volume;
  late final _IntDart _hasAudio;
  late final _IntDart _streamCount;
  late final _IntDart _videoStreamIndex;
  late final _IntDart _audioStreamIndex;
  late final _StringDart _videoCodecName;
  late final _StringDart _videoCodecLongName;
  late final _StringDart _audioCodecName;
  late final _StringDart _audioCodecLongName;
  late final _IndexedStringDart _streamType;
  late final _IndexedStringDart _streamCodecName;
  late final _IndexedStringDart _streamCodecLongName;
  late final _IndexedStringDart _streamLanguage;
  late final _IndexedIntDart _streamChannels;
  late final _IndexedIntDart _streamSampleRate;
  late final _IndexedIntDart _streamWidth;
  late final _IndexedIntDart _streamHeight;
  late final _IndexedInt64Dart _streamBitRate;
  late final _StringDart _videoPixelFormat;
  late final _IntDart _videoColorspace;
  late final _IntDart _videoColorTrc;
  late final _StringDart _videoColorRange;
  late final _StringDart _sourceTimecode;
  late final _Int64Dart _durationFrames;
  late final _Int64Dart _durationMs;
  late final _DoubleDart _fps;
  late final _IntDart _width;
  late final _IntDart _height;
  late final _DoubleDart _displayAspect;
  late final _IntDart _isStill;

  bool initialize() => _init() != 0;
  void shutdown() => _shutdown();

  String get version => _version().toDartString();
  String get lastError => _lastError().toDartString();

  int get textureId => _textureId();

  bool open(String path) {
    final nativePath = path.toNativeUtf8(allocator: malloc);
    try {
      return _open(nativePath) != 0;
    } finally {
      malloc.free(nativePath);
    }
  }

  void closeMedia() => _closeMedia();

  bool play() => _play() != 0;
  bool pause() => _pause() != 0;
  bool seekMs(int milliseconds) => _seek(milliseconds) != 0;
  bool setSpeed(double value) => _setSpeed(value) != 0;
  bool setPlayAllFrames(bool enabled) => _setPlayAllFrames(enabled ? 1 : 0) != 0;

  double get speed => _speed();
  bool get playAllFrames => _playAllFrames() != 0;
  int get positionMs => _positionMs();
  bool get isPlaying => _isPlaying() != 0;
  bool get isEof => _isEof() != 0;

  set volume(double value) => _setVolume(value);
  double get volume => _volume();
  bool get hasAudio => _hasAudio() != 0;

  int get streamCount => _streamCount();
  int get videoStreamIndex => _videoStreamIndex();
  int get audioStreamIndex => _audioStreamIndex();
  String get videoCodecName => _videoCodecName().toDartString();
  String get videoCodecLongName => _videoCodecLongName().toDartString();
  String get audioCodecName => _audioCodecName().toDartString();
  String get audioCodecLongName => _audioCodecLongName().toDartString();
  String streamType(int index) => _streamType(index).toDartString();
  String streamCodecName(int index) => _streamCodecName(index).toDartString();
  String streamCodecLongName(int index) =>
      _streamCodecLongName(index).toDartString();
  String streamLanguage(int index) => _streamLanguage(index).toDartString();
  int streamChannels(int index) => _streamChannels(index);
  int streamSampleRate(int index) => _streamSampleRate(index);
  int streamWidth(int index) => _streamWidth(index);
  int streamHeight(int index) => _streamHeight(index);
  int streamBitRate(int index) => _streamBitRate(index);
  String get videoPixelFormat => _videoPixelFormat().toDartString();
  int get videoColorspace => _videoColorspace();
  int get videoColorTrc => _videoColorTrc();
  String get videoColorRange => _videoColorRange().toDartString();
  String get sourceTimecode => _sourceTimecode().toDartString();
  int get durationFrames => _durationFrames();
  int get durationMs => _durationMs();
  double get fps => _fps();
  int get width => _width();
  int get height => _height();
  double get displayAspect => _displayAspect();
  bool get isStill => _isStill() != 0;
}

/// Opens media on a helper isolate so native probing does not stall Flutter's
/// frame pump.
///
/// DynamicLibrary.process() resolves the same already-loaded bridge in the
/// process, while the native engine mutex serializes access to shared state.
Future<bool> openMediaOnHelperIsolate(String path) {
  return Isolate.run(() => MltBridge().open(path));
}
