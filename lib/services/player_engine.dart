// lib/services/player_engine.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/media_info.dart';
import 'mlt_bridge.dart';

enum PlaybackRepeatMode { off, loop }

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Owns the native player and the polling loop, and nothing about layout.
class PlayerEngine extends ChangeNotifier {
  PlayerEngine(this.bridge, {required this.initialized}) {
    _volume = initialized ? bridge.volume : 1.0;
    _playAllFrames = initialized ? bridge.playAllFrames : false;
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  final MltBridge bridge;
  final bool initialized;

  Timer? _poll;

  MediaInfo? _media;
  String? _error;

  bool _opening = false;
  bool _playing = false;
  bool _eof = false;
  bool _playAllFrames = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;

  double _speed = 0.0;
  int _positionMs = 0;
  int _textureId = -1;

  double _volume = 1.0;
  double _volumeBeforeMute = 1.0;
  bool _muted = false;

  MediaInfo? get media => _media;
  String? get error => _error;
  bool get opening => _opening;
  bool get playing => _playing;
  bool get eof => _eof;
  bool get playAllFrames => _playAllFrames;
  PlaybackRepeatMode get repeatMode => _repeatMode;
  double get speed => _speed;
  int get positionMs => _positionMs;
  int get textureId => _textureId;
  double get volume => _volume;
  bool get muted => _muted;
  bool get hasMedia => _media != null;

  int get durationMs => _media?.durationMs ?? 0;
  bool get hasTimeline => durationMs > 0;

  set textureId(int value) {
    if (value != _textureId) {
      _textureId = value;
      notifyListeners();
    }
  }

  void _tick() {
    // Every native getter takes the engine lock, which open() holds for
    // its whole duration. Polling through an open would serialise the
    // main isolate against it and undo the point of the helper isolate.
    if (_opening || _media == null) {
      return;
    }

    final previousSpeed = _speed;
    final position = bridge.positionMs;
    final playing = bridge.isPlaying;
    final speed = bridge.speed;
    final playAllFrames = bridge.playAllFrames;
    final eof = bridge.isEof;

    // The native bridge reports speed 0 once the consumer stops at a
    // boundary. Keep the last commanded speed long enough to restart loop
    // playback from that boundary.
    if (_handleRepeatBoundary(
      positionMs: position,
      eof: eof,
      previousSpeed: previousSpeed,
    )) {
      return;
    }

    if (position != _positionMs ||
        playing != _playing ||
        speed != _speed ||
        playAllFrames != _playAllFrames ||
        eof != _eof) {
      _positionMs = position;
      _playing = playing;
      _speed = speed;
      _playAllFrames = playAllFrames;
      _eof = eof;
      notifyListeners();
    }
  }

  bool _handleRepeatBoundary({
    required int positionMs,
    required bool eof,
    required double previousSpeed,
  }) {
    final media = _media;
    if (media == null ||
        media.isStill ||
        media.frames <= 0 ||
        media.fps <= 0 ||
        _repeatMode == PlaybackRepeatMode.off ||
        previousSpeed == 0.0) {
      return false;
    }

    final frame = ((positionMs / 1000.0) * media.fps).round();
    final atForwardEnd = previousSpeed > 0.0 && eof;
    final atReverseStart = previousSpeed < 0.0 && frame <= 0;

    if (!atForwardEnd && !atReverseStart) {
      return false;
    }

    final targetSpeed = previousSpeed;

    if (!bridge.setSpeed(targetSpeed)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not continue repeat playback.'
          : bridge.lastError;
      _playing = false;
      _speed = 0.0;
      _positionMs = bridge.positionMs;
      _eof = bridge.isEof;
      notifyListeners();
      return true;
    }

    _positionMs = bridge.positionMs;
    _playing = bridge.isPlaying;
    _speed = bridge.speed;
    _eof = bridge.isEof;
    _error = null;
    notifyListeners();
    return true;
  }

  Future<bool> open(String path) async {
    if (!initialized || _opening) {
      return false;
    }

    _opening = true;
    _error = null;
    notifyListeners();

    bool opened;
    try {
      opened = await openMediaOnHelperIsolate(path);
    } catch (error) {
      _opening = false;
      _error = error.toString();
      notifyListeners();
      return false;
    }

    _opening = false;

    if (!opened) {
      _media = null;
      _playing = false;
      _eof = false;
      _speed = 0.0;
      _positionMs = 0;
      _error = bridge.lastError.isEmpty
          ? 'MLT could not open that file.'
          : bridge.lastError;
      notifyListeners();
      return false;
    }

    final fps = bridge.fps;

    var fileSizeBytes = 0;
    try {
      fileSizeBytes = await File(path).length();
    } on FileSystemException {
      fileSizeBytes = 0;
    }

    final streamCount = bridge.streamCount;
    final videoStreamIndex = bridge.videoStreamIndex;
    final audioStreamIndex = bridge.audioStreamIndex;
    final streams = <StreamInfo>[];

    for (var index = 0; index < streamCount; index++) {
      streams.add(
        StreamInfo(
          index: index,
          type: bridge.streamType(index),
          codecName: bridge.streamCodecName(index),
          codecLongName: bridge.streamCodecLongName(index),
          language: bridge.streamLanguage(index),
          channels: bridge.streamChannels(index),
          sampleRate: bridge.streamSampleRate(index),
          width: bridge.streamWidth(index),
          height: bridge.streamHeight(index),
          bitRate: bridge.streamBitRate(index),
          selected: index == videoStreamIndex || index == audioStreamIndex,
        ),
      );
    }

    _media = MediaInfo(
      path: path,
      width: bridge.width,
      height: bridge.height,
      displayAspect: bridge.displayAspect,
      fps: fps,
      frames: bridge.durationFrames,
      durationMs: bridge.durationMs,
      fileSizeBytes: fileSizeBytes,
      hasAudio: bridge.hasAudio,
      isStill: bridge.isStill,
      streamCount: streamCount,
      streams: streams,
      videoStreamIndex: videoStreamIndex,
      audioStreamIndex: audioStreamIndex,
      videoCodecName: bridge.videoCodecName,
      videoCodecLongName: bridge.videoCodecLongName,
      audioCodecName: bridge.audioCodecName,
      audioCodecLongName: bridge.audioCodecLongName,
      videoPixelFormat: bridge.videoPixelFormat,
      videoColorspace: bridge.videoColorspace,
      videoColorTrc: bridge.videoColorTrc,
      videoColorRange: bridge.videoColorRange,
      sourceTimecode: SourceTimecode.tryParse(
        bridge.sourceTimecode,
        fps,
      ),
    );

    _playing = false;
    _eof = false;
    _speed = 0.0;
    _playAllFrames = bridge.playAllFrames;
    _positionMs = 0;
    _error = null;

    final id = bridge.textureId;
    if (id > 0) {
      _textureId = id;
    }

    // Volume survives the new consumer, but read it back rather than
    // assuming, so the slider always shows what the engine actually has.
    _volume = bridge.volume;
    _muted = _volume <= 0.0;

    notifyListeners();
    return true;
  }

  void togglePlayback() {
    final media = _media;
    if (media == null || media.isStill) {
      return;
    }

    final ok = _playing ? bridge.pause() : bridge.play();
    if (!ok) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _playing = !_playing;
    _speed = _playing ? 1.0 : 0.0;
    _positionMs = bridge.positionMs;
    _eof = bridge.isEof;
    _error = null;
    notifyListeners();
  }

  void pausePlayback() {
    final media = _media;
    if (media == null || media.isStill || !_playing) {
      return;
    }

    if (!bridge.pause()) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _playing = false;
    _speed = 0.0;
    _positionMs = bridge.positionMs;
    _eof = bridge.isEof;
    _error = null;
    notifyListeners();
  }

  void shuttleForward() => _shuttle(1);
  void shuttleReverse() => _shuttle(-1);

  void _shuttle(int direction) {
    final media = _media;
    if (media == null || media.isStill) {
      return;
    }

    final sameDirection = _speed.sign == direction;
    final magnitude = sameDirection ? _speed.abs() : 0.0;

    final double nextMagnitude;
    if (magnitude < 1.0) {
      nextMagnitude = 1.0;
    } else if (magnitude < 2.0) {
      nextMagnitude = 2.0;
    } else if (magnitude < 4.0) {
      nextMagnitude = 4.0;
    } else {
      nextMagnitude = 8.0;
    }

    final targetSpeed = nextMagnitude * direction;

    if (!bridge.setSpeed(targetSpeed)) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _playing = true;
    _speed = targetSpeed;
    _positionMs = bridge.positionMs;
    _eof = false;
    _error = null;
    notifyListeners();
  }

  void seekTo(int targetMs) {
    final media = _media;
    if (media == null || media.durationMs <= 0) {
      return;
    }

    final clamped = targetMs.clamp(0, media.durationMs);
    if (!bridge.seekMs(clamped)) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _positionMs = clamped;
    _eof = false;
    _error = null;
    notifyListeners();
  }

  void seekBy(int deltaMs) => seekTo(_positionMs + deltaMs);

  void stepFrames(int deltaFrames) {
    final media = _media;
    if (media == null || media.isStill || media.frames <= 0 || media.fps <= 0) {
      return;
    }

    // Frame stepping is a paused operation. Pause first so the position we
    // calculate from is the exact frame MLT has parked on rather than a
    // consumer position that is still advancing underneath us.
    if (_playing && !bridge.pause()) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    final parkedMs = bridge.positionMs;
    final currentFrame = ((parkedMs / 1000.0) * media.fps).round();
    final targetFrame =
        (currentFrame + deltaFrames).clamp(0, media.frames - 1);

    // mlt_bridge_seek_ms() converts milliseconds back to a frame with a
    // truncating cast. Aim at the middle of the requested frame's time span
    // rather than its boundary so fractional rates such as 23.976 and 29.97
    // cannot round us onto the preceding frame.
    final targetMs =
        (((targetFrame + 0.5) * 1000.0) / media.fps).floor();

    if (!bridge.seekMs(targetMs)) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _positionMs = bridge.positionMs;
    _playing = false;
    _speed = 0.0;
    _eof = false;
    _error = null;
    notifyListeners();
  }

  void toggleLoop() {
    _repeatMode =
        _repeatMode == PlaybackRepeatMode.loop ? PlaybackRepeatMode.off : PlaybackRepeatMode.loop;
    notifyListeners();
  }

  void togglePlayAllFrames() {
    final media = _media;
    if (media == null || media.isStill) {
      return;
    }

    final target = !_playAllFrames;

    if (!bridge.setPlayAllFrames(target)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Play All Frames.'
          : bridge.lastError;
      notifyListeners();
      return;
    }

    _playAllFrames = bridge.playAllFrames;
    _positionMs = bridge.positionMs;
    _playing = bridge.isPlaying;
    _speed = bridge.speed;
    _eof = bridge.isEof;
    _error = null;
    notifyListeners();
  }

  void setVolume(double value) {
    final clamped = value.clamp(0.0, 1.0);
    _volume = clamped;
    _muted = clamped <= 0.0;
    if (!_muted) {
      _volumeBeforeMute = clamped;
    }
    bridge.volume = clamped;
    notifyListeners();
  }

  void adjustVolume(double delta) => setVolume(_volume + delta);

  void toggleMute() {
    if (_muted || _volume <= 0.0) {
      setVolume(_volumeBeforeMute <= 0.0 ? 1.0 : _volumeBeforeMute);
    } else {
      _volumeBeforeMute = _volume;
      setVolume(0.0);
    }
  }

  void clearError() {
    if (_error != null) {
      _error = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    bridge.shutdown();
    super.dispose();
  }
}
