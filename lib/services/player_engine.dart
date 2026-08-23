// lib/services/player_engine.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/media_info.dart';
import 'mlt_bridge.dart';
import 'mlt_layer_bridge.dart';

enum PlaybackRepeatMode { off, loop }

enum ExportRangeMode { wholeMovie, inOut }

/// Immutable snapshot of the editable clip and composition state.
///
/// POC 10 hardening extends the original trim/selection history so Undo/Redo
/// also owns Layer 2 topology and the live composition controls. Source/media
/// metadata that can be re-derived after a rebuild is deliberately excluded.
class _ClipEditState {
  const _ClipEditState({
    required this.trimInFrame,
    required this.trimOutFrame,
    required this.inFrame,
    required this.outFrame,
    required this.secondaryTrackPath,
    required this.secondaryTrackStartFrame,
    required this.secondaryTrackOpacity,
    required this.secondaryTrackX,
    required this.secondaryTrackY,
    required this.secondaryTrackScale,
    required this.secondaryTrackVisible,
    required this.secondaryTrackAlphaMode,
    required this.tertiaryTrackPath,
    required this.tertiaryTrackStartFrame,
    required this.tertiaryTrackOpacity,
    required this.tertiaryTrackX,
    required this.tertiaryTrackY,
    required this.tertiaryTrackScale,
    required this.tertiaryTrackVisible,
    required this.tertiaryTrackAlphaMode,
    required this.primaryTrackAudioGain,
    required this.secondaryTrackAudioGain,
    required this.tertiaryTrackAudioGain,
  });

  final int trimInFrame;
  final int trimOutFrame;
  final int? inFrame;
  final int? outFrame;

  final String? secondaryTrackPath;
  final int? secondaryTrackStartFrame;
  final double secondaryTrackOpacity;
  final double secondaryTrackX;
  final double secondaryTrackY;
  final double secondaryTrackScale;
  final bool secondaryTrackVisible;
  final int secondaryTrackAlphaMode;

  final String? tertiaryTrackPath;
  final int? tertiaryTrackStartFrame;
  final double tertiaryTrackOpacity;
  final double tertiaryTrackX;
  final double tertiaryTrackY;
  final double tertiaryTrackScale;
  final bool tertiaryTrackVisible;
  final int tertiaryTrackAlphaMode;

  final double primaryTrackAudioGain;
  final double secondaryTrackAudioGain;
  final double tertiaryTrackAudioGain;

  static bool _near(double a, double b) => (a - b).abs() < 0.000001;

  bool sameAs(_ClipEditState other) =>
      trimInFrame == other.trimInFrame &&
      trimOutFrame == other.trimOutFrame &&
      inFrame == other.inFrame &&
      outFrame == other.outFrame &&
      secondaryTrackPath == other.secondaryTrackPath &&
      secondaryTrackStartFrame == other.secondaryTrackStartFrame &&
      _near(secondaryTrackOpacity, other.secondaryTrackOpacity) &&
      _near(secondaryTrackX, other.secondaryTrackX) &&
      _near(secondaryTrackY, other.secondaryTrackY) &&
      _near(secondaryTrackScale, other.secondaryTrackScale) &&
      secondaryTrackVisible == other.secondaryTrackVisible &&
      secondaryTrackAlphaMode == other.secondaryTrackAlphaMode &&
      tertiaryTrackPath == other.tertiaryTrackPath &&
      tertiaryTrackStartFrame == other.tertiaryTrackStartFrame &&
      _near(tertiaryTrackOpacity, other.tertiaryTrackOpacity) &&
      _near(tertiaryTrackX, other.tertiaryTrackX) &&
      _near(tertiaryTrackY, other.tertiaryTrackY) &&
      _near(tertiaryTrackScale, other.tertiaryTrackScale) &&
      tertiaryTrackVisible == other.tertiaryTrackVisible &&
      tertiaryTrackAlphaMode == other.tertiaryTrackAlphaMode &&
      _near(primaryTrackAudioGain, other.primaryTrackAudioGain) &&
      _near(secondaryTrackAudioGain, other.secondaryTrackAudioGain) &&
      _near(tertiaryTrackAudioGain, other.tertiaryTrackAudioGain);
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

  static const String _invalidInOutExportIssue =
      'In/Out export requires both an In point and an Out point.';
  static const String _invalidExportRangeIssue =
      'The requested export range is invalid.';

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

  String? _tertiaryTrackPath;
  int? _tertiaryTrackStartFrame;
  double _tertiaryTrackOpacity = 1.0;
  double _tertiaryTrackX = 0.0;
  double _tertiaryTrackY = 0.0;
  double _tertiaryTrackScale = 1.0;
  bool _tertiaryTrackVisible = true;
  bool _tertiaryTrackIsStill = false;
  bool _tertiaryTrackHasAlpha = false;
  int _tertiaryTrackAlphaMode = 0;
  double _tertiaryTrackAudioGain = 1.0;
  bool _tertiaryTrackHasAudio = false;

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
  String? _exportRangeIssue;
  ExportRangeMode _exportRangeMode = ExportRangeMode.wholeMovie;
  bool _exportRangeModeExplicit = false;

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

  bool _restoringEditState = false;
  int _notificationHoldDepth = 0;
  bool _notificationPending = false;
  String? _continuousEditKey;
  Timer? _continuousEditTimer;

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

  String? get tertiaryTrackPath => _tertiaryTrackPath;
  int? get tertiaryTrackStartFrame => _tertiaryTrackStartFrame;
  double get tertiaryTrackOpacity => _tertiaryTrackOpacity;
  double get tertiaryTrackX => _tertiaryTrackX;
  double get tertiaryTrackY => _tertiaryTrackY;
  double get tertiaryTrackScale => _tertiaryTrackScale;
  bool get tertiaryTrackVisible => _tertiaryTrackVisible;
  bool get tertiaryTrackIsStill => _tertiaryTrackIsStill;
  bool get tertiaryTrackHasAlpha => _tertiaryTrackHasAlpha;
  int get tertiaryTrackAlphaMode => _tertiaryTrackAlphaMode;
  double get tertiaryTrackAudioGain => _tertiaryTrackAudioGain;
  bool get tertiaryTrackHasAudio => _tertiaryTrackHasAudio;
  bool get hasTertiaryTrack => _tertiaryTrackPath != null;

  int get trackCount => _media == null
      ? 0
      : (hasTertiaryTrack ? 3 : (hasSecondaryTrack ? 2 : 1));
  bool get exportsAvailable =>
      _media != null && !_media!.isStill && _media!.frames > 0;
  bool get exportHasAudio =>
      (_media?.hasAudio ?? false) ||
      (hasSecondaryTrack && _secondaryTrackHasAudio) ||
      (hasTertiaryTrack && _tertiaryTrackHasAudio);

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
  String? get exportRangeIssue => _exportRangeIssue;
  bool get hasExportStatus =>
      _exporting || _exportSucceeded || _exportError != null;

  // Export mode is an explicit user choice. Never silently substitute Whole
  // Movie when In/Out is selected but its markers are missing or invalid.
  ExportRangeMode get exportRangeMode => _exportRangeMode;

  int get exportInFrame {
    if (_exportRangeMode == ExportRangeMode.inOut) {
      return hasSelection ? _inFrame! : -1;
    }
    return _trimInFrame;
  }

  int get exportOutFrame {
    if (_exportRangeMode == ExportRangeMode.inOut) {
      return hasSelection ? _outFrame! : -1;
    }
    return _trimOutFrame;
  }

  int get exportFrameCount {
    if (_exportRangeMode == ExportRangeMode.inOut && !hasSelection) {
      return 0;
    }

    final start = exportInFrame;
    final end = exportOutFrame;
    return start >= 0 && end >= start ? end - start + 1 : 0;
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

  bool get canUndo => !_restoringEditState && _undoStack.isNotEmpty;
  bool get canRedo => !_restoringEditState && _redoStack.isNotEmpty;

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

  @override
  void notifyListeners() {
    if (_notificationHoldDepth > 0) {
      _notificationPending = true;
      return;
    }

    super.notifyListeners();
  }

  void _holdNotifications() {
    _notificationHoldDepth += 1;
  }

  void _releaseNotifications() {
    if (_notificationHoldDepth <= 0) {
      return;
    }

    _notificationHoldDepth -= 1;

    if (_notificationHoldDepth == 0 && _notificationPending) {
      _notificationPending = false;
      super.notifyListeners();
    }
  }

  _ClipEditState _captureEditState() {
    return _ClipEditState(
      trimInFrame: _trimInFrame,
      trimOutFrame: _trimOutFrame,
      inFrame: _inFrame,
      outFrame: _outFrame,
      secondaryTrackPath: _secondaryTrackPath,
      secondaryTrackStartFrame: _secondaryTrackStartFrame,
      secondaryTrackOpacity: _secondaryTrackOpacity,
      secondaryTrackX: _secondaryTrackX,
      secondaryTrackY: _secondaryTrackY,
      secondaryTrackScale: _secondaryTrackScale,
      secondaryTrackVisible: _secondaryTrackVisible,
      secondaryTrackAlphaMode: _secondaryTrackAlphaMode,
      tertiaryTrackPath: _tertiaryTrackPath,
      tertiaryTrackStartFrame: _tertiaryTrackStartFrame,
      tertiaryTrackOpacity: _tertiaryTrackOpacity,
      tertiaryTrackX: _tertiaryTrackX,
      tertiaryTrackY: _tertiaryTrackY,
      tertiaryTrackScale: _tertiaryTrackScale,
      tertiaryTrackVisible: _tertiaryTrackVisible,
      tertiaryTrackAlphaMode: _tertiaryTrackAlphaMode,
      primaryTrackAudioGain: _primaryTrackAudioGain,
      secondaryTrackAudioGain: _secondaryTrackAudioGain,
      tertiaryTrackAudioGain: _tertiaryTrackAudioGain,
    );
  }

  void _finishContinuousEditGroup() {
    _continuousEditTimer?.cancel();
    _continuousEditTimer = null;
    _continuousEditKey = null;
  }

  void _recordEditBeforeChange(
    _ClipEditState before, {
    String? continuousKey,
  }) {
    if (_restoringEditState) {
      return;
    }

    if (continuousKey == null) {
      _finishContinuousEditGroup();
      _undoStack.add(before);
    } else {
      if (_continuousEditKey != continuousKey) {
        _undoStack.add(before);
      }

      _continuousEditKey = continuousKey;
      _continuousEditTimer?.cancel();
      _continuousEditTimer = Timer(
        const Duration(milliseconds: 500),
        _finishContinuousEditGroup,
      );
    }

    _redoStack.clear();
  }

  void _restoreClipFields(_ClipEditState state) {
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
    _syncExportRangeState(allowImplicitInOut: true);

    if (boundsChanged) {
      _constrainSourcePositionToTrim();
    }
  }

  Future<bool> _runWithFrozenPreview(
    Future<bool> Function() operation,
  ) async {
    _holdNotifications();

    final began = bridge.beginPreviewUpdate();
    var ended = true;

    try {
      final result = await operation();

      if (began) {
        ended = bridge.endPreviewUpdate();
      }

      if (result && !ended) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not publish the rebuilt composition frame.'
            : bridge.lastError;
        return false;
      }

      return result;
    } catch (_) {
      if (began) {
        bridge.endPreviewUpdate();
      }
      rethrow;
    } finally {
      _releaseNotifications();
    }
  }

  Future<bool> _applyEditState(
    _ClipEditState state, {
    required String basePath,
    required int playheadFrame,
  }) async {
    final topologyChanged =
        state.secondaryTrackPath != _secondaryTrackPath ||
        state.tertiaryTrackPath != _tertiaryTrackPath ||
        (state.secondaryTrackPath != null &&
            state.secondaryTrackStartFrame != _secondaryTrackStartFrame) ||
        (state.tertiaryTrackPath != null &&
            state.tertiaryTrackStartFrame != _tertiaryTrackStartFrame);

    if (topologyChanged) {
      return _runWithFrozenPreview(
        () => _rebuildLayerStack(
          primaryPath: basePath,
          secondaryPath: state.secondaryTrackPath,
          secondaryStartFrame: state.secondaryTrackStartFrame,
          tertiaryPath: state.tertiaryTrackPath,
          tertiaryStartFrame: state.tertiaryTrackStartFrame,
          playheadFrame: playheadFrame,
          primaryGain: state.primaryTrackAudioGain,
          secondaryGain: state.secondaryTrackAudioGain,
          tertiaryGain: state.tertiaryTrackAudioGain,
          secondaryOpacity: state.secondaryTrackOpacity,
          secondaryX: state.secondaryTrackX,
          secondaryY: state.secondaryTrackY,
          secondaryScale: state.secondaryTrackScale,
          secondaryVisible: state.secondaryTrackVisible,
          secondaryAlphaMode: state.secondaryTrackAlphaMode,
          tertiaryOpacity: state.tertiaryTrackOpacity,
          tertiaryX: state.tertiaryTrackX,
          tertiaryY: state.tertiaryTrackY,
          tertiaryScale: state.tertiaryTrackScale,
          tertiaryVisible: state.tertiaryTrackVisible,
          tertiaryAlphaMode: state.tertiaryTrackAlphaMode,
          editState: state,
          undoState: const <_ClipEditState>[],
          redoState: const <_ClipEditState>[],
        ),
      );
    }

    _restoreClipFields(state);

    if (trackHasAudio(0)) {
      if (!bridge.setTrackAudioGain(0, state.primaryTrackAudioGain)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 1 audio level.'
            : bridge.lastError;
        return false;
      }
      _syncTrackAudioGain(0);
    }

    if (state.secondaryTrackPath != null && hasSecondaryTrack) {
      if (!bridge.setSecondaryGeometry(
        state.secondaryTrackX,
        state.secondaryTrackY,
        state.secondaryTrackScale,
      )) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 2 geometry.'
            : bridge.lastError;
        return false;
      }
      _syncSecondaryGeometry();

      final effectiveOpacity = state.secondaryTrackVisible
          ? state.secondaryTrackOpacity
          : 0.0;
      if (!bridge.setSecondaryOpacity(effectiveOpacity)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 2 opacity.'
            : bridge.lastError;
        return false;
      }
      _secondaryTrackOpacity = state.secondaryTrackOpacity;
      _secondaryTrackVisible = state.secondaryTrackVisible;

      if (!bridge.setSecondaryAlphaMode(state.secondaryTrackAlphaMode)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 2 alpha interpretation.'
            : bridge.lastError;
        return false;
      }
      _secondaryTrackAlphaMode =
          bridge.secondaryAlphaMode.clamp(0, 2).toInt();

      if (trackHasAudio(1)) {
        if (!bridge.setTrackAudioGain(1, state.secondaryTrackAudioGain)) {
          _error = bridge.lastError.isEmpty
              ? 'MLT could not restore Layer 2 audio level.'
              : bridge.lastError;
          return false;
        }
        _syncTrackAudioGain(1);
      }
    }

    if (state.tertiaryTrackPath != null && hasTertiaryTrack) {
      if (!bridge.setLayerGeometry(
        2,
        state.tertiaryTrackX,
        state.tertiaryTrackY,
        state.tertiaryTrackScale,
      )) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 3 geometry.'
            : bridge.lastError;
        return false;
      }
      _syncTertiaryGeometry();

      final effectiveOpacity = state.tertiaryTrackVisible
          ? state.tertiaryTrackOpacity
          : 0.0;
      if (!bridge.setLayerOpacity(2, effectiveOpacity)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 3 opacity.'
            : bridge.lastError;
        return false;
      }
      _tertiaryTrackOpacity = state.tertiaryTrackOpacity;
      _tertiaryTrackVisible = state.tertiaryTrackVisible;

      if (!bridge.setLayerAlphaMode(2, state.tertiaryTrackAlphaMode)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 3 alpha interpretation.'
            : bridge.lastError;
        return false;
      }
      _tertiaryTrackAlphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();

      if (trackHasAudio(2)) {
        if (!bridge.setTrackAudioGain(2, state.tertiaryTrackAudioGain)) {
          _error = bridge.lastError.isEmpty
              ? 'MLT could not restore Layer 3 audio level.'
              : bridge.lastError;
          return false;
        }
        _syncTrackAudioGain(2);
      }
    }

    _error = null;
    return true;
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
    if (!canUndo) {
      return;
    }
    unawaited(_moveEditHistory(undoing: true));
  }

  void redo() {
    if (!canRedo) {
      return;
    }
    unawaited(_moveEditHistory(undoing: false));
  }

  Future<void> _moveEditHistory({required bool undoing}) async {
    if (_restoringEditState || _media == null) {
      return;
    }

    _finishContinuousEditGroup();

    final originalUndo = List<_ClipEditState>.from(_undoStack);
    final originalRedo = List<_ClipEditState>.from(_redoStack);
    final source = undoing ? originalUndo : originalRedo;
    if (source.isEmpty) {
      return;
    }

    final current = _captureEditState();
    final target = source.removeLast();
    final desiredUndo = undoing
        ? List<_ClipEditState>.from(source)
        : List<_ClipEditState>.from(originalUndo);
    final desiredRedo = undoing
        ? List<_ClipEditState>.from(originalRedo)
        : List<_ClipEditState>.from(source);

    if (undoing) {
      desiredRedo.add(current);
    } else {
      desiredUndo.add(current);
    }

    final basePath = _media!.path;
    final playheadFrame = bridge.positionFrame;

    _restoringEditState = true;
    notifyListeners();

    final restored = await _applyEditState(
      target,
      basePath: basePath,
      playheadFrame: playheadFrame,
    );

    if (restored) {
      _undoStack
        ..clear()
        ..addAll(desiredUndo);
      _redoStack
        ..clear()
        ..addAll(desiredRedo);
      _error = null;
    } else {
      final historyError = _error;
      final rolledBack = await _applyEditState(
        current,
        basePath: basePath,
        playheadFrame: playheadFrame,
      );

      _undoStack
        ..clear()
        ..addAll(originalUndo);
      _redoStack
        ..clear()
        ..addAll(originalRedo);

      _error = rolledBack
          ? (historyError ??
              '${undoing ? 'Undo' : 'Redo'} could not restore that edit.')
          : '${undoing ? 'Undo' : 'Redo'} failed and the previous composition could not be restored.';
    }

    _restoringEditState = false;
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

  void setExportRangeMode(ExportRangeMode mode) {
    // Choosing a range in the export menu is an explicit user decision even
    // when it matches the current value. Remember that decision so later
    // marker edits cannot silently flip Whole Movie back to In/Out.
    final changed = _exportRangeMode != mode || !_exportRangeModeExplicit;
    _exportRangeMode = mode;
    _exportRangeModeExplicit = true;
    _syncExportRangeState();

    if (changed) {
      notifyListeners();
    }
  }

  // Keep range validity separate from export execution status. Marker edits
  // can make an In/Out request temporarily unsatisfied, but they must never
  // overwrite the result/error of an export that is already running.
  void _syncExportRangeState({bool allowImplicitInOut = false}) {
    if (allowImplicitInOut &&
        hasSelection &&
        !_exportRangeModeExplicit &&
        _exportRangeMode == ExportRangeMode.wholeMovie) {
      _exportRangeMode = ExportRangeMode.inOut;
    }

    _exportRangeIssue =
        _exportRangeMode == ExportRangeMode.inOut && !hasSelection
            ? _invalidInOutExportIssue
            : null;
  }

  bool _validateRequestedExportRange() {
    _syncExportRangeState();

    if (_exportRangeIssue != null) {
      notifyListeners();
      return false;
    }

    final media = _media;
    final start = exportInFrame;
    final end = exportOutFrame;

    if (media == null ||
        start < 0 ||
        end < start ||
        end >= media.frames) {
      _exportRangeIssue = _invalidExportRangeIssue;
      notifyListeners();
      return false;
    }

    // A previously invalid range can become valid after marker/trim changes.
    if (_exportRangeIssue == _invalidExportRangeIssue) {
      _exportRangeIssue = null;
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

  bool _startCompositionExport({
    required String outputPath,
    required int inFrame,
    required int outFrame,
    required int kind,
    required String fallbackError,
  }) {
    final media = _media;

    // Last line of defense before crossing the FFI boundary. The Dart layer
    // must never hand native code a negative, reversed, or out-of-source
    // range, regardless of which export command reached this method.
    if (media == null ||
        inFrame < 0 ||
        outFrame < inFrame ||
        outFrame >= media.frames) {
      _exporting = false;
      _exportSucceeded = false;
      _exportProgress = 0.0;
      _exportPath = outputPath;
      _exportError = 'The requested export range is invalid.';
      notifyListeners();
      return false;
    }

    _exportSucceeded = false;
    _exportError = null;
    _exportProgress = 0.0;
    _exportPath = outputPath;

    final started = bridge.startCompositionExport(
      outputPath: outputPath,
      inFrame: inFrame,
      outFrame: outFrame,
      kind: kind,
    );

    if (!started) {
      _exporting = false;
      _exportError =
          bridge.exportError.isEmpty ? fallbackError : bridge.exportError;
      notifyListeners();
      return false;
    }

    _exporting = true;
    notifyListeners();
    return true;
  }

  bool startFrameExport(String outputPath, {required int sourceFrame}) {
    final media = _media;

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

    return _startCompositionExport(
      outputPath: outputPath,
      inFrame: sourceFrame,
      outFrame: sourceFrame,
      kind: 1,
      fallbackError: 'MLT could not start composited frame export.',
    );
  }

  bool startImageSequenceExport(String outputDirectory) {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        media.frames <= 0 ||
        _exporting) {
      return false;
    }

    if (!_validateRequestedExportRange()) {
      return false;
    }

    return _startCompositionExport(
      outputPath: outputDirectory,
      inFrame: exportInFrame,
      outFrame: exportOutFrame,
      kind: 2,
      fallbackError: 'MLT could not start composited image-sequence export.',
    );
  }

  bool startAudioExport(String outputPath) {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !exportHasAudio ||
        media.frames <= 0 ||
        _exporting) {
      return false;
    }

    if (!_validateRequestedExportRange()) {
      return false;
    }

    return _startCompositionExport(
      outputPath: outputPath,
      inFrame: exportInFrame,
      outFrame: exportOutFrame,
      kind: 3,
      fallbackError: 'MLT could not start composited audio export.',
    );
  }

  bool startExport(String outputPath) {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        media.frames <= 0 ||
        _exporting) {
      return false;
    }

    if (!_validateRequestedExportRange()) {
      return false;
    }

    return _startCompositionExport(
      outputPath: outputPath,
      inFrame: exportInFrame,
      outFrame: exportOutFrame,
      kind: 0,
      fallbackError: 'MLT could not start composited video export.',
    );
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

    _finishContinuousEditGroup();
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
    _tertiaryTrackPath = null;
    _tertiaryTrackStartFrame = null;
    _tertiaryTrackOpacity = 1.0;
    _tertiaryTrackX = 0.0;
    _tertiaryTrackY = 0.0;
    _tertiaryTrackScale = 1.0;
    _tertiaryTrackVisible = true;
    _tertiaryTrackIsStill = false;
    _tertiaryTrackHasAlpha = false;
    _tertiaryTrackAlphaMode = 0;
    _tertiaryTrackAudioGain = 1.0;
    _tertiaryTrackHasAudio = false;
    _playingSelection = false;
    _exportRangeMode = ExportRangeMode.wholeMovie;
    _exportRangeModeExplicit = false;
    _exportRangeIssue = null;
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
  /// playhead frame. The first addition creates Layer 2; the second creates
  /// Layer 3. Adding a layer establishes a new Undo baseline, matching the
  /// QuickTime-style rule used for Layer 2 during POC 10 hardening.
  Future<bool> addTrack(String path) async {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState ||
        trackCount >= 3) {
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

    final added = await _addTrackAtFrame(path, startFrame);
    if (added) {
      _finishContinuousEditGroup();
      _undoStack.clear();
      _redoStack.clear();
      notifyListeners();
    }
    return added;
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
        trackCount >= 3) {
      return false;
    }

    final targetLayerIndex = hasSecondaryTrack ? 2 : 1;

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
          ? 'MLT could not add that media as Layer ${targetLayerIndex + 1}.'
          : bridge.lastError;
      notifyListeners();
      return false;
    }

    if (targetLayerIndex == 1) {
      _secondaryTrackPath = path;
      final nativeStartFrame = bridge.layerStartFrame(1);
      _secondaryTrackStartFrame =
          nativeStartFrame >= 0 ? nativeStartFrame : clampedStart;
      _secondaryTrackOpacity =
          bridge.layerOpacity(1).clamp(0.0, 1.0).toDouble();
      _secondaryTrackX = bridge.layerX(1);
      _secondaryTrackY = bridge.layerY(1);
      _secondaryTrackScale = bridge.layerScale(1).clamp(0.10, 3.0).toDouble();
      _secondaryTrackVisible = true;
      _secondaryTrackIsStill = bridge.layerIsStill(1);
      _secondaryTrackHasAlpha = bridge.layerHasAlpha(1);
      _secondaryTrackAlphaMode = bridge.layerAlphaMode(1).clamp(0, 2).toInt();
      _secondaryTrackHasAudio = bridge.trackHasAudio(1);
      _secondaryTrackAudioGain =
          bridge.trackAudioGain(1).clamp(0.0, 1.0).toDouble();
    } else {
      _tertiaryTrackPath = path;
      final nativeStartFrame = bridge.layerStartFrame(2);
      _tertiaryTrackStartFrame =
          nativeStartFrame >= 0 ? nativeStartFrame : clampedStart;
      _tertiaryTrackOpacity =
          bridge.layerOpacity(2).clamp(0.0, 1.0).toDouble();
      _tertiaryTrackX = bridge.layerX(2);
      _tertiaryTrackY = bridge.layerY(2);
      _tertiaryTrackScale = bridge.layerScale(2).clamp(0.10, 3.0).toDouble();
      _tertiaryTrackVisible = true;
      _tertiaryTrackIsStill = bridge.layerIsStill(2);
      _tertiaryTrackHasAlpha = bridge.layerHasAlpha(2);
      _tertiaryTrackAlphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();
      _tertiaryTrackHasAudio = bridge.trackHasAudio(2);
      _tertiaryTrackAudioGain =
          bridge.trackAudioGain(2).clamp(0.0, 1.0).toDouble();
    }

    _primaryTrackAudioGain =
        bridge.trackAudioGain(0).clamp(0.0, 1.0).toDouble();
    if (hasSecondaryTrack) {
      _secondaryTrackHasAudio = bridge.trackHasAudio(1);
      _secondaryTrackAudioGain =
          bridge.trackAudioGain(1).clamp(0.0, 1.0).toDouble();
    }

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

  /// Remove Layer 2 while preserving the base movie and clip edit state.
  /// The operation is a normal Undo/Redo edit; Undo reconstructs the removed
  /// layer from the captured path, placement, geometry, alpha, and gain state.
  Future<bool> removeSecondaryLayer() async {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        !hasSecondaryTrack ||
        hasTertiaryTrack ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    final before = _captureEditState();
    final undoState = List<_ClipEditState>.from(_undoStack);
    final redoState = List<_ClipEditState>.from(_redoStack);
    final playheadFrame = bridge.positionFrame;

    final removed = await _rebuildLayerStack(
      primaryPath: media.path,
      secondaryPath: null,
      secondaryStartFrame: null,
      tertiaryPath: null,
      tertiaryStartFrame: null,
      playheadFrame: playheadFrame,
      primaryGain: before.primaryTrackAudioGain,
      secondaryGain: 1.0,
      secondaryOpacity: 1.0,
      secondaryX: 0.0,
      secondaryY: 0.0,
      secondaryScale: 1.0,
      secondaryVisible: true,
      secondaryAlphaMode: 0,
      tertiaryGain: 1.0,
      tertiaryOpacity: 1.0,
      tertiaryX: 0.0,
      tertiaryY: 0.0,
      tertiaryScale: 1.0,
      tertiaryVisible: true,
      tertiaryAlphaMode: 0,
      editState: before,
      undoState: undoState,
      redoState: redoState,
    );

    if (!removed) {
      return false;
    }

    final after = _captureEditState();
    if (!before.sameAs(after)) {
      _recordEditBeforeChange(before);
    }

    _error = null;
    notifyListeners();
    return true;
  }

  /// Remove only the top Layer 3. Layer 2 remains in place and Undo restores
  /// Layer 3 with its exact source, start, geometry, opacity, alpha, and gain.
  Future<bool> removeTertiaryLayer() async {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        !hasSecondaryTrack ||
        !hasTertiaryTrack ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    final before = _captureEditState();
    final undoState = List<_ClipEditState>.from(_undoStack);
    final redoState = List<_ClipEditState>.from(_redoStack);
    final playheadFrame = bridge.positionFrame;

    final removed = await _runWithFrozenPreview(
      () => _rebuildLayerStack(
        primaryPath: media.path,
        secondaryPath: before.secondaryTrackPath,
        secondaryStartFrame: before.secondaryTrackStartFrame,
        tertiaryPath: null,
        tertiaryStartFrame: null,
        playheadFrame: playheadFrame,
        primaryGain: before.primaryTrackAudioGain,
        secondaryGain: before.secondaryTrackAudioGain,
        tertiaryGain: 1.0,
        secondaryOpacity: before.secondaryTrackOpacity,
        secondaryX: before.secondaryTrackX,
        secondaryY: before.secondaryTrackY,
        secondaryScale: before.secondaryTrackScale,
        secondaryVisible: before.secondaryTrackVisible,
        secondaryAlphaMode: before.secondaryTrackAlphaMode,
        tertiaryOpacity: 1.0,
        tertiaryX: 0.0,
        tertiaryY: 0.0,
        tertiaryScale: 1.0,
        tertiaryVisible: true,
        tertiaryAlphaMode: 0,
        editState: before,
        undoState: undoState,
        redoState: redoState,
      ),
    );

    if (!removed) {
      return false;
    }

    final after = _captureEditState();
    if (!before.sameAs(after)) {
      _recordEditBeforeChange(before);
    }

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
        _exporting ||
        _restoringEditState) {
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    final editState = _captureEditState();
    final undoState = List<_ClipEditState>.from(_undoStack);
    final redoState = List<_ClipEditState>.from(_redoStack);
    final currentFrame = bridge.positionFrame;
    final basePath = media.path;

    Future<bool> rebuildWith(String secondaryPath, int secondaryAlphaMode) {
      return _rebuildLayerStack(
        primaryPath: basePath,
        secondaryPath: secondaryPath,
        secondaryStartFrame: editState.secondaryTrackStartFrame,
        tertiaryPath: editState.tertiaryTrackPath,
        tertiaryStartFrame: editState.tertiaryTrackStartFrame,
        playheadFrame: currentFrame,
        primaryGain: editState.primaryTrackAudioGain,
        secondaryGain: editState.secondaryTrackAudioGain,
        tertiaryGain: editState.tertiaryTrackAudioGain,
        secondaryOpacity: editState.secondaryTrackOpacity,
        secondaryX: editState.secondaryTrackX,
        secondaryY: editState.secondaryTrackY,
        secondaryScale: editState.secondaryTrackScale,
        secondaryVisible: editState.secondaryTrackVisible,
        secondaryAlphaMode: secondaryAlphaMode,
        tertiaryOpacity: editState.tertiaryTrackOpacity,
        tertiaryX: editState.tertiaryTrackX,
        tertiaryY: editState.tertiaryTrackY,
        tertiaryScale: editState.tertiaryTrackScale,
        tertiaryVisible: editState.tertiaryTrackVisible,
        tertiaryAlphaMode: editState.tertiaryTrackAlphaMode,
        editState: editState,
        undoState: undoState,
        redoState: redoState,
      );
    }

    final rebuilt = await rebuildWith(path, 0);
    if (rebuilt) {
      final after = _captureEditState();
      if (!editState.sameAs(after)) {
        _recordEditBeforeChange(editState);
      }
      return true;
    }

    final replaceError = _error;
    final rolledBack = await rebuildWith(
      oldSecondaryPath,
      editState.secondaryTrackAlphaMode,
    );

    _error = rolledBack
        ? (replaceError ?? 'The replacement layer source could not be opened.')
        : 'The replacement failed and the previous layer could not be restored.';
    notifyListeners();
    return false;
  }

  /// Replace Layer 3 while preserving its placement and controls. Layer 2 is
  /// rebuilt unchanged underneath it; the replacement asset starts in Auto
  /// alpha mode just like a Layer 2 source replacement.
  Future<bool> replaceTertiaryLayerSource(String path) async {
    final media = _media;
    final oldTertiaryPath = _tertiaryTrackPath;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        oldTertiaryPath == null ||
        !hasSecondaryTrack ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    final editState = _captureEditState();
    final undoState = List<_ClipEditState>.from(_undoStack);
    final redoState = List<_ClipEditState>.from(_redoStack);
    final currentFrame = bridge.positionFrame;
    final basePath = media.path;

    Future<bool> rebuildWith(String tertiaryPath, int tertiaryAlphaMode) {
      return _rebuildLayerStack(
        primaryPath: basePath,
        secondaryPath: editState.secondaryTrackPath,
        secondaryStartFrame: editState.secondaryTrackStartFrame,
        tertiaryPath: tertiaryPath,
        tertiaryStartFrame: editState.tertiaryTrackStartFrame,
        playheadFrame: currentFrame,
        primaryGain: editState.primaryTrackAudioGain,
        secondaryGain: editState.secondaryTrackAudioGain,
        tertiaryGain: editState.tertiaryTrackAudioGain,
        secondaryOpacity: editState.secondaryTrackOpacity,
        secondaryX: editState.secondaryTrackX,
        secondaryY: editState.secondaryTrackY,
        secondaryScale: editState.secondaryTrackScale,
        secondaryVisible: editState.secondaryTrackVisible,
        secondaryAlphaMode: editState.secondaryTrackAlphaMode,
        tertiaryOpacity: editState.tertiaryTrackOpacity,
        tertiaryX: editState.tertiaryTrackX,
        tertiaryY: editState.tertiaryTrackY,
        tertiaryScale: editState.tertiaryTrackScale,
        tertiaryVisible: editState.tertiaryTrackVisible,
        tertiaryAlphaMode: tertiaryAlphaMode,
        editState: editState,
        undoState: undoState,
        redoState: redoState,
      );
    }

    final rebuilt = await rebuildWith(path, 0);
    if (rebuilt) {
      final after = _captureEditState();
      if (!editState.sameAs(after)) {
        _recordEditBeforeChange(editState);
      }
      return true;
    }

    final replaceError = _error;
    final rolledBack = await rebuildWith(
      oldTertiaryPath,
      editState.tertiaryTrackAlphaMode,
    );

    _error = rolledBack
        ? (replaceError ?? 'The Layer 3 replacement source could not be opened.')
        : 'Layer 3 replacement failed and the previous source could not be restored.';
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
    final oldPlayheadFrame = bridge.positionFrame;
    final oldPlayheadSeconds = oldMedia.fps > 0
        ? oldPlayheadFrame / oldMedia.fps
        : 0.0;
    final secondaryStartSeconds = oldEditState.secondaryTrackPath != null &&
            oldEditState.secondaryTrackStartFrame != null &&
            oldMedia.fps > 0
        ? oldEditState.secondaryTrackStartFrame! / oldMedia.fps
        : 0.0;
    final tertiaryStartSeconds = oldEditState.tertiaryTrackPath != null &&
            oldEditState.tertiaryTrackStartFrame != null &&
            oldMedia.fps > 0
        ? oldEditState.tertiaryTrackStartFrame! / oldMedia.fps
        : 0.0;

    final opened = await open(path);
    final replacementMedia = _media;

    if (!opened ||
        replacementMedia == null ||
        replacementMedia.isStill ||
        !replacementMedia.hasVideo) {
      final replaceError = !opened
          ? _error
          : 'Layer 1 must be a timed video source; still images are overlay-only.';

      await _rebuildLayerStack(
        primaryPath: oldBasePath,
        secondaryPath: oldEditState.secondaryTrackPath,
        secondaryStartFrame: oldEditState.secondaryTrackStartFrame,
        tertiaryPath: oldEditState.tertiaryTrackPath,
        tertiaryStartFrame: oldEditState.tertiaryTrackStartFrame,
        playheadFrame: oldPlayheadFrame,
        primaryGain: oldEditState.primaryTrackAudioGain,
        secondaryGain: oldEditState.secondaryTrackAudioGain,
        tertiaryGain: oldEditState.tertiaryTrackAudioGain,
        secondaryOpacity: oldEditState.secondaryTrackOpacity,
        secondaryX: oldEditState.secondaryTrackX,
        secondaryY: oldEditState.secondaryTrackY,
        secondaryScale: oldEditState.secondaryTrackScale,
        secondaryVisible: oldEditState.secondaryTrackVisible,
        secondaryAlphaMode: oldEditState.secondaryTrackAlphaMode,
        tertiaryOpacity: oldEditState.tertiaryTrackOpacity,
        tertiaryX: oldEditState.tertiaryTrackX,
        tertiaryY: oldEditState.tertiaryTrackY,
        tertiaryScale: oldEditState.tertiaryTrackScale,
        tertiaryVisible: oldEditState.tertiaryTrackVisible,
        tertiaryAlphaMode: oldEditState.tertiaryTrackAlphaMode,
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
    final newSecondaryStart = oldEditState.secondaryTrackPath != null && newFps > 0
        ? (secondaryStartSeconds * newFps).round()
        : null;
    final newTertiaryStart = oldEditState.tertiaryTrackPath != null && newFps > 0
        ? (tertiaryStartSeconds * newFps).round()
        : null;

    if (oldEditState.secondaryTrackPath != null) {
      final rebuilt = await _rebuildLayerStack(
        primaryPath: path,
        secondaryPath: oldEditState.secondaryTrackPath,
        secondaryStartFrame: newSecondaryStart,
        tertiaryPath: oldEditState.tertiaryTrackPath,
        tertiaryStartFrame: newTertiaryStart,
        playheadFrame: newPlayheadFrame,
        primaryGain: oldEditState.primaryTrackAudioGain,
        secondaryGain: oldEditState.secondaryTrackAudioGain,
        tertiaryGain: oldEditState.tertiaryTrackAudioGain,
        secondaryOpacity: oldEditState.secondaryTrackOpacity,
        secondaryX: oldEditState.secondaryTrackX,
        secondaryY: oldEditState.secondaryTrackY,
        secondaryScale: oldEditState.secondaryTrackScale,
        secondaryVisible: oldEditState.secondaryTrackVisible,
        secondaryAlphaMode: oldEditState.secondaryTrackAlphaMode,
        tertiaryOpacity: oldEditState.tertiaryTrackOpacity,
        tertiaryX: oldEditState.tertiaryTrackX,
        tertiaryY: oldEditState.tertiaryTrackY,
        tertiaryScale: oldEditState.tertiaryTrackScale,
        tertiaryVisible: oldEditState.tertiaryTrackVisible,
        tertiaryAlphaMode: oldEditState.tertiaryTrackAlphaMode,
      );

      if (!rebuilt) {
        final replaceError = _error;
        await _rebuildLayerStack(
          primaryPath: oldBasePath,
          secondaryPath: oldEditState.secondaryTrackPath,
          secondaryStartFrame: oldEditState.secondaryTrackStartFrame,
          tertiaryPath: oldEditState.tertiaryTrackPath,
          tertiaryStartFrame: oldEditState.tertiaryTrackStartFrame,
          playheadFrame: oldPlayheadFrame,
          primaryGain: oldEditState.primaryTrackAudioGain,
          secondaryGain: oldEditState.secondaryTrackAudioGain,
          tertiaryGain: oldEditState.tertiaryTrackAudioGain,
          secondaryOpacity: oldEditState.secondaryTrackOpacity,
          secondaryX: oldEditState.secondaryTrackX,
          secondaryY: oldEditState.secondaryTrackY,
          secondaryScale: oldEditState.secondaryTrackScale,
          secondaryVisible: oldEditState.secondaryTrackVisible,
          secondaryAlphaMode: oldEditState.secondaryTrackAlphaMode,
          tertiaryOpacity: oldEditState.tertiaryTrackOpacity,
          tertiaryX: oldEditState.tertiaryTrackX,
          tertiaryY: oldEditState.tertiaryTrackY,
          tertiaryScale: oldEditState.tertiaryTrackScale,
          tertiaryVisible: oldEditState.tertiaryTrackVisible,
          tertiaryAlphaMode: oldEditState.tertiaryTrackAlphaMode,
          editState: oldEditState,
          undoState: oldUndoState,
          redoState: oldRedoState,
        );
        _error = replaceError ??
            'The new base video could not preserve the overlay layers.';
        notifyListeners();
        return false;
      }
    } else {
      _seekSourceFrameClamped(newPlayheadFrame);
      if (trackHasAudio(0)) {
        setTrackAudioGain(0, oldEditState.primaryTrackAudioGain, recordEdit: false);
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
        hasTertiaryTrack ||
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

      await _rebuildLayerStack(
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

    final swapped = await _rebuildLayerStack(
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
    final rolledBack = await _rebuildLayerStack(
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

  Future<bool> _rebuildLayerStack({
    required String primaryPath,
    required String? secondaryPath,
    required int? secondaryStartFrame,
    String? tertiaryPath,
    int? tertiaryStartFrame,
    required int playheadFrame,
    required double primaryGain,
    required double secondaryGain,
    double tertiaryGain = 1.0,
    required double secondaryOpacity,
    required double secondaryX,
    required double secondaryY,
    required double secondaryScale,
    required bool secondaryVisible,
    required int secondaryAlphaMode,
    double tertiaryOpacity = 1.0,
    double tertiaryX = 0.0,
    double tertiaryY = 0.0,
    double tertiaryScale = 1.0,
    bool tertiaryVisible = true,
    int tertiaryAlphaMode = 0,
    _ClipEditState? editState,
    List<_ClipEditState>? undoState,
    List<_ClipEditState>? redoState,
  }) async {
    final preservedExportRangeMode =
        editState != null ? _exportRangeMode : null;
    final preservedExportRangeModeExplicit =
        editState != null ? _exportRangeModeExplicit : null;

    if (tertiaryPath != null && secondaryPath == null) {
      _error = 'Layer 3 requires Layer 2 underneath it.';
      notifyListeners();
      return false;
    }

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

    if (tertiaryPath != null) {
      final added = await _addTrackAtFrame(
        tertiaryPath,
        tertiaryStartFrame ?? 0,
      );
      if (!added) {
        return false;
      }
    }

    if (trackHasAudio(0)) {
      setTrackAudioGain(0, primaryGain, recordEdit: false);
    }

    if (secondaryPath != null && hasSecondaryTrack) {
      setSecondaryTrackGeometry(
        x: secondaryX,
        y: secondaryY,
        scale: secondaryScale,
        recordEdit: false,
      );
      setSecondaryTrackOpacity(secondaryOpacity, recordEdit: false);
      if (!secondaryVisible) {
        setSecondaryTrackVisible(false, recordEdit: false);
      }
      setSecondaryTrackAlphaMode(secondaryAlphaMode, recordEdit: false);
      if (trackHasAudio(1)) {
        setTrackAudioGain(1, secondaryGain, recordEdit: false);
      }
    }

    if (tertiaryPath != null && hasTertiaryTrack) {
      setTertiaryTrackGeometry(
        x: tertiaryX,
        y: tertiaryY,
        scale: tertiaryScale,
        recordEdit: false,
      );
      setTertiaryTrackOpacity(tertiaryOpacity, recordEdit: false);
      if (!tertiaryVisible) {
        setTertiaryTrackVisible(false, recordEdit: false);
      }
      setTertiaryTrackAlphaMode(tertiaryAlphaMode, recordEdit: false);
      if (trackHasAudio(2)) {
        setTrackAudioGain(2, tertiaryGain, recordEdit: false);
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

      if (preservedExportRangeMode != null &&
          preservedExportRangeModeExplicit != null) {
        _exportRangeMode = preservedExportRangeMode;
        _exportRangeModeExplicit = preservedExportRangeModeExplicit;
        _syncExportRangeState();
      }
    }

    _seekSourceFrameClamped(playheadFrame);
    if (editState != null) {
      _constrainSourcePositionToTrim();
    }
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
  void setSecondaryTrackOpacity(
    double value, {
    bool recordEdit = true,
  }) {
    if (!hasSecondaryTrack || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();
    final before = recordEdit ? _captureEditState() : null;

    if (!_secondaryTrackVisible) {
      _secondaryTrackOpacity = requested;
      _error = null;

      if (before != null && !before.sameAs(_captureEditState())) {
        _recordEditBeforeChange(
          before,
          continuousKey: 'secondary-opacity',
        );
      }

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

    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(
        before,
        continuousKey: 'secondary-opacity',
      );
    }

    notifyListeners();
  }

  /// POC 10.7: show or hide Layer 2 without destroying its opacity setting.
  /// Native opacity zero is used only as the render switch; the inspector's
  /// requested opacity remains stored in _secondaryTrackOpacity.
  void setSecondaryTrackVisible(
    bool visible, {
    bool recordEdit = true,
  }) {
    if (!hasSecondaryTrack ||
        visible == _secondaryTrackVisible ||
        (recordEdit && _restoringEditState)) {
      return;
    }

    final before = recordEdit ? _captureEditState() : null;
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

    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }

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
    bool recordEdit = true,
  }) {
    if (!hasSecondaryTrack || (recordEdit && _restoringEditState)) {
      return;
    }

    final requestedScale = scale.clamp(0.10, 3.0).toDouble();
    final before = recordEdit ? _captureEditState() : null;

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

    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(
        before,
        continuousKey: 'secondary-geometry',
      );
    }

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
    if (!hasSecondaryTrack || _restoringEditState) {
      return;
    }

    final requested = anchor.clamp(0, 8).toInt();
    final before = _captureEditState();

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

    if (!before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }

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
  void setSecondaryTrackAlphaMode(
    int mode, {
    bool recordEdit = true,
  }) {
    if (!hasSecondaryTrack || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = mode.clamp(0, 2).toInt();
    final before = recordEdit ? _captureEditState() : null;

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

    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }

    notifyListeners();
  }

  void setTertiaryTrackOpacity(
    double value, {
    bool recordEdit = true,
  }) {
    if (!hasTertiaryTrack || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();
    final before = recordEdit ? _captureEditState() : null;

    if (!_tertiaryTrackVisible) {
      _tertiaryTrackOpacity = requested;
      _error = null;
      if (before != null && !before.sameAs(_captureEditState())) {
        _recordEditBeforeChange(before, continuousKey: 'tertiary-opacity');
      }
      notifyListeners();
      return;
    }

    if (!bridge.setLayerOpacity(2, requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 3 opacity.'
          : bridge.lastError;
      _tertiaryTrackOpacity =
          bridge.layerOpacity(2).clamp(0.0, 1.0).toDouble();
      notifyListeners();
      return;
    }

    _tertiaryTrackOpacity =
        bridge.layerOpacity(2).clamp(0.0, 1.0).toDouble();
    _error = null;
    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before, continuousKey: 'tertiary-opacity');
    }
    notifyListeners();
  }

  void setTertiaryTrackVisible(
    bool visible, {
    bool recordEdit = true,
  }) {
    if (!hasTertiaryTrack ||
        visible == _tertiaryTrackVisible ||
        (recordEdit && _restoringEditState)) {
      return;
    }

    final before = recordEdit ? _captureEditState() : null;
    final effectiveOpacity = visible ? _tertiaryTrackOpacity : 0.0;
    if (!bridge.setLayerOpacity(2, effectiveOpacity)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 3 visibility.'
          : bridge.lastError;
      notifyListeners();
      return;
    }

    _tertiaryTrackVisible = visible;
    _error = null;
    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }
    notifyListeners();
  }

  void toggleTertiaryTrackVisible() {
    setTertiaryTrackVisible(!_tertiaryTrackVisible);
  }

  void setTertiaryTrackGeometry({
    required double x,
    required double y,
    required double scale,
    bool recordEdit = true,
  }) {
    if (!hasTertiaryTrack || (recordEdit && _restoringEditState)) {
      return;
    }

    final requestedScale = scale.clamp(0.10, 3.0).toDouble();
    final before = recordEdit ? _captureEditState() : null;
    if (!bridge.setLayerGeometry(2, x, y, requestedScale)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 3 position or scale.'
          : bridge.lastError;
      _syncTertiaryGeometry();
      notifyListeners();
      return;
    }

    _syncTertiaryGeometry();
    _error = null;
    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before, continuousKey: 'tertiary-geometry');
    }
    notifyListeners();
  }

  void setTertiaryTrackX(double value) {
    setTertiaryTrackGeometry(
      x: value,
      y: _tertiaryTrackY,
      scale: _tertiaryTrackScale,
    );
  }

  void setTertiaryTrackY(double value) {
    setTertiaryTrackGeometry(
      x: _tertiaryTrackX,
      y: value,
      scale: _tertiaryTrackScale,
    );
  }

  void setTertiaryTrackScale(double value) {
    setTertiaryTrackGeometry(
      x: _tertiaryTrackX,
      y: _tertiaryTrackY,
      scale: value,
    );
  }

  void setTertiaryTrackAnchor(int anchor) {
    if (!hasTertiaryTrack || _restoringEditState) {
      return;
    }

    final requested = anchor.clamp(0, 8).toInt();
    final before = _captureEditState();
    if (!bridge.setLayerAnchor(2, requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not anchor Layer 3.'
          : bridge.lastError;
      _syncTertiaryGeometry();
      notifyListeners();
      return;
    }

    _syncTertiaryGeometry();
    _error = null;
    if (!before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }
    notifyListeners();
  }

  void _syncTertiaryGeometry() {
    _tertiaryTrackX = bridge.layerX(2);
    _tertiaryTrackY = bridge.layerY(2);
    _tertiaryTrackScale = bridge.layerScale(2).clamp(0.10, 3.0).toDouble();
  }

  void setTertiaryTrackAlphaMode(
    int mode, {
    bool recordEdit = true,
  }) {
    if (!hasTertiaryTrack || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = mode.clamp(0, 2).toInt();
    final before = recordEdit ? _captureEditState() : null;
    if (!bridge.setLayerAlphaMode(2, requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 3 alpha interpretation.'
          : bridge.lastError;
      _tertiaryTrackAlphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();
      notifyListeners();
      return;
    }

    _tertiaryTrackAlphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();
    _error = null;
    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }
    notifyListeners();
  }

  /// POC 10.5: adjust one track's audio gain before the tractor mix.
  ///
  /// Track 0 is the base, track 1 is Layer 2, and track 2 is Layer 3. The
  /// existing master volume remains independent and follows the mixed audio.
  void setTrackAudioGain(
    int trackIndex,
    double value, {
    bool recordEdit = true,
  }) {
    if (_media == null ||
        trackIndex < 0 ||
        trackIndex >= trackCount ||
        !trackHasAudio(trackIndex) ||
        (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();
    final before = recordEdit ? _captureEditState() : null;

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

    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(
        before,
        continuousKey: 'track-audio-$trackIndex',
      );
    }

    notifyListeners();
  }

  bool trackHasAudio(int trackIndex) {
    if (trackIndex == 0) {
      return _media?.hasAudio ?? false;
    }
    if (trackIndex == 1) {
      return hasSecondaryTrack && _secondaryTrackHasAudio;
    }
    if (trackIndex == 2) {
      return hasTertiaryTrack && _tertiaryTrackHasAudio;
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
    if (trackIndex == 2) {
      return _tertiaryTrackAudioGain;
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
    } else if (trackIndex == 2) {
      _tertiaryTrackAudioGain = applied;
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

    // The first completed selection makes In/Out the useful default. Once
    // the user explicitly chooses a range, marker edits respect that choice.
    _syncExportRangeState(allowImplicitInOut: true);

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

    // The first completed selection makes In/Out the useful default. Once
    // the user explicitly chooses a range, marker edits respect that choice.
    _syncExportRangeState(allowImplicitInOut: true);

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

    // Trim turns the marked range into the active movie itself. Reset export
    // range intent to Whole Movie so exporting the trimmed clip requires no
    // stale In/Out markers. This is a semantic consequence of Trim, not a
    // fallback from an invalid export request.
    _exportRangeMode = ExportRangeMode.wholeMovie;
    _exportRangeModeExplicit = false;
    _syncExportRangeState();

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
    _syncExportRangeState();
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
    _finishContinuousEditGroup();
    _poll?.cancel();
    _poll = null;
    bridge.shutdown();
    super.dispose();
  }
}