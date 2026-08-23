// lib/services/player_engine.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/media_info.dart';
import 'mlt_bridge.dart';

enum PlaybackRepeatMode { off, loop }

/// Immutable snapshot of the editable clip state.
///
/// POC 8 keeps selection markers and non-destructive trim bounds together
/// so Undo/Redo can restore the complete editable clip state atomically.
class _ClipEditState {
  const _ClipEditState({
    required this.trimInFrame,
    required this.trimOutFrame,
    required this.inFrame,
    required this.outFrame,
  });

  final int trimInFrame;
  final int trimOutFrame;
  final int? inFrame;
  final int? outFrame;

  bool sameAs(_ClipEditState other) =>
      trimInFrame == other.trimInFrame &&
      trimOutFrame == other.trimOutFrame &&
      inFrame == other.inFrame &&
      outFrame == other.outFrame;
}

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
  bool _addingTrack = false;
  String? _secondaryTrackPath;
  int? _secondaryTrackStartFrame;
  double _secondaryTrackOpacity = 1.0;
  double _secondaryTrackX = 0.0;
  double _secondaryTrackY = 0.0;
  double _secondaryTrackScale = 1.0;
  bool _secondaryTrackVisible = true;
  bool _secondaryTrackIsStill = false;
  bool _secondaryTrackHasAlpha = false;
  int _secondaryTrackAlphaMode = 0;
  double _primaryTrackAudioGain = 1.0;
  double _secondaryTrackAudioGain = 1.0;
  bool _secondaryTrackHasAudio = false;

  bool _playing = false;
  bool _playingSelection = false;
  bool _eof = false;
  bool _playAllFrames = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;

  // POC 9 export state is independent of preview transport. The native
  // bridge renders on its own worker thread; this engine only polls status.
  bool _exporting = false;
  bool _exportSucceeded = false;
  double _exportProgress = 0.0;
  String? _exportPath;
  String? _exportError;

  // POC 8 selection state is frame-based. Milliseconds remain a transport
  // concern, but edit boundaries need to survive fractional frame rates
  // without accumulating rounding error.
  int? _inFrame;
  int? _outFrame;

  // Editable clip bounds start as the full source. Trim Selection changes
  // only these frame bounds; the producer and source file remain untouched.
  int _trimInFrame = 0;
  int _trimOutFrame = -1;

  final List<_ClipEditState> _undoStack = <_ClipEditState>[];
  final List<_ClipEditState> _redoStack = <_ClipEditState>[];

  double _speed = 0.0;
  int _positionMs = 0;
  int _textureId = -1;

  double _volume = 1.0;
  double _volumeBeforeMute = 1.0;
  bool _muted = false;

  MediaInfo? get media => _media;
  String? get error => _error;
  bool get opening => _opening;
  bool get addingTrack => _addingTrack;
  String? get secondaryTrackPath => _secondaryTrackPath;
  int? get secondaryTrackStartFrame => _secondaryTrackStartFrame;
  double get secondaryTrackOpacity => _secondaryTrackOpacity;
  double get secondaryTrackX => _secondaryTrackX;
  double get secondaryTrackY => _secondaryTrackY;
  double get secondaryTrackScale => _secondaryTrackScale;
  bool get secondaryTrackVisible => _secondaryTrackVisible;
  bool get secondaryTrackIsStill => _secondaryTrackIsStill;
  bool get secondaryTrackHasAlpha => _secondaryTrackHasAlpha;
  int get secondaryTrackAlphaMode => _secondaryTrackAlphaMode;
  double get primaryTrackAudioGain => _primaryTrackAudioGain;
  double get secondaryTrackAudioGain => _secondaryTrackAudioGain;
  bool get secondaryTrackHasAudio => _secondaryTrackHasAudio;
  bool get hasSecondaryTrack => _secondaryTrackPath != null;
  int get trackCount => _media == null ? 0 : (hasSecondaryTrack ? 2 : 1);
  bool get sourceOnlyExportsAvailable => !hasSecondaryTrack;

  bool get playing => _playing;
  bool get playingSelection => _playingSelection;
  bool get eof => _eof;
  bool get playAllFrames => _playAllFrames;
  PlaybackRepeatMode get repeatMode => _repeatMode;
  double get speed => _speed;
  int get textureId => _textureId;
  double get volume => _volume;
  bool get muted => _muted;
  bool get hasMedia => _media != null;

  bool get exporting => _exporting;
  bool get exportSucceeded => _exportSucceeded;
  double get exportProgress => _exportProgress;
  String? get exportPath => _exportPath;
  String? get exportError => _exportError;
  bool get hasExportStatus =>
      _exporting || _exportSucceeded || _exportError != null;

  int get exportInFrame =>
      hasSelection ? _inFrame! : _trimInFrame;
  int get exportOutFrame =>
      hasSelection ? _outFrame! : _trimOutFrame;
  int get exportFrameCount {
    final start = exportInFrame;
    final end = exportOutFrame;
    return end >= start ? end - start + 1 : 0;
  }

  int? get inFrame => _inFrame;
  int? get outFrame => _outFrame;
  bool get hasInPoint => _inFrame != null;
  bool get hasOutPoint => _outFrame != null;
  bool get hasSelection =>
      _inFrame != null && _outFrame != null && _inFrame! <= _outFrame!;

  int get trimInFrame => _trimInFrame;
  int get trimOutFrame => _trimOutFrame;

  int get clipFrameCount {
    final media = _media;
    if (media == null ||
        media.frames <= 0 ||
        _trimOutFrame < _trimInFrame) {
      return 0;
    }
    return _trimOutFrame - _trimInFrame + 1;
  }

  bool get isTrimmed {
    final media = _media;
    return media != null &&
        media.frames > 0 &&
        (_trimInFrame != 0 || _trimOutFrame != media.frames - 1);
  }

  bool get canTrimSelection =>
      hasSelection &&
      (_inFrame != _trimInFrame || _outFrame != _trimOutFrame);

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  int get selectionFrameCount =>
      hasSelection ? (_outFrame! - _inFrame! + 1) : 0;

  int get selectionDurationMs {
    final media = _media;
    final frames = selectionFrameCount;
    if (media == null || media.fps <= 0 || frames <= 0) {
      return 0;
    }
    return ((frames * 1000.0) / media.fps).round();
  }

  _ClipEditState _captureEditState() {
    return _ClipEditState(
      trimInFrame: _trimInFrame,
      trimOutFrame: _trimOutFrame,
      inFrame: _inFrame,
      outFrame: _outFrame,
    );
  }

  void _recordEditBeforeChange(_ClipEditState before) {
    _undoStack.add(before);
    _redoStack.clear();
  }

  void _restoreEditState(_ClipEditState state) {
    _playingSelection = false;

    final boundsChanged =
        state.trimInFrame != _trimInFrame ||
        state.trimOutFrame != _trimOutFrame;

    if (boundsChanged && _playing) {
      bridge.pause();
      _playing = false;
      _speed = 0.0;
    }

    _trimInFrame = state.trimInFrame;
    _trimOutFrame = state.trimOutFrame;
    _inFrame = state.inFrame;
    _outFrame = state.outFrame;

    if (boundsChanged) {
      _constrainSourcePositionToTrim();
    }

    _error = null;
  }

  void _constrainSourcePositionToTrim() {
    final media = _media;
    if (media == null ||
        media.frames <= 0 ||
        media.fps <= 0 ||
        _trimOutFrame < _trimInFrame) {
      return;
    }

    final sourceFrame = bridge.positionFrame;
    final targetFrame =
        sourceFrame.clamp(_trimInFrame, _trimOutFrame);

    if (targetFrame != sourceFrame) {
      bridge.seekFrame(targetFrame);
    }

    _positionMs = bridge.positionMs;
    _eof = false;
  }

  void undo() {
    if (_undoStack.isEmpty) {
      return;
    }

    final current = _captureEditState();
    final previous = _undoStack.removeLast();
    _redoStack.add(current);
    _restoreEditState(previous);
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) {
      return;
    }

    final current = _captureEditState();
    final next = _redoStack.removeLast();
    _undoStack.add(current);
    _restoreEditState(next);
    notifyListeners();
  }

  int get durationMs {
    final media = _media;
    final frames = clipFrameCount;
    if (media == null || media.fps <= 0 || frames <= 0) {
      return 0;
    }
    return ((frames * 1000.0) / media.fps).round();
  }

  /// Clip-relative transport position. The native bridge keeps reporting
  /// source time; the UI sees time from the active trim In point instead.
  int get positionMs {
    final media = _media;
    if (media == null || media.fps <= 0 || clipFrameCount <= 0) {
      return 0;
    }

    final sourceFrame = _frameAtPosition(media, _positionMs);
    final clipFrame =
        (sourceFrame - _trimInFrame).clamp(0, clipFrameCount - 1);
    return ((clipFrame * 1000.0) / media.fps).round();
  }

  /// Raw source position for embedded source-timecode display.
  int get sourcePositionMs => _positionMs;

  int get currentClipFrame {
    final media = _media;
    if (media == null || media.fps <= 0 || clipFrameCount <= 0) {
      return 0;
    }
    final sourceFrame = _frameAtPosition(media, _positionMs);
    return (sourceFrame - _trimInFrame).clamp(0, clipFrameCount - 1);
  }

  int clipFrameForSourceFrame(int sourceFrame) {
    if (clipFrameCount <= 0) {
      return 0;
    }
    return (sourceFrame - _trimInFrame).clamp(0, clipFrameCount - 1);
  }

  int sourceFrameForClipPositionMs(int clipPositionMs) {
    final media = _media;
    if (media == null || media.fps <= 0 || clipFrameCount <= 0) {
      return 0;
    }

    final clampedMs = clipPositionMs.clamp(0, durationMs);
    final clipFrame = ((clampedMs / 1000.0) * media.fps)
        .round()
        .clamp(0, clipFrameCount - 1);
    return _trimInFrame + clipFrame;
  }

  bool get hasTimeline => durationMs > 0;

  set textureId(int value) {
    if (value != _textureId) {
      _textureId = value;
      notifyListeners();
    }
  }

  void _tick() {
    final exportChanged = _pollExport();

    // Every native playback getter takes the engine lock, which open() holds
    // for its whole duration. Export status has its own native mutex and can
    // still be polled while a new source is opening.
    if (_opening || _media == null) {
      if (exportChanged) {
        notifyListeners();
      }
      return;
    }

    final previousSpeed = _speed;
    final position = bridge.positionMs;
    final positionFrame = bridge.positionFrame;
    final playing = bridge.isPlaying;
    final speed = bridge.speed;
    final playAllFrames = bridge.playAllFrames;
    final eof = bridge.isEof;

    // Selection playback owns its Out boundary. Handle it before whole-file
    // repeat logic so Loop can never carry a Play Selection command beyond
    // the marked range.
    if (_handleSelectionBoundary(
      positionFrame: positionFrame,
      playing: playing,
      eof: eof,
    )) {
      return;
    }

    // Active trim bounds become the clip's transport boundaries. Handle
    // them before whole-source EOF repeat so normal Play/Loop can never
    // escape a trimmed movie.
    if (_handleTrimBoundary(
      positionFrame: positionFrame,
      playing: playing,
      eof: eof,
      previousSpeed: previousSpeed,
    )) {
      return;
    }

    // The native bridge reports speed 0 once the consumer stops at a
    // boundary. Keep the last commanded speed long enough to restart loop
    // playback from that boundary.
    if (_handleRepeatBoundary(
      positionFrame: positionFrame,
      eof: eof,
      previousSpeed: previousSpeed,
    )) {
      return;
    }

    if (exportChanged ||
        position != _positionMs ||
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

  bool _handleSelectionBoundary({
    required int positionFrame,
    required bool playing,
    required bool eof,
  }) {
    final media = _media;
    final inFrame = _inFrame;
    final outFrame = _outFrame;

    if (!_playingSelection ||
        media == null ||
        inFrame == null ||
        outFrame == null ||
        media.frames <= 0 ||
        media.fps <= 0) {
      return false;
    }

    // The selection model and the native playback position are both
    // frame-based here; no millisecond round-trip is involved.
    final currentFrame = positionFrame;
    if (currentFrame <= outFrame && !eof) {
      return false;
    }

    // Stop first so the producer cannot continue advancing while we move it
    // to the next exact boundary position.
    if (playing && !bridge.pause()) {
      _playingSelection = false;
      _error = bridge.lastError.isEmpty
          ? 'MLT could not stop at the selection Out point.'
          : bridge.lastError;
      _playing = bridge.isPlaying;
      _speed = bridge.speed;
      _positionMs = bridge.positionMs;
      _eof = bridge.isEof;
      notifyListeners();
      return true;
    }

    // Loop applies to the active selection. When Play Selection owns the
    // transport, Loop means In -> Out -> In, not whole-file repeat.
    if (_repeatMode == PlaybackRepeatMode.loop) {
      if (!bridge.seekFrame(inFrame)) {
        _playingSelection = false;
        _playing = false;
        _speed = 0.0;
        _positionMs = bridge.positionMs;
        _eof = bridge.isEof;
        _error = bridge.lastError.isEmpty
            ? 'MLT could not return to the selection In point.'
            : bridge.lastError;
        notifyListeners();
        return true;
      }

      if (!bridge.setSpeed(1.0)) {
        _playingSelection = false;
        _playing = false;
        _speed = 0.0;
        _positionMs = bridge.positionMs;
        _eof = bridge.isEof;
        _error = bridge.lastError.isEmpty
            ? 'MLT could not continue selection loop playback.'
            : bridge.lastError;
        notifyListeners();
        return true;
      }

      _playingSelection = true;
      _playing = bridge.isPlaying;
      _speed = bridge.speed;
      _positionMs = bridge.positionMs;
      _eof = false;
      _error = null;
      notifyListeners();
      return true;
    }

    // Loop is off: park on the inclusive Out frame and finish Play Selection.
    if (!bridge.seekFrame(outFrame)) {
      _playingSelection = false;
      _error = bridge.lastError.isEmpty
          ? 'MLT could not park on the selection Out point.'
          : bridge.lastError;
      _playing = false;
      _speed = 0.0;
      _positionMs = bridge.positionMs;
      _eof = bridge.isEof;
      notifyListeners();
      return true;
    }

    _playingSelection = false;
    _playing = false;
    _speed = 0.0;
    _positionMs = bridge.positionMs;
    _eof = false;
    _error = null;
    notifyListeners();
    return true;
  }

  bool _handleTrimBoundary({
    required int positionFrame,
    required bool playing,
    required bool eof,
    required double previousSpeed,
  }) {
    final media = _media;
    if (media == null ||
        media.frames <= 0 ||
        media.fps <= 0 ||
        !isTrimmed ||
        previousSpeed == 0.0) {
      return false;
    }

    final currentFrame = positionFrame;
    final beyondOut = previousSpeed > 0.0 &&
        (currentFrame > _trimOutFrame ||
            (eof && currentFrame >= _trimOutFrame));
    final beforeIn = previousSpeed < 0.0 &&
        (currentFrame < _trimInFrame ||
            (!playing && currentFrame <= _trimInFrame));

    if (!beyondOut && !beforeIn) {
      return false;
    }

    if (playing && !bridge.pause()) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not stop at the trimmed clip boundary.'
          : bridge.lastError;
      _playing = bridge.isPlaying;
      _speed = bridge.speed;
      _positionMs = bridge.positionMs;
      _eof = bridge.isEof;
      notifyListeners();
      return true;
    }

    final boundaryFrame =
        previousSpeed > 0.0 ? _trimOutFrame : _trimInFrame;

    if (_repeatMode == PlaybackRepeatMode.loop) {
      final restartFrame =
          previousSpeed > 0.0 ? _trimInFrame : _trimOutFrame;

      if (!bridge.seekFrame(restartFrame)) {
        _playing = false;
        _speed = 0.0;
        _positionMs = bridge.positionMs;
        _eof = false;
        _error = bridge.lastError.isEmpty
            ? 'MLT could not return to the trimmed clip boundary.'
            : bridge.lastError;
        notifyListeners();
        return true;
      }

      if (!bridge.setSpeed(previousSpeed)) {
        _playing = false;
        _speed = 0.0;
        _positionMs = bridge.positionMs;
        _eof = false;
        _error = bridge.lastError.isEmpty
            ? 'MLT could not continue trimmed loop playback.'
            : bridge.lastError;
        notifyListeners();
        return true;
      }

      _playing = bridge.isPlaying;
      _speed = bridge.speed;
      _positionMs = bridge.positionMs;
      _eof = false;
      _error = null;
      notifyListeners();
      return true;
    }

    if (!bridge.seekFrame(boundaryFrame)) {
      _playing = false;
      _speed = 0.0;
      _positionMs = bridge.positionMs;
      _eof = false;
      _error = bridge.lastError.isEmpty
          ? 'MLT could not park on the trimmed clip boundary.'
          : bridge.lastError;
      notifyListeners();
      return true;
    }

    _playing = false;
    _speed = 0.0;
    _positionMs = bridge.positionMs;
    _eof = false;
    _error = null;
    notifyListeners();
    return true;
  }

  bool _handleRepeatBoundary({
    required int positionFrame,
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

    final atForwardEnd = previousSpeed > 0.0 && eof;
    final atReverseStart = previousSpeed < 0.0 && positionFrame <= 0;

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

  bool _pollExport() {
    if (!_exporting) {
      return false;
    }

    final progress = bridge.exportProgress.clamp(0.0, 1.0);
    final running = bridge.exportIsRunning;

    if (running) {
      if (progress != _exportProgress) {
        _exportProgress = progress;
        return true;
      }
      return false;
    }

    _exporting = false;
    _exportProgress = bridge.exportProgress.clamp(0.0, 1.0);
    _exportSucceeded = bridge.exportSucceeded;
    _exportError = _exportSucceeded
        ? null
        : (bridge.exportError.isEmpty ? 'Export failed.' : bridge.exportError);

    if (_exportSucceeded) {
      _exportProgress = 1.0;
    }

    return true;
  }

  int? captureCurrentSourceFrame() {
    final media = _media;
    if (_opening ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        media.frames <= 0 ||
        media.fps <= 0 ||
        _trimOutFrame < _trimInFrame) {
      return null;
    }

    /*
     * Snapshot the visible source frame before stopping transport. Native
     * pause intentionally parks one frame beyond the displayed consumer
     * position in the direction of travel, so capture must remember the
     * visible frame first and then explicitly seek back to that exact frame.
     */
    final frame = bridge.positionFrame
        .clamp(_trimInFrame, _trimOutFrame);

    if (_playing) {
      if (!bridge.pause()) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not pause for frame export.'
            : bridge.lastError;
        notifyListeners();
        return null;
      }

      if (!bridge.seekFrame(frame)) {
        _playingSelection = false;
        _playing = false;
        _speed = 0.0;
        _positionMs = bridge.positionMs;
        _eof = bridge.isEof;
        _error = bridge.lastError.isEmpty
            ? 'MLT could not park on the captured frame.'
            : bridge.lastError;
        notifyListeners();
        return null;
      }

      _playingSelection = false;
      _playing = false;
      _speed = 0.0;
      _positionMs = bridge.positionMs;
      _eof = false;
      _error = null;
      notifyListeners();
    }

    return frame;
  }

  bool startFrameExport(String outputPath, {required int sourceFrame}) {
    final media = _media;

    if (hasSecondaryTrack) {
      _exportSucceeded = false;
      _exportError =
          'Composite export is not enabled yet; remove/reopen the movie '
          'to return to the one-track exporter.';
      _exportPath = null;
      _exportProgress = 0.0;
      notifyListeners();
      return false;
    }

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        media.frames <= 0 ||
        sourceFrame < _trimInFrame ||
        sourceFrame > _trimOutFrame ||
        _exporting) {
      return false;
    }

    _exportSucceeded = false;
    _exportError = null;
    _exportProgress = 0.0;
    _exportPath = outputPath;

    final started = bridge.startFrameExport(
      sourcePath: media.path,
      outputPath: outputPath,
      frame: sourceFrame,
    );

    if (!started) {
      _exportError = bridge.exportError.isEmpty
          ? 'MLT could not start frame export.'
          : bridge.exportError;
      notifyListeners();
      return false;
    }

    _exporting = true;
    notifyListeners();
    return true;
  }

  bool startImageSequenceExport(String outputDirectory) {
    final media = _media;

    if (hasSecondaryTrack) {
      _exportSucceeded = false;
      _exportError =
          'Composite export is not enabled yet; remove/reopen the movie '
          'to return to the one-track exporter.';
      _exportPath = null;
      _exportProgress = 0.0;
      notifyListeners();
      return false;
    }

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        media.frames <= 0 ||
        exportFrameCount <= 0 ||
        _exporting) {
      return false;
    }

    _exportSucceeded = false;
    _exportError = null;
    _exportProgress = 0.0;
    _exportPath = outputDirectory;

    final started = bridge.startPngSequenceExport(
      sourcePath: media.path,
      outputDirectory: outputDirectory,
      inFrame: exportInFrame,
      outFrame: exportOutFrame,
    );

    if (!started) {
      _exportError = bridge.exportError.isEmpty
          ? 'MLT could not start image-sequence export.'
          : bridge.exportError;
      notifyListeners();
      return false;
    }

    _exporting = true;
    notifyListeners();
    return true;
  }

  bool startAudioExport(String outputPath) {
    final media = _media;

    if (hasSecondaryTrack) {
      _exportSucceeded = false;
      _exportError =
          'Composite export is not enabled yet; remove/reopen the movie '
          'to return to the one-track exporter.';
      _exportPath = null;
      _exportProgress = 0.0;
      notifyListeners();
      return false;
    }

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasAudio ||
        media.frames <= 0 ||
        exportFrameCount <= 0 ||
        _exporting) {
      return false;
    }

    _exportSucceeded = false;
    _exportError = null;
    _exportProgress = 0.0;
    _exportPath = outputPath;

    final started = bridge.startAudioExport(
      sourcePath: media.path,
      outputPath: outputPath,
      inFrame: exportInFrame,
      outFrame: exportOutFrame,
    );

    if (!started) {
      _exportError = bridge.exportError.isEmpty
          ? 'MLT could not start audio export.'
          : bridge.exportError;
      notifyListeners();
      return false;
    }

    _exporting = true;
    notifyListeners();
    return true;
  }

  bool startExport(String outputPath) {
    final media = _media;

    if (hasSecondaryTrack) {
      _exportSucceeded = false;
      _exportError =
          'Composite export is not enabled yet; remove/reopen the movie '
          'to return to the one-track exporter.';
      _exportPath = null;
      _exportProgress = 0.0;
      notifyListeners();
      return false;
    }

    if (!initialized ||
        media == null ||
        media.isStill ||
        media.frames <= 0 ||
        exportFrameCount <= 0 ||
        _exporting) {
      return false;
    }

    _exportSucceeded = false;
    _exportError = null;
    _exportProgress = 0.0;
    _exportPath = outputPath;

    final started = bridge.startExport(
      sourcePath: media.path,
      outputPath: outputPath,
      inFrame: exportInFrame,
      outFrame: exportOutFrame,
    );

    if (!started) {
      _exporting = false;
      _exportError = bridge.exportError.isEmpty
          ? 'MLT could not start export.'
          : bridge.exportError;
      notifyListeners();
      return false;
    }

    _exporting = true;
    notifyListeners();
    return true;
  }

  void cancelExport() {
    if (!_exporting) {
      return;
    }

    bridge.cancelExport();
  }

  void clearExportStatus() {
    if (_exporting) {
      return;
    }

    if (_exportSucceeded || _exportError != null || _exportPath != null) {
      _exportSucceeded = false;
      _exportError = null;
      _exportPath = null;
      _exportProgress = 0.0;
      notifyListeners();
    }
  }

  Future<bool> open(String path) async {
    if (!initialized || _opening) {
      return false;
    }

    _opening = true;
    _addingTrack = false;
    _secondaryTrackPath = null;
    _secondaryTrackStartFrame = null;
    _secondaryTrackOpacity = 1.0;
    _secondaryTrackX = 0.0;
    _secondaryTrackY = 0.0;
    _secondaryTrackScale = 1.0;
    _secondaryTrackVisible = true;
    _secondaryTrackIsStill = false;
    _secondaryTrackHasAlpha = false;
    _secondaryTrackAlphaMode = 0;
    _primaryTrackAudioGain = 1.0;
    _secondaryTrackAudioGain = 1.0;
    _secondaryTrackHasAudio = false;
    _playingSelection = false;
    _inFrame = null;
    _outFrame = null;
    _trimInFrame = 0;
    _trimOutFrame = -1;
    _undoStack.clear();
    _redoStack.clear();
    _error = null;
    notifyListeners();

    bool opened;
    try {
      opened = await openMediaOnHelperIsolate(path, bridge.engineAddress);
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
      _playingSelection = false;
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

    _trimInFrame = 0;
    _trimOutFrame = _media!.frames > 0 ? _media!.frames - 1 : -1;

    _playing = false;
    _playingSelection = false;
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

    _primaryTrackAudioGain =
        bridge.trackAudioGain(0).clamp(0.0, 1.0).toDouble();

    notifyListeners();
    return true;
  }

  /// Place one additional video or still-image layer at the current exact
  /// playhead frame and promote the native viewer graph to a two-layer tractor.
  /// Still images are held natively from their start frame through Movie A.
  Future<bool> addTrack(String path) async {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        _opening ||
        _addingTrack ||
        _exporting ||
        hasSecondaryTrack) {
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    var startFrame = bridge.positionFrame;
    if (startFrame < 0) {
      startFrame = 0;
    }
    if (media.frames > 0 && startFrame >= media.frames) {
      startFrame = media.frames - 1;
    }

    return _addTrackAtFrame(path, startFrame);
  }

  Future<bool> _addTrackAtFrame(String path, int startFrame) async {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        _opening ||
        _addingTrack ||
        _exporting ||
        hasSecondaryTrack) {
      return false;
    }

    var clampedStart = startFrame;
    if (clampedStart < 0) {
      clampedStart = 0;
    }
    if (media.frames > 0 && clampedStart >= media.frames) {
      clampedStart = media.frames - 1;
    }

    _addingTrack = true;
    _error = null;
    notifyListeners();

    bool added;
    try {
      added = await addTrackOnHelperIsolate(
        path,
        clampedStart,
        bridge.engineAddress,
      );
    } catch (error) {
      _addingTrack = false;
      _error = error.toString();
      notifyListeners();
      return false;
    }

    _addingTrack = false;

    if (!added) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not add that media as a second layer.'
          : bridge.lastError;
      notifyListeners();
      return false;
    }

    _secondaryTrackPath = path;
    final nativeStartFrame = bridge.secondaryStartFrame;
    _secondaryTrackStartFrame =
        nativeStartFrame >= 0 ? nativeStartFrame : clampedStart;
    _secondaryTrackOpacity =
        bridge.secondaryOpacity.clamp(0.0, 1.0).toDouble();
    _secondaryTrackX = bridge.secondaryX;
    _secondaryTrackY = bridge.secondaryY;
    _secondaryTrackScale =
        bridge.secondaryScale.clamp(0.10, 3.0).toDouble();
    _secondaryTrackVisible = true;
    _secondaryTrackIsStill = bridge.secondaryIsStill;
    _secondaryTrackHasAlpha = bridge.secondaryHasAlpha;
    _secondaryTrackAlphaMode =
        bridge.secondaryAlphaMode.clamp(0, 2).toInt();
    _primaryTrackAudioGain =
        bridge.trackAudioGain(0).clamp(0.0, 1.0).toDouble();
    _secondaryTrackHasAudio = bridge.trackHasAudio(1);
    _secondaryTrackAudioGain =
        bridge.trackAudioGain(1).clamp(0.0, 1.0).toDouble();
    _exportSucceeded = false;
    _exportError = null;
    _exportPath = null;
    _exportProgress = 0.0;

    _playing = false;
    _playingSelection = false;
    _speed = 0.0;
    _positionMs = bridge.positionMs;
    _eof = false;
    _error = null;

    notifyListeners();
    return true;
  }

  Future<bool> _parkPlaybackForLayerChange() async {
    if (!_playing) {
      return true;
    }

    if (!bridge.pause()) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not pause before changing a layer source.'
          : bridge.lastError;
      notifyListeners();
      return false;
    }

    _playing = false;
    _playingSelection = false;
    _speed = 0.0;
    _positionMs = bridge.positionMs;
    _eof = false;
    notifyListeners();
    return true;
  }

  /// POC 10.6.1: replace Layer 2's media while preserving the layer's
  /// placement and inspector controls. The graph is rebuilt from the same
  /// base movie so this remains a layer-source swap, not a timeline edit.
  Future<bool> replaceSecondaryLayerSource(String path) async {
    final media = _media;
    final oldSecondaryPath = _secondaryTrackPath;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        oldSecondaryPath == null ||
        _opening ||
        _addingTrack ||
        _exporting) {
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    final editState = _captureEditState();
    final undoState = List<_ClipEditState>.from(_undoStack);
    final redoState = List<_ClipEditState>.from(_redoStack);
    final currentFrame = bridge.positionFrame;
    final startFrame = _secondaryTrackStartFrame ?? 0;
    final opacity = _secondaryTrackOpacity;
    final secondaryX = _secondaryTrackX;
    final secondaryY = _secondaryTrackY;
    final secondaryScale = _secondaryTrackScale;
    final visible = _secondaryTrackVisible;
    final alphaMode = _secondaryTrackAlphaMode;
    final primaryGain = _primaryTrackAudioGain;
    final secondaryGain = _secondaryTrackAudioGain;
    final basePath = media.path;

    final rebuilt = await _rebuildLayerPair(
      primaryPath: basePath,
      secondaryPath: path,
      secondaryStartFrame: startFrame,
      playheadFrame: currentFrame,
      primaryGain: primaryGain,
      secondaryGain: secondaryGain,
      secondaryOpacity: opacity,
      secondaryX: secondaryX,
      secondaryY: secondaryY,
      secondaryScale: secondaryScale,
      secondaryVisible: visible,
      // Alpha interpretation belongs to the asset, not the layer slot. A new
      // source therefore starts in Auto even though placement/opacity/gain
      // remain layer properties.
      secondaryAlphaMode: 0,
      editState: editState,
      undoState: undoState,
      redoState: redoState,
    );

    if (rebuilt) {
      return true;
    }

    final replaceError = _error;

    final rolledBack = await _rebuildLayerPair(
      primaryPath: basePath,
      secondaryPath: oldSecondaryPath,
      secondaryStartFrame: startFrame,
      playheadFrame: currentFrame,
      primaryGain: primaryGain,
      secondaryGain: secondaryGain,
      secondaryOpacity: opacity,
      secondaryX: secondaryX,
      secondaryY: secondaryY,
      secondaryScale: secondaryScale,
      secondaryVisible: visible,
      secondaryAlphaMode: alphaMode,
      editState: editState,
      undoState: undoState,
      redoState: redoState,
    );

    _error = rolledBack
        ? (replaceError ?? 'The replacement layer source could not be opened.')
        : 'The replacement failed and the previous layer could not be restored.';
    notifyListeners();
    return false;
  }

  /// Replace the base layer with another timed video source. The caller keeps
  /// still images out of this chooser; a defensive runtime check below also
  /// rolls back if MLT classifies the replacement as a still or audio-only.
  Future<bool> replacePrimaryLayerSource(String path) async {
    final oldMedia = _media;
    if (!initialized ||
        oldMedia == null ||
        oldMedia.isStill ||
        !oldMedia.hasVideo ||
        _opening ||
        _addingTrack ||
        _exporting) {
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    final oldBasePath = oldMedia.path;
    final oldEditState = _captureEditState();
    final oldUndoState = List<_ClipEditState>.from(_undoStack);
    final oldRedoState = List<_ClipEditState>.from(_redoStack);
    final oldSecondaryPath = _secondaryTrackPath;
    final oldStartFrame = _secondaryTrackStartFrame;
    final oldStartSeconds = oldSecondaryPath != null &&
            oldStartFrame != null &&
            oldMedia.fps > 0
        ? oldStartFrame / oldMedia.fps
        : 0.0;
    final oldPlayheadFrame = bridge.positionFrame;
    final oldPlayheadSeconds = oldMedia.fps > 0
        ? oldPlayheadFrame / oldMedia.fps
        : 0.0;
    final opacity = _secondaryTrackOpacity;
    final secondaryX = _secondaryTrackX;
    final secondaryY = _secondaryTrackY;
    final secondaryScale = _secondaryTrackScale;
    final visible = _secondaryTrackVisible;
    final alphaMode = _secondaryTrackAlphaMode;
    final primaryGain = _primaryTrackAudioGain;
    final secondaryGain = _secondaryTrackAudioGain;

    final opened = await open(path);
    final replacementMedia = _media;

    if (!opened ||
        replacementMedia == null ||
        replacementMedia.isStill ||
        !replacementMedia.hasVideo) {
      final replaceError = !opened
          ? _error
          : 'Layer 1 must be a timed video source; still images are overlay-only.';

      await _rebuildLayerPair(
        primaryPath: oldBasePath,
        secondaryPath: oldSecondaryPath,
        secondaryStartFrame: oldStartFrame,
        playheadFrame: oldPlayheadFrame,
        primaryGain: primaryGain,
        secondaryGain: secondaryGain,
        secondaryOpacity: opacity,
        secondaryX: secondaryX,
        secondaryY: secondaryY,
        secondaryScale: secondaryScale,
        secondaryVisible: visible,
        secondaryAlphaMode: alphaMode,
        editState: oldEditState,
        undoState: oldUndoState,
        redoState: oldRedoState,
      );

      _error = replaceError ??
          'Layer 1 must be a timed video source; still images are overlay-only.';
      notifyListeners();
      return false;
    }

    final newFps = replacementMedia.fps;
    final newPlayheadFrame = newFps > 0
        ? (oldPlayheadSeconds * newFps).round()
        : 0;
    final newStartFrame = oldSecondaryPath != null && newFps > 0
        ? (oldStartSeconds * newFps).round()
        : null;

    if (oldSecondaryPath != null) {
      final rebuilt = await _rebuildLayerPair(
        primaryPath: path,
        secondaryPath: oldSecondaryPath,
        secondaryStartFrame: newStartFrame,
        playheadFrame: newPlayheadFrame,
        primaryGain: primaryGain,
        secondaryGain: secondaryGain,
        secondaryOpacity: opacity,
        secondaryX: secondaryX,
        secondaryY: secondaryY,
        secondaryScale: secondaryScale,
        secondaryVisible: visible,
        secondaryAlphaMode: alphaMode,
      );

      if (!rebuilt) {
        final replaceError = _error;
        await _rebuildLayerPair(
          primaryPath: oldBasePath,
          secondaryPath: oldSecondaryPath,
          secondaryStartFrame: oldStartFrame,
          playheadFrame: oldPlayheadFrame,
          primaryGain: primaryGain,
          secondaryGain: secondaryGain,
          secondaryOpacity: opacity,
          secondaryX: secondaryX,
          secondaryY: secondaryY,
          secondaryScale: secondaryScale,
          secondaryVisible: visible,
          secondaryAlphaMode: alphaMode,
          editState: oldEditState,
          undoState: oldUndoState,
          redoState: oldRedoState,
        );
        _error = replaceError ??
            'The new base video could not preserve the overlay layer.';
        notifyListeners();
        return false;
      }
    } else {
      _seekSourceFrameClamped(newPlayheadFrame);
      if (trackHasAudio(0)) {
        setTrackAudioGain(0, primaryGain);
      }
    }

    _error = null;
    notifyListeners();
    return true;
  }

  /// POC 10.7: exchange the media in the BASE and OVERLAY slots.
  ///
  /// This is deliberately a layer-order operation, not timeline editing.
  /// Layer 1 remains the timed base slot at frame zero; Layer 2 keeps its
  /// existing insertion time, opacity, visibility, and audio-gain controls.
  /// A still image cannot be swapped into Layer 1.
  Future<bool> swapLayerOrder() async {
    final oldMedia = _media;
    final oldSecondaryPath = _secondaryTrackPath;

    if (!initialized ||
        oldMedia == null ||
        oldMedia.isStill ||
        !oldMedia.hasVideo ||
        oldSecondaryPath == null ||
        _secondaryTrackIsStill ||
        _opening ||
        _addingTrack ||
        _exporting) {
      if (_secondaryTrackIsStill) {
        _error = 'A still image cannot become the base layer.';
        notifyListeners();
      }
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    final oldBasePath = oldMedia.path;
    final oldStartFrame = _secondaryTrackStartFrame ?? 0;
    final oldStartSeconds = oldMedia.fps > 0
        ? oldStartFrame / oldMedia.fps
        : 0.0;
    final oldPlayheadFrame = bridge.positionFrame;
    final oldPlayheadSeconds = oldMedia.fps > 0
        ? oldPlayheadFrame / oldMedia.fps
        : 0.0;

    final oldEditState = _captureEditState();
    final oldUndoState = List<_ClipEditState>.from(_undoStack);
    final oldRedoState = List<_ClipEditState>.from(_redoStack);

    final opacity = _secondaryTrackOpacity;
    final secondaryX = _secondaryTrackX;
    final secondaryY = _secondaryTrackY;
    final secondaryScale = _secondaryTrackScale;
    final visible = _secondaryTrackVisible;
    final oldAlphaMode = _secondaryTrackAlphaMode;
    final primaryGain = _primaryTrackAudioGain;
    final secondaryGain = _secondaryTrackAudioGain;

    // Probe the would-be base through the normal open path. This gives us its
    // authoritative frame rate and defensively rejects anything that MLT does
    // not classify as a timed video source.
    final opened = await open(oldSecondaryPath);
    final newBase = _media;

    if (!opened ||
        newBase == null ||
        newBase.isStill ||
        !newBase.hasVideo) {
      final swapError = !opened
          ? _error
          : 'Only a timed video can become the base layer.';

      await _rebuildLayerPair(
        primaryPath: oldBasePath,
        secondaryPath: oldSecondaryPath,
        secondaryStartFrame: oldStartFrame,
        playheadFrame: oldPlayheadFrame,
        primaryGain: primaryGain,
        secondaryGain: secondaryGain,
        secondaryOpacity: opacity,
        secondaryX: secondaryX,
        secondaryY: secondaryY,
        secondaryScale: secondaryScale,
        secondaryVisible: visible,
        secondaryAlphaMode: oldAlphaMode,
        editState: oldEditState,
        undoState: oldUndoState,
        redoState: oldRedoState,
      );

      _error = swapError ?? 'The layer order could not be changed.';
      notifyListeners();
      return false;
    }

    final newFps = newBase.fps;
    final newStartFrame = newFps > 0
        ? (oldStartSeconds * newFps).round()
        : 0;
    final newPlayheadFrame = newFps > 0
        ? (oldPlayheadSeconds * newFps).round()
        : 0;

    final swapped = await _rebuildLayerPair(
      primaryPath: oldSecondaryPath,
      secondaryPath: oldBasePath,
      secondaryStartFrame: newStartFrame,
      playheadFrame: newPlayheadFrame,
      primaryGain: primaryGain,
      secondaryGain: secondaryGain,
      secondaryOpacity: opacity,
      secondaryX: secondaryX,
      secondaryY: secondaryY,
      secondaryScale: secondaryScale,
      secondaryVisible: visible,
      // Alpha interpretation belongs to the asset. The old base is a new
      // overlay source, so begin conservatively in Auto.
      secondaryAlphaMode: 0,
    );

    if (swapped) {
      _error = null;
      notifyListeners();
      return true;
    }

    final swapError = _error;
    final rolledBack = await _rebuildLayerPair(
      primaryPath: oldBasePath,
      secondaryPath: oldSecondaryPath,
      secondaryStartFrame: oldStartFrame,
      playheadFrame: oldPlayheadFrame,
      primaryGain: primaryGain,
      secondaryGain: secondaryGain,
      secondaryOpacity: opacity,
      secondaryX: secondaryX,
      secondaryY: secondaryY,
      secondaryScale: secondaryScale,
      secondaryVisible: visible,
      secondaryAlphaMode: oldAlphaMode,
      editState: oldEditState,
      undoState: oldUndoState,
      redoState: oldRedoState,
    );

    _error = rolledBack
        ? (swapError ?? 'The layer order could not be changed.')
        : 'Layer swap failed and the previous composition could not be restored.';
    notifyListeners();
    return false;
  }

  Future<bool> _rebuildLayerPair({
    required String primaryPath,
    required String? secondaryPath,
    required int? secondaryStartFrame,
    required int playheadFrame,
    required double primaryGain,
    required double secondaryGain,
    required double secondaryOpacity,
    required double secondaryX,
    required double secondaryY,
    required double secondaryScale,
    required bool secondaryVisible,
    required int secondaryAlphaMode,
    _ClipEditState? editState,
    List<_ClipEditState>? undoState,
    List<_ClipEditState>? redoState,
  }) async {
    if (!await open(primaryPath)) {
      return false;
    }

    final media = _media;
    if (media == null || media.isStill || !media.hasVideo) {
      _error = 'Layer 1 must be a timed video source.';
      notifyListeners();
      return false;
    }

    _seekSourceFrameClamped(playheadFrame);

    if (secondaryPath != null) {
      final added = await _addTrackAtFrame(
        secondaryPath,
        secondaryStartFrame ?? 0,
      );
      if (!added) {
        return false;
      }
    }

    if (trackHasAudio(0)) {
      setTrackAudioGain(0, primaryGain);
    }

    if (secondaryPath != null && hasSecondaryTrack) {
      setSecondaryTrackGeometry(
        x: secondaryX,
        y: secondaryY,
        scale: secondaryScale,
      );
      setSecondaryTrackOpacity(secondaryOpacity);
      if (!secondaryVisible) {
        setSecondaryTrackVisible(false);
      }
      setSecondaryTrackAlphaMode(secondaryAlphaMode);
      if (trackHasAudio(1)) {
        setTrackAudioGain(1, secondaryGain);
      }
    }

    if (editState != null &&
        editState.trimInFrame >= 0 &&
        editState.trimOutFrame < media.frames) {
      _trimInFrame = editState.trimInFrame;
      _trimOutFrame = editState.trimOutFrame;
      _inFrame = editState.inFrame;
      _outFrame = editState.outFrame;
      _undoStack
        ..clear()
        ..addAll(undoState ?? const <_ClipEditState>[]);
      _redoStack
        ..clear()
        ..addAll(redoState ?? const <_ClipEditState>[]);
      _constrainSourcePositionToTrim();
    }

    _seekSourceFrameClamped(playheadFrame);
    _error = null;
    notifyListeners();
    return true;
  }

  void _seekSourceFrameClamped(int frame) {
    final media = _media;
    if (media == null || media.frames <= 0) {
      return;
    }

    final target = frame.clamp(0, media.frames - 1);
    if (bridge.seekFrame(target)) {
      _positionMs = bridge.positionMs;
      _playing = false;
      _playingSelection = false;
      _speed = 0.0;
      _eof = false;
    }
  }

  /// POC 10.4: update Layer 2 video opacity without rebuilding the tractor.
  ///
  /// POC 10.7 keeps visibility independent from opacity. While the layer is
  /// hidden, slider changes are remembered locally and applied the next time
  /// the eye control makes the layer visible.
  void setSecondaryTrackOpacity(double value) {
    if (!hasSecondaryTrack) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();

    if (!_secondaryTrackVisible) {
      _secondaryTrackOpacity = requested;
      _error = null;
      notifyListeners();
      return;
    }

    if (!bridge.setSecondaryOpacity(requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 2 opacity.'
          : bridge.lastError;
      _secondaryTrackOpacity =
          bridge.secondaryOpacity.clamp(0.0, 1.0).toDouble();
      notifyListeners();
      return;
    }

    _secondaryTrackOpacity =
        bridge.secondaryOpacity.clamp(0.0, 1.0).toDouble();
    _error = null;
    notifyListeners();
  }

  /// POC 10.7: show or hide Layer 2 without destroying its opacity setting.
  /// Native opacity zero is used only as the render switch; the inspector's
  /// requested opacity remains stored in _secondaryTrackOpacity.
  void setSecondaryTrackVisible(bool visible) {
    if (!hasSecondaryTrack || visible == _secondaryTrackVisible) {
      return;
    }

    final effectiveOpacity = visible ? _secondaryTrackOpacity : 0.0;

    if (!bridge.setSecondaryOpacity(effectiveOpacity)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 2 visibility.'
          : bridge.lastError;
      notifyListeners();
      return;
    }

    _secondaryTrackVisible = visible;
    _error = null;
    notifyListeners();
  }

  void toggleSecondaryTrackVisible() {
    setSecondaryTrackVisible(!_secondaryTrackVisible);
  }

  /// POC 10.8: move and uniformly scale Layer 2 without rebuilding the tractor.
  /// Coordinates are base-frame pixels measured from the top-left corner.
  void setSecondaryTrackGeometry({
    required double x,
    required double y,
    required double scale,
  }) {
    if (!hasSecondaryTrack) {
      return;
    }

    final requestedScale = scale.clamp(0.10, 3.0).toDouble();

    if (!bridge.setSecondaryGeometry(x, y, requestedScale)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 2 position or scale.'
          : bridge.lastError;
      _syncSecondaryGeometry();
      notifyListeners();
      return;
    }

    _syncSecondaryGeometry();
    _error = null;
    notifyListeners();
  }

  void setSecondaryTrackX(double value) {
    setSecondaryTrackGeometry(
      x: value,
      y: _secondaryTrackY,
      scale: _secondaryTrackScale,
    );
  }

  void setSecondaryTrackY(double value) {
    setSecondaryTrackGeometry(
      x: _secondaryTrackX,
      y: value,
      scale: _secondaryTrackScale,
    );
  }

  void setSecondaryTrackScale(double value) {
    setSecondaryTrackGeometry(
      x: _secondaryTrackX,
      y: _secondaryTrackY,
      scale: value,
    );
  }

  /// Anchor indices are row-major: 0 top-left through 8 bottom-right.
  void setSecondaryTrackAnchor(int anchor) {
    if (!hasSecondaryTrack) {
      return;
    }

    final requested = anchor.clamp(0, 8).toInt();

    if (!bridge.setSecondaryAnchor(requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not anchor Layer 2.'
          : bridge.lastError;
      _syncSecondaryGeometry();
      notifyListeners();
      return;
    }

    _syncSecondaryGeometry();
    _error = null;
    notifyListeners();
  }

  void _syncSecondaryGeometry() {
    _secondaryTrackX = bridge.secondaryX;
    _secondaryTrackY = bridge.secondaryY;
    _secondaryTrackScale =
        bridge.secondaryScale.clamp(0.10, 3.0).toDouble();
  }

  /// POC 10.6: interpret layer 2 alpha without rebuilding the tractor.
  ///
  /// 0 = Auto/native decode, 1 = Straight/native decode,
  /// 2 = Premultiplied (native bridge unpremultiplies RGB before composite).
  void setSecondaryTrackAlphaMode(int mode) {
    if (!hasSecondaryTrack) {
      return;
    }

    final requested = mode.clamp(0, 2).toInt();

    if (!bridge.setSecondaryAlphaMode(requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change layer 2 alpha interpretation.'
          : bridge.lastError;
      _secondaryTrackAlphaMode =
          bridge.secondaryAlphaMode.clamp(0, 2).toInt();
      notifyListeners();
      return;
    }

    _secondaryTrackAlphaMode =
        bridge.secondaryAlphaMode.clamp(0, 2).toInt();
    _error = null;
    notifyListeners();
  }

  /// POC 10.5: adjust one track's audio gain before the tractor mix.
  ///
  /// Track 0 is Movie A and track 1 is Movie B. The existing master volume
  /// remains independent and is applied after the mixed track audio.
  void setTrackAudioGain(int trackIndex, double value) {
    if (_media == null ||
        trackIndex < 0 ||
        trackIndex >= trackCount ||
        !trackHasAudio(trackIndex)) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();

    if (!bridge.setTrackAudioGain(trackIndex, requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change track ${trackIndex + 1} audio level.'
          : bridge.lastError;
      _syncTrackAudioGain(trackIndex);
      notifyListeners();
      return;
    }

    _syncTrackAudioGain(trackIndex);
    _error = null;
    notifyListeners();
  }

  bool trackHasAudio(int trackIndex) {
    if (trackIndex == 0) {
      return _media?.hasAudio ?? false;
    }
    if (trackIndex == 1) {
      return hasSecondaryTrack && _secondaryTrackHasAudio;
    }
    return false;
  }

  double trackAudioGain(int trackIndex) {
    if (trackIndex == 0) {
      return _primaryTrackAudioGain;
    }
    if (trackIndex == 1) {
      return _secondaryTrackAudioGain;
    }
    return 1.0;
  }

  void _syncTrackAudioGain(int trackIndex) {
    final applied =
        bridge.trackAudioGain(trackIndex).clamp(0.0, 1.0).toDouble();

    if (trackIndex == 0) {
      _primaryTrackAudioGain = applied;
    } else if (trackIndex == 1) {
      _secondaryTrackAudioGain = applied;
    }
  }

  void togglePlayback() {
    final media = _media;
    if (media == null || media.isStill) {
      return;
    }

    _playingSelection = false;

    if (!_playing && isTrimmed && media.fps > 0) {
      final currentFrame = bridge.positionFrame;
      if (currentFrame >= _trimOutFrame) {
        if (!bridge.seekFrame(_trimInFrame)) {
          _error = bridge.lastError;
          notifyListeners();
          return;
        }
      }
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

    _playingSelection = false;

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

    _playingSelection = false;

    if (isTrimmed && media.fps > 0) {
      final currentFrame = bridge.positionFrame;
      final atForwardEnd = direction > 0 && currentFrame >= _trimOutFrame;
      final atReverseStart = direction < 0 && currentFrame <= _trimInFrame;

      if (atForwardEnd || atReverseStart) {
        final restartFrame =
            direction > 0 ? _trimInFrame : _trimOutFrame;
        if (!bridge.seekFrame(restartFrame)) {
          _error = bridge.lastError;
          notifyListeners();
          return;
        }
      }
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
    final frames = clipFrameCount;
    if (media == null || media.fps <= 0 || frames <= 0) {
      return;
    }

    _playingSelection = false;

    final clamped = targetMs.clamp(0, durationMs);
    final clipFrame = ((clamped / 1000.0) * media.fps)
        .round()
        .clamp(0, frames - 1);
    final sourceFrame = _trimInFrame + clipFrame;

    if (!bridge.seekFrame(sourceFrame)) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _positionMs = bridge.positionMs;
    _eof = false;
    _error = null;
    notifyListeners();
  }

  void seekBy(int deltaMs) => seekTo(positionMs + deltaMs);

  void setInPoint() {
    final media = _media;
    if (_opening ||
        media == null ||
        media.isStill ||
        media.frames <= 0 ||
        media.fps <= 0) {
      return;
    }

    _playingSelection = false;

    final position = bridge.positionMs;
    final frame = bridge.positionFrame
        .clamp(_trimInFrame, _trimOutFrame);
    final before = _captureEditState();

    _inFrame = frame;

    // Keep the selection directional. If a new In point is placed beyond
    // the existing Out point, the stale Out point is no longer a valid
    // boundary and is cleared rather than silently swapping meanings.
    if (_outFrame != null && _outFrame! < frame) {
      _outFrame = null;
    }

    final after = _captureEditState();
    if (!before.sameAs(after)) {
      _recordEditBeforeChange(before);
    }

    _positionMs = position;
    _error = null;
    notifyListeners();
  }

  void setOutPoint() {
    final media = _media;
    if (_opening ||
        media == null ||
        media.isStill ||
        media.frames <= 0 ||
        media.fps <= 0) {
      return;
    }

    _playingSelection = false;

    final position = bridge.positionMs;
    final frame = bridge.positionFrame
        .clamp(_trimInFrame, _trimOutFrame);
    final before = _captureEditState();

    _outFrame = frame;

    // Mirror the In-point rule above: an Out point before the current In
    // clears that stale In point and leaves the newly placed marker intact.
    if (_inFrame != null && _inFrame! > frame) {
      _inFrame = null;
    }

    final after = _captureEditState();
    if (!before.sameAs(after)) {
      _recordEditBeforeChange(before);
    }

    _positionMs = position;
    _error = null;
    notifyListeners();
  }

  void trimSelection() {
    final media = _media;
    final inFrame = _inFrame;
    final outFrame = _outFrame;

    if (_opening ||
        media == null ||
        media.isStill ||
        media.frames <= 0 ||
        media.fps <= 0 ||
        inFrame == null ||
        outFrame == null ||
        inFrame > outFrame ||
        !canTrimSelection) {
      return;
    }

    final before = _captureEditState();

    _playingSelection = false;
    if (_playing && !bridge.pause()) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not pause before trimming.'
          : bridge.lastError;
      notifyListeners();
      return;
    }

    _playing = false;
    _speed = 0.0;
    _trimInFrame = inFrame;
    _trimOutFrame = outFrame;

    // The marked selection has become the active clip itself, so the
    // temporary editing markers are cleared. Undo restores both the old
    // bounds and the markers exactly as they were before Trim.
    _inFrame = null;
    _outFrame = null;

    _constrainSourcePositionToTrim();

    final after = _captureEditState();
    if (!before.sameAs(after)) {
      _recordEditBeforeChange(before);
    }

    _error = null;
    notifyListeners();
  }

  void clearSelection() {
    if (_inFrame == null && _outFrame == null) {
      return;
    }

    final before = _captureEditState();
    _playingSelection = false;
    _inFrame = null;
    _outFrame = null;
    _recordEditBeforeChange(before);
    notifyListeners();
  }

  void playSelection() {
    final media = _media;
    final inFrame = _inFrame;
    final outFrame = _outFrame;

    if (_opening ||
        media == null ||
        media.isStill ||
        media.frames <= 0 ||
        media.fps <= 0 ||
        inFrame == null ||
        outFrame == null ||
        inFrame > outFrame) {
      return;
    }

    // A one-frame selection is a useful exact navigation target even though
    // there is nothing meaningful to play through. Park on it and remain
    // paused.
    if (inFrame == outFrame) {
      if (_playing && !bridge.pause()) {
        _error = bridge.lastError;
        notifyListeners();
        return;
      }

      if (!bridge.seekFrame(inFrame)) {
        _error = bridge.lastError;
        notifyListeners();
        return;
      }

      _playingSelection = false;
      _playing = false;
      _speed = 0.0;
      _positionMs = bridge.positionMs;
      _eof = false;
      _error = null;
      notifyListeners();
      return;
    }

    if (_playing && !bridge.pause()) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    if (!bridge.seekFrame(inFrame)) {
      _playingSelection = false;
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    if (!bridge.setSpeed(1.0)) {
      _playingSelection = false;
      _playing = false;
      _speed = 0.0;
      _positionMs = bridge.positionMs;
      _error = bridge.lastError.isEmpty
          ? 'MLT could not play the marked selection.'
          : bridge.lastError;
      notifyListeners();
      return;
    }

    _playingSelection = true;
    _playing = bridge.isPlaying;
    _speed = bridge.speed;
    _positionMs = bridge.positionMs;
    _eof = false;
    _error = null;
    notifyListeners();
  }

  static int _midpointMsForFrame(MediaInfo media, int frame) {
    return (((frame + 0.5) * 1000.0) / media.fps).floor();
  }

  static int _frameAtPosition(MediaInfo media, int positionMs) {
    final frame = ((positionMs / 1000.0) * media.fps).round();
    return frame.clamp(0, media.frames - 1);
  }

  @visibleForTesting
  static int midpointMsForFrameForTesting(MediaInfo media, int frame) {
    return _midpointMsForFrame(media, frame);
  }

  @visibleForTesting
  static int frameAtPositionForTesting(MediaInfo media, int positionMs) {
    return _frameAtPosition(media, positionMs);
  }

  void stepFrames(int deltaFrames) {
    final media = _media;
    if (media == null || media.isStill || media.frames <= 0 || media.fps <= 0) {
      return;
    }

    _playingSelection = false;

    // Frame stepping is a paused operation. Pause first so the position we
    // calculate from is the exact frame MLT has parked on rather than a
    // consumer position that is still advancing underneath us.
    if (_playing && !bridge.pause()) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    final currentFrame = bridge.positionFrame;
    final targetFrame = (currentFrame + deltaFrames)
        .clamp(_trimInFrame, _trimOutFrame);

    if (!bridge.seekFrame(targetFrame)) {
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