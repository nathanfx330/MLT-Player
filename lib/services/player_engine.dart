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

    notifyListeners();
    return true;
  }

  /// POC 10.3: place one additional timed video source at the current exact
  /// playhead frame and promote the native viewer graph to a two-track tractor.
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

    if (_playing) {
      if (!bridge.pause()) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not pause before Add to Movie.'
            : bridge.lastError;
        notifyListeners();
        return false;
      }

      _playing = false;
      _playingSelection = false;
      _speed = 0.0;
      _positionMs = bridge.positionMs;
    }

    var startFrame = bridge.positionFrame;
    if (startFrame < 0) {
      startFrame = 0;
    }
    if (media.frames > 0 && startFrame >= media.frames) {
      startFrame = media.frames - 1;
    }

    _addingTrack = true;
    _error = null;
    notifyListeners();

    bool added;
    try {
      added = await addTrackOnHelperIsolate(
        path,
        startFrame,
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
          ? 'MLT could not add that movie as a second track.'
          : bridge.lastError;
      notifyListeners();
      return false;
    }

    _secondaryTrackPath = path;
    final nativeStartFrame = bridge.secondaryStartFrame;
    _secondaryTrackStartFrame =
        nativeStartFrame >= 0 ? nativeStartFrame : startFrame;
    _secondaryTrackOpacity =
        bridge.secondaryOpacity.clamp(0.0, 1.0).toDouble();
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

  /// POC 10.4: update track 2's video opacity in place without rebuilding
  /// the tractor or changing audio gain. The native bridge refreshes a paused
  /// preview frame immediately, so this is safe to drive directly from Slider.
  void setSecondaryTrackOpacity(double value) {
    if (!hasSecondaryTrack) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();

    if (!bridge.setSecondaryOpacity(requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change track 2 opacity.'
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