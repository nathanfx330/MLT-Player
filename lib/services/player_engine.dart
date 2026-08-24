// lib/services/player_engine.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../models/media_info.dart';
import 'mlt_bridge.dart';
import 'mlt_layer_bridge.dart';

enum PlaybackRepeatMode { off, loop }

enum ExportRangeMode { wholeMovie, inOut }

const int _baseLayerIndex = 0;
const int _secondaryLayerIndex = 1;
const int _tertiaryLayerIndex = 2;
const int _layerSlotCount = 3;

@immutable
class CompositionLayerState {
  const CompositionLayerState({
    required this.index,
    required this.present,
    required this.path,
    required this.startFrame,
    this.endFrame,
    this.sourceInFrame,
    this.sourceOutFrame,
    this.sourceFrameCount,
    required this.opacity,
    required this.x,
    required this.y,
    required this.scale,
    required this.visible,
    required this.isStill,
    required this.hasAlpha,
    required this.alphaMode,
    required this.hasAudio,
    required this.audioGain,
    this.visualPosition = 0,
  });

  final int index;
  final bool present;
  final String? path;
  final int? startFrame;
  final int? endFrame;
  final int? sourceInFrame;
  final int? sourceOutFrame;
  final int? sourceFrameCount;
  final double opacity;
  final double x;
  final double y;
  final double scale;
  final bool visible;
  final bool isStill;
  final bool hasAlpha;
  final int alphaMode;
  final bool hasAudio;
  final double audioGain;
  final int visualPosition;
}

/// Immutable per-layer snapshot used by clip/composition Undo and Redo.
///
/// Dart intentionally uses the same 0/1/2 slot numbering as native:
/// Layer 1/base, Layer 2, Layer 3. Keeping slot identity aligned across the
/// FFI boundary avoids hidden +1/-1 translations.
class _LayerEditState {
  const _LayerEditState({
    required this.present,
    required this.path,
    required this.startFrame,
    required this.endFrame,
    required this.sourceInFrame,
    required this.sourceOutFrame,
    required this.sourceFrameCount,
    required this.opacity,
    required this.x,
    required this.y,
    required this.scale,
    required this.visible,
    required this.isStill,
    required this.hasAlpha,
    required this.alphaMode,
    required this.hasAudio,
    required this.audioGain,
  });

  final bool present;
  final String? path;
  final int? startFrame;
  final int? endFrame;
  final int? sourceInFrame;
  final int? sourceOutFrame;
  final int? sourceFrameCount;
  final double opacity;
  final double x;
  final double y;
  final double scale;
  final bool visible;
  final bool isStill;
  final bool hasAlpha;
  final int alphaMode;
  final bool hasAudio;
  final double audioGain;

  static bool _near(double a, double b) => (a - b).abs() < 0.000001;

  bool sameAs(_LayerEditState other) =>
      present == other.present &&
      path == other.path &&
      startFrame == other.startFrame &&
      endFrame == other.endFrame &&
      sourceInFrame == other.sourceInFrame &&
      sourceOutFrame == other.sourceOutFrame &&
      sourceFrameCount == other.sourceFrameCount &&
      _near(opacity, other.opacity) &&
      _near(x, other.x) &&
      _near(y, other.y) &&
      _near(scale, other.scale) &&
      visible == other.visible &&
      isStill == other.isStill &&
      hasAlpha == other.hasAlpha &&
      alphaMode == other.alphaMode &&
      hasAudio == other.hasAudio &&
      _near(audioGain, other.audioGain);
}

/// Mutable runtime state for one fixed composition slot.
class _LayerRuntimeState {
  bool present = false;

  String? _path;
  String? get path => _path;
  set path(String? value) {
    _path = value;
    present = value != null;
  }

  int? startFrame;
  int? endFrame;
  int? sourceInFrame;
  int? sourceOutFrame;
  int? sourceFrameCount;
  double opacity = 1.0;
  double x = 0.0;
  double y = 0.0;
  double scale = 1.0;
  bool visible = true;
  bool isStill = false;
  bool hasAlpha = false;
  int alphaMode = 0;
  bool hasAudio = false;
  double audioGain = 1.0;

  void reset() {
    present = false;
    _path = null;
    startFrame = null;
    endFrame = null;
    sourceInFrame = null;
    sourceOutFrame = null;
    sourceFrameCount = null;
    opacity = 1.0;
    x = 0.0;
    y = 0.0;
    scale = 1.0;
    visible = true;
    isStill = false;
    hasAlpha = false;
    alphaMode = 0;
    hasAudio = false;
    audioGain = 1.0;
  }

  _LayerEditState snapshot() {
    return _LayerEditState(
      present: present,
      path: path,
      startFrame: startFrame,
      endFrame: endFrame,
      sourceInFrame: sourceInFrame,
      sourceOutFrame: sourceOutFrame,
      sourceFrameCount: sourceFrameCount,
      opacity: opacity,
      x: x,
      y: y,
      scale: scale,
      visible: visible,
      isStill: isStill,
      hasAlpha: hasAlpha,
      alphaMode: alphaMode,
      hasAudio: hasAudio,
      audioGain: audioGain,
    );
  }

  void assign(_LayerEditState state) {
    _path = state.path;
    present = state.present;
    startFrame = state.startFrame;
    endFrame = state.endFrame;
    sourceInFrame = state.sourceInFrame;
    sourceOutFrame = state.sourceOutFrame;
    sourceFrameCount = state.sourceFrameCount;
    opacity = state.opacity;
    x = state.x;
    y = state.y;
    scale = state.scale;
    visible = state.visible;
    isStill = state.isStill;
    hasAlpha = state.hasAlpha;
    alphaMode = state.alphaMode;
    hasAudio = state.hasAudio;
    audioGain = state.audioGain;
  }
}

/// Immutable snapshot of the editable clip and composition state.
///
/// The layer model is fixed-slot and index-aligned with native. Source/media
/// metadata that can be re-derived after a rebuild is still captured here so
/// a state round-trip can prove that no layer property silently disappears
/// during Undo/Redo or future model refactors.
class _ClipEditState {
  _ClipEditState({
    required this.trimInFrame,
    required this.trimOutFrame,
    required this.inFrame,
    required this.outFrame,
    required List<_LayerEditState> layers,
    required List<int> visualOrder,
  })  : assert(layers.length == _layerSlotCount),
        assert(visualOrder.length == _layerSlotCount),
        layers = List<_LayerEditState>.unmodifiable(layers),
        visualOrder = List<int>.unmodifiable(visualOrder);

  final int trimInFrame;
  final int trimOutFrame;
  final int? inFrame;
  final int? outFrame;
  final List<_LayerEditState> layers;
  final List<int> visualOrder;

  static bool _near(double a, double b) => _LayerEditState._near(a, b);

  bool sameAs(_ClipEditState other) {
    if (trimInFrame != other.trimInFrame ||
        trimOutFrame != other.trimOutFrame ||
        inFrame != other.inFrame ||
        outFrame != other.outFrame ||
        layers.length != other.layers.length ||
        visualOrder.length != other.visualOrder.length) {
      return false;
    }

    for (var index = 0; index < visualOrder.length; index++) {
      if (visualOrder[index] != other.visualOrder[index]) {
        return false;
      }
    }

    for (var index = 0; index < layers.length; index++) {
      if (!layers[index].sameAs(other.layers[index])) {
        return false;
      }
    }

    return true;
  }
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Owns the native player and the polling loop, and nothing about layout.
class PlayerEngine extends ChangeNotifier {
  PlayerEngine(this.bridge, {required this.initialized})
      : _editStateTestMode = false {
    _volume = initialized ? bridge.volume : 1.0;
    _playAllFrames = initialized ? bridge.playAllFrames : false;
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  @visibleForTesting
  PlayerEngine.forEditStateTesting()
      : initialized = false,
        _editStateTestMode = true;

  static const String _invalidInOutExportIssue =
      'In/Out export requires both an In point and an Out point.';
  static const String _invalidExportRangeIssue =
      'The requested export range is invalid.';

  late final MltBridge bridge;
  final bool initialized;
  final bool _editStateTestMode;

  Timer? _poll;

  MediaInfo? _media;
  String? _error;

  bool _opening = false;
  bool _addingTrack = false;
  final List<_LayerRuntimeState> _layers = List<_LayerRuntimeState>.generate(
    _layerSlotCount,
    (_) => _LayerRuntimeState(),
    growable: false,
  );
  List<int> _visualOrder = <int>[0, 1, 2];

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
  bool _textureFrozen = false;
  int _textureFreezeDepth = 0;

  double _volume = 1.0;
  double _volumeBeforeMute = 1.0;
  bool _muted = false;

  MediaInfo? get media => _media;
  String? get error => _error;
  bool get opening => _opening;
  bool get addingTrack => _addingTrack;
  bool get textureFrozen => _textureFrozen;

  /// Fixed composition slots aligned with the native layer ABI.
  ///
  /// Slot 0 = Layer 1/base, slot 1 = Layer 2, slot 2 = Layer 3.
  /// The returned list always contains all three slots; absent overlays keep
  /// their slot identity with `present == false`.
  List<CompositionLayerState> get layerStates =>
      List<CompositionLayerState>.unmodifiable(
        List<CompositionLayerState>.generate(
          _layerSlotCount,
          layerState,
          growable: false,
        ),
      );

  List<int> get visualOrder => List<int>.unmodifiable(_visualOrder);

  CompositionLayerState layerState(int layerIndex) {
    if (layerIndex < 0 || layerIndex >= _layerSlotCount) {
      throw RangeError.range(
        layerIndex,
        0,
        _layerSlotCount - 1,
        'layerIndex',
      );
    }

    final layer = _layers[layerIndex];
    return CompositionLayerState(
      index: layerIndex,
      present: layer.present,
      path: layer.path,
      startFrame: layer.startFrame,
      endFrame: layer.endFrame,
      sourceInFrame: layer.sourceInFrame,
      sourceOutFrame: layer.sourceOutFrame,
      sourceFrameCount: layer.sourceFrameCount,
      opacity: layer.opacity,
      x: layer.x,
      y: layer.y,
      scale: layer.scale,
      visible: layer.visible,
      isStill: layer.isStill,
      hasAlpha: layer.hasAlpha,
      alphaMode: layer.alphaMode,
      hasAudio: layer.hasAudio,
      audioGain: layer.audioGain,
      visualPosition: _visualOrder.indexOf(layerIndex),
    );
  }

  bool hasLayer(int layerIndex) =>
      layerIndex >= 0 &&
      layerIndex < _layerSlotCount &&
      _layers[layerIndex].present;

  int get trackCount =>
      _layers.where((_LayerRuntimeState layer) => layer.present).length;

  int? get topOverlayLayerIndex {
    // Overlay removal still follows the native contiguous-slot topology:
    // Layer 3 must be removed before Layer 2. Visual Z-order is independent
    // from that ownership rule, so do not make a visually higher Layer 2 look
    // removable while Layer 3 still exists.
    if (hasLayer(_tertiaryLayerIndex)) {
      return _tertiaryLayerIndex;
    }
    if (hasLayer(_secondaryLayerIndex)) {
      return _secondaryLayerIndex;
    }
    return null;
  }
  bool get exportsAvailable =>
      _media != null && !_media!.isStill && _media!.frames > 0;
  bool get exportHasAudio => _layers.any(
        (_LayerRuntimeState layer) => layer.present && layer.hasAudio,
      );

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
      layers: _layers
          .map((_LayerRuntimeState layer) => layer.snapshot())
          .toList(growable: false),
      visualOrder: _visualOrder,
    );
  }

  void _assignEditStateFields(_ClipEditState state) {
    _trimInFrame = state.trimInFrame;
    _trimOutFrame = state.trimOutFrame;
    _inFrame = state.inFrame;
    _outFrame = state.outFrame;
    _visualOrder = List<int>.from(state.visualOrder);

    if (_editStateTestMode) {
      for (var index = 0; index < _layerSlotCount; index++) {
        _layers[index].assign(state.layers[index]);
      }
      return;
    }

    // Base source identity and media metadata belong to the currently-open
    // MediaInfo/native producer, not to clip edit history. Only its
    // composition-owned audio gain is restored from slot 0. Overlay slots are
    // fully edit-owned and can be assigned from history.
    _layers[_baseLayerIndex].audioGain =
        state.layers[_baseLayerIndex].audioGain;
    for (var index = _secondaryLayerIndex; index < _layerSlotCount; index++) {
      _layers[index].assign(state.layers[index]);
    }
  }

  void _resetLayerStates() {
    for (final layer in _layers) {
      layer.reset();
    }
    _visualOrder = <int>[0, 1, 2];
  }

  void _syncBaseLayerFromMedia(String path) {
    final media = _media;
    if (media == null) {
      _layers[_baseLayerIndex].reset();
      return;
    }

    final base = _layers[_baseLayerIndex];
    base.path = path;
    base.startFrame = 0;
    base.endFrame = media.frames > 0 ? media.frames - 1 : null;
    base.sourceInFrame = media.frames > 0 ? 0 : null;
    base.sourceOutFrame = media.frames > 0 ? media.frames - 1 : null;
    base.sourceFrameCount = media.frames > 0 ? media.frames : null;
    base.opacity = 1.0;
    base.x = 0.0;
    base.y = 0.0;
    base.scale = 1.0;
    base.visible = true;
    base.isStill = media.isStill;
    base.hasAlpha = false;
    base.alphaMode = 0;
    base.hasAudio = media.hasAudio;
    base.audioGain =
        bridge.trackAudioGain(_baseLayerIndex).clamp(0.0, 1.0).toDouble();
  }

  void _syncLayerTimingFromNative(int layerIndex) {
    if (layerIndex <= _baseLayerIndex ||
        layerIndex >= _layerSlotCount ||
        !hasLayer(layerIndex)) {
      return;
    }

    final nativeStart = bridge.layerStartFrame(layerIndex);
    final nativeEnd = bridge.layerEndFrame(layerIndex);
    if (nativeStart >= 0) {
      _layers[layerIndex].startFrame = nativeStart;
    }
    if (nativeEnd >= 0) {
      _layers[layerIndex].endFrame = nativeEnd;
    }
  }

  void _syncLayerSourceRangeFromNative(int layerIndex) {
    if (layerIndex <= _baseLayerIndex ||
        layerIndex >= _layerSlotCount ||
        !hasLayer(layerIndex)) {
      return;
    }

    final layer = _layers[layerIndex];
    if (layer.isStill) {
      layer.sourceInFrame = null;
      layer.sourceOutFrame = null;
      layer.sourceFrameCount = null;
      return;
    }

    final nativeIn = bridge.layerSourceInFrame(layerIndex);
    final nativeOut = bridge.layerSourceOutFrame(layerIndex);
    final nativeLength = bridge.layerSourceLengthFrames(layerIndex);
    layer.sourceInFrame = nativeIn >= 0 ? nativeIn : null;
    layer.sourceOutFrame = nativeOut >= 0 ? nativeOut : null;
    layer.sourceFrameCount = nativeLength > 0 ? nativeLength : null;
  }

  @visibleForTesting
  static Object editStateForTesting({
    required int trimInFrame,
    required int trimOutFrame,
    required int? inFrame,
    required int? outFrame,
    required List<CompositionLayerState> layers,
    List<int> visualOrder = const <int>[0, 1, 2],
  }) {
    if (layers.length != _layerSlotCount) {
      throw ArgumentError.value(
        layers.length,
        'layers.length',
        'Edit-state tests require exactly $_layerSlotCount indexed slots.',
      );
    }

    for (var index = 0; index < _layerSlotCount; index++) {
      if (layers[index].index != index) {
        throw ArgumentError(
          'Layer slot $index contains state for index ${layers[index].index}.',
        );
      }
    }

    if (visualOrder.length != _layerSlotCount ||
        visualOrder.toSet().length != _layerSlotCount ||
        visualOrder.any(
          (int layerIndex) =>
              layerIndex < 0 || layerIndex >= _layerSlotCount,
        )) {
      throw ArgumentError.value(
        visualOrder,
        'visualOrder',
        'Visual order must be a permutation of 0, 1, and 2.',
      );
    }

    return _ClipEditState(
      trimInFrame: trimInFrame,
      trimOutFrame: trimOutFrame,
      inFrame: inFrame,
      outFrame: outFrame,
      layers: layers
          .map(
            (CompositionLayerState layer) => _LayerEditState(
              present: layer.present,
              path: layer.path,
              startFrame: layer.startFrame,
              endFrame: layer.endFrame,
              sourceInFrame: layer.sourceInFrame,
              sourceOutFrame: layer.sourceOutFrame,
              sourceFrameCount: layer.sourceFrameCount,
              opacity: layer.opacity,
              x: layer.x,
              y: layer.y,
              scale: layer.scale,
              visible: layer.visible,
              isStill: layer.isStill,
              hasAlpha: layer.hasAlpha,
              alphaMode: layer.alphaMode,
              hasAudio: layer.hasAudio,
              audioGain: layer.audioGain,
            ),
          )
          .toList(growable: false),
      visualOrder: visualOrder,
    );
  }

  @visibleForTesting
  static Map<String, Object?> editStateValuesForTesting(Object value) {
    final state = value as _ClipEditState;
    return <String, Object?>{
      'trimInFrame': state.trimInFrame,
      'trimOutFrame': state.trimOutFrame,
      'inFrame': state.inFrame,
      'outFrame': state.outFrame,
      'visualOrder': List<int>.from(state.visualOrder),
      'layers': state.layers
          .map(
            (_LayerEditState layer) => <String, Object?>{
              'present': layer.present,
              'path': layer.path,
              'startFrame': layer.startFrame,
              'endFrame': layer.endFrame,
              'sourceInFrame': layer.sourceInFrame,
              'sourceOutFrame': layer.sourceOutFrame,
              'sourceFrameCount': layer.sourceFrameCount,
              'opacity': layer.opacity,
              'x': layer.x,
              'y': layer.y,
              'scale': layer.scale,
              'visible': layer.visible,
              'isStill': layer.isStill,
              'hasAlpha': layer.hasAlpha,
              'alphaMode': layer.alphaMode,
              'hasAudio': layer.hasAudio,
              'audioGain': layer.audioGain,
            },
          )
          .toList(growable: false),
    };
  }

  @visibleForTesting
  Object captureEditStateForTesting() => _captureEditState();

  @visibleForTesting
  Future<void> applyEditStateForTesting(Object value) async {
    if (!_editStateTestMode) {
      throw StateError('applyEditStateForTesting requires the test constructor.');
    }

    final restored = await _applyEditState(
      value as _ClipEditState,
      basePath: '',
      playheadFrame: 0,
    );

    if (!restored) {
      throw StateError(_error ?? 'Test edit state could not be restored.');
    }
  }

  @visibleForTesting
  void recordCurrentEditStateForTesting() {
    if (!_editStateTestMode) {
      throw StateError(
        'recordCurrentEditStateForTesting requires the test constructor.',
      );
    }

    _recordEditBeforeChange(_captureEditState());
  }

  @visibleForTesting
  Future<void> undoEditStateForTesting() =>
      _moveEditHistory(undoing: true);

  @visibleForTesting
  Future<void> redoEditStateForTesting() =>
      _moveEditHistory(undoing: false);

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
    final firstFlutterFreeze = _textureFreezeDepth == 0;
    _textureFreezeDepth += 1;

    if (firstFlutterFreeze) {
      // Freeze the Texture widget itself before native graph mutation begins.
      // This is stronger than merely withholding MLT frames: Flutter keeps
      // presenting the exact last composited texture while media dimensions,
      // layer roles, and inspector state are rebuilt behind it.
      _textureFrozen = true;
      super.notifyListeners();

      // Make sure one Flutter frame has actually observed freeze=true before
      // we touch the native graph. Otherwise a fast rebuild can outrun the
      // widget update and still expose a one-frame cross-aspect intermediate.
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }

    _holdNotifications();

    final began = bridge.beginPreviewUpdate();
    final frameSerialBefore =
        began ? bridge.previewFrameSerial : 0;
    var ended = true;

    try {
      final result = await operation();

      if (began) {
        ended = bridge.endPreviewUpdate();
      }

      if (!ended) {
        if (result) {
          _error = bridge.lastError.isEmpty
              ? 'MLT could not publish the rebuilt composition frame.'
              : bridge.lastError;
        }
        return false;
      }

      // While Flutter's Texture remains frozen, wait only for the fully
      // configured replacement frame to reach the native ready slot. On the
      // final Dart notification we change layout/aspect and unfreeze Texture
      // together, so Flutter's first allowed populate in the new layout pulls
      // this final frame rather than an intermediate one.
      if (began &&
          !await _waitForPreviewFrameReady(frameSerialBefore)) {
        _error =
            'The rebuilt preview frame did not reach the native ready slot.';
        return false;
      }

      return result;
    } catch (_) {
      if (began) {
        bridge.endPreviewUpdate();
      }
      rethrow;
    } finally {
      _textureFreezeDepth -= 1;
      if (_textureFreezeDepth == 0) {
        _textureFrozen = false;
        // A notification is already being held for successful rebuilds, but
        // guarantee that Texture(freeze:false) and the final media/layout state
        // are published in the same Flutter rebuild even on no-op/failure paths.
        _notificationPending = true;
      }
      _releaseNotifications();
    }
  }

  Future<bool> _waitForPreviewFrameReady(int previousSerial) async {
    const pollInterval = Duration(milliseconds: 4);
    const maxPolls = 750;

    for (var attempt = 0; attempt < maxPolls; attempt++) {
      if (bridge.previewFrameSerial != previousSerial) {
        return true;
      }
      await Future<void>.delayed(pollInterval);
    }

    return false;
  }

  Future<bool> _waitForPreviewPrewarm(int previousSerial) async {
    const pollInterval = Duration(milliseconds: 4);
    const maxPolls = 750;

    for (var attempt = 0; attempt < maxPolls; attempt++) {
      if (bridge.previewPrewarmSerial != previousSerial) {
        return true;
      }
      await Future<void>.delayed(pollInterval);
    }

    return false;
  }

  bool _isVisualOrderPermutation(List<int> order) {
    if (order.length != _layerSlotCount) {
      return false;
    }
    final seen = <int>{};
    for (final layerIndex in order) {
      if (layerIndex < 0 ||
          layerIndex >= _layerSlotCount ||
          !seen.add(layerIndex)) {
        return false;
      }
    }
    return true;
  }

  bool _setVisualOrderNative(List<int> order) {
    if (!_isVisualOrderPermutation(order)) {
      _error = 'The requested visual layer order is invalid.';
      return false;
    }
    if (_editStateTestMode) {
      _visualOrder = List<int>.from(order);
      return true;
    }

    final began = bridge.beginPreviewUpdate();
    final applied = bridge.setLayerVisualOrder(order[0], order[1], order[2]);
    final ended = !began || bridge.endPreviewUpdate();

    if (!applied) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not apply the visual layer order.'
          : bridge.lastError;
      return false;
    }
    if (!ended) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not publish the reordered composition frame.'
          : bridge.lastError;
      return false;
    }

    _visualOrder = List<int>.from(order);
    return true;
  }

  bool _canRestoreOnlyTertiary(_ClipEditState state) {
    return _layers[_tertiaryLayerIndex].path == null &&
        state.layers[_tertiaryLayerIndex].path != null &&
        hasLayer(_secondaryLayerIndex) &&
        state.layers[_secondaryLayerIndex].path == _layers[_secondaryLayerIndex].path &&
        state.layers[_secondaryLayerIndex].startFrame == _layers[_secondaryLayerIndex].startFrame &&
        state.layers[_secondaryLayerIndex].endFrame == _layers[_secondaryLayerIndex].endFrame &&
        state.layers[_secondaryLayerIndex].sourceInFrame ==
            _layers[_secondaryLayerIndex].sourceInFrame &&
        state.layers[_secondaryLayerIndex].sourceOutFrame ==
            _layers[_secondaryLayerIndex].sourceOutFrame &&
        _ClipEditState._near(
          state.layers[_baseLayerIndex].audioGain,
          _layers[_baseLayerIndex].audioGain,
        ) &&
        _ClipEditState._near(
          state.layers[_secondaryLayerIndex].audioGain,
          _layers[_secondaryLayerIndex].audioGain,
        ) &&
        _ClipEditState._near(
          state.layers[_secondaryLayerIndex].opacity,
          _layers[_secondaryLayerIndex].opacity,
        ) &&
        _ClipEditState._near(state.layers[_secondaryLayerIndex].x, _layers[_secondaryLayerIndex].x) &&
        _ClipEditState._near(state.layers[_secondaryLayerIndex].y, _layers[_secondaryLayerIndex].y) &&
        _ClipEditState._near(
          state.layers[_secondaryLayerIndex].scale,
          _layers[_secondaryLayerIndex].scale,
        ) &&
        state.layers[_secondaryLayerIndex].visible == _layers[_secondaryLayerIndex].visible &&
        state.layers[_secondaryLayerIndex].alphaMode == _layers[_secondaryLayerIndex].alphaMode;
  }

  Future<bool> _restoreOnlyTertiary(_ClipEditState state) async {
    final path = state.layers[_tertiaryLayerIndex].path;
    if (path == null) {
      return false;
    }

    final effectiveOpacity =
        state.layers[_tertiaryLayerIndex].visible ? state.layers[_tertiaryLayerIndex].opacity : 0.0;

    bool added;
    try {
      added = await addLayerWithStateOnHelperIsolate(
        bridge.engineAddress,
        2,
        path,
        startFrame: state.layers[_tertiaryLayerIndex].startFrame ?? 0,
        endFrame: state.layers[_tertiaryLayerIndex].endFrame ?? -1,
        sourceInFrame: state.layers[_tertiaryLayerIndex].sourceInFrame,
        sourceOutFrame: state.layers[_tertiaryLayerIndex].sourceOutFrame,
        x: state.layers[_tertiaryLayerIndex].x,
        y: state.layers[_tertiaryLayerIndex].y,
        scale: state.layers[_tertiaryLayerIndex].scale,
        opacity: effectiveOpacity,
        alphaMode: state.layers[_tertiaryLayerIndex].alphaMode,
        audioGain: state.layers[_tertiaryLayerIndex].audioGain,
      );
    } catch (error) {
      _error = error.toString();
      return false;
    }

    if (!added) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not restore Layer 3.'
          : bridge.lastError;
      return false;
    }

    _layers[_tertiaryLayerIndex].path = path;
    final nativeStart = bridge.layerStartFrame(2);
    _layers[_tertiaryLayerIndex].startFrame =
        nativeStart >= 0 ? nativeStart : state.layers[_tertiaryLayerIndex].startFrame;
    final nativeEnd = bridge.layerEndFrame(2);
    _layers[_tertiaryLayerIndex].endFrame =
        nativeEnd >= 0 ? nativeEnd : state.layers[_tertiaryLayerIndex].endFrame;
    _syncLayerSourceRangeFromNative(_tertiaryLayerIndex);
    _layers[_tertiaryLayerIndex].opacity = state.layers[_tertiaryLayerIndex].opacity;
    _layers[_tertiaryLayerIndex].visible = state.layers[_tertiaryLayerIndex].visible;
    _layers[_tertiaryLayerIndex].x = bridge.layerX(2);
    _layers[_tertiaryLayerIndex].y = bridge.layerY(2);
    _layers[_tertiaryLayerIndex].scale = bridge.layerScale(2).clamp(0.10, 3.0).toDouble();
    _layers[_tertiaryLayerIndex].isStill = bridge.layerIsStill(2);
    _layers[_tertiaryLayerIndex].hasAlpha = bridge.layerHasAlpha(2);
    _layers[_tertiaryLayerIndex].alphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();
    _layers[_tertiaryLayerIndex].hasAudio = bridge.trackHasAudio(2);
    _layers[_tertiaryLayerIndex].audioGain = _layers[_tertiaryLayerIndex].hasAudio
        ? bridge.trackAudioGain(2).clamp(0.0, 1.0).toDouble()
        : state.layers[_tertiaryLayerIndex].audioGain;

    if (!_setVisualOrderNative(state.visualOrder)) {
      return false;
    }

    _restoreClipFields(state);
    _error = null;
    return true;
  }

  Future<bool> _applyEditState(
    _ClipEditState state, {
    required String basePath,
    required int playheadFrame,
  }) async {
    if (_editStateTestMode) {
      _assignEditStateFields(state);
      _error = null;
      return true;
    }

    final topologyChanged =
        state.layers[_secondaryLayerIndex].path != _layers[_secondaryLayerIndex].path ||
        state.layers[_tertiaryLayerIndex].path != _layers[_tertiaryLayerIndex].path ||
        (state.layers[_secondaryLayerIndex].path != null &&
            (state.layers[_secondaryLayerIndex].startFrame != _layers[_secondaryLayerIndex].startFrame ||
             state.layers[_secondaryLayerIndex].endFrame != _layers[_secondaryLayerIndex].endFrame ||
             state.layers[_secondaryLayerIndex].sourceInFrame !=
                 _layers[_secondaryLayerIndex].sourceInFrame ||
             state.layers[_secondaryLayerIndex].sourceOutFrame !=
                 _layers[_secondaryLayerIndex].sourceOutFrame)) ||
        (state.layers[_tertiaryLayerIndex].path != null &&
            (state.layers[_tertiaryLayerIndex].startFrame != _layers[_tertiaryLayerIndex].startFrame ||
             state.layers[_tertiaryLayerIndex].endFrame != _layers[_tertiaryLayerIndex].endFrame ||
             state.layers[_tertiaryLayerIndex].sourceInFrame !=
                 _layers[_tertiaryLayerIndex].sourceInFrame ||
             state.layers[_tertiaryLayerIndex].sourceOutFrame !=
                 _layers[_tertiaryLayerIndex].sourceOutFrame));

    if (topologyChanged && _canRestoreOnlyTertiary(state)) {
      final restored = await _runWithFrozenPreview(
        () => _restoreOnlyTertiary(state),
      );
      if (restored) {
        _assignEditStateFields(state);
        _syncLayerTimingFromNative(_secondaryLayerIndex);
        _syncLayerTimingFromNative(_tertiaryLayerIndex);
        _syncLayerSourceRangeFromNative(_secondaryLayerIndex);
        _syncLayerSourceRangeFromNative(_tertiaryLayerIndex);
      }
      return restored;
    }

    if (topologyChanged) {
      final restored = await _runWithFrozenPreview(
        () => _rebuildLayerStack(
          primaryPath: basePath,
          secondaryPath: state.layers[_secondaryLayerIndex].path,
          secondaryStartFrame: state.layers[_secondaryLayerIndex].startFrame,
          secondaryEndFrame: state.layers[_secondaryLayerIndex].endFrame,
          secondarySourceInFrame: state.layers[_secondaryLayerIndex].sourceInFrame,
          secondarySourceOutFrame: state.layers[_secondaryLayerIndex].sourceOutFrame,
          tertiaryPath: state.layers[_tertiaryLayerIndex].path,
          tertiaryStartFrame: state.layers[_tertiaryLayerIndex].startFrame,
          tertiaryEndFrame: state.layers[_tertiaryLayerIndex].endFrame,
          tertiarySourceInFrame: state.layers[_tertiaryLayerIndex].sourceInFrame,
          tertiarySourceOutFrame: state.layers[_tertiaryLayerIndex].sourceOutFrame,
          playheadFrame: playheadFrame,
          primaryGain: state.layers[_baseLayerIndex].audioGain,
          secondaryGain: state.layers[_secondaryLayerIndex].audioGain,
          tertiaryGain: state.layers[_tertiaryLayerIndex].audioGain,
          secondaryOpacity: state.layers[_secondaryLayerIndex].opacity,
          secondaryX: state.layers[_secondaryLayerIndex].x,
          secondaryY: state.layers[_secondaryLayerIndex].y,
          secondaryScale: state.layers[_secondaryLayerIndex].scale,
          secondaryVisible: state.layers[_secondaryLayerIndex].visible,
          secondaryAlphaMode: state.layers[_secondaryLayerIndex].alphaMode,
          tertiaryOpacity: state.layers[_tertiaryLayerIndex].opacity,
          tertiaryX: state.layers[_tertiaryLayerIndex].x,
          tertiaryY: state.layers[_tertiaryLayerIndex].y,
          tertiaryScale: state.layers[_tertiaryLayerIndex].scale,
          tertiaryVisible: state.layers[_tertiaryLayerIndex].visible,
          tertiaryAlphaMode: state.layers[_tertiaryLayerIndex].alphaMode,
          editState: state,
          undoState: const <_ClipEditState>[],
          redoState: const <_ClipEditState>[],
          visualOrder: state.visualOrder,
        ),
      );
      if (restored) {
        _assignEditStateFields(state);
        _syncLayerTimingFromNative(_secondaryLayerIndex);
        _syncLayerTimingFromNative(_tertiaryLayerIndex);
        _syncLayerSourceRangeFromNative(_secondaryLayerIndex);
        _syncLayerSourceRangeFromNative(_tertiaryLayerIndex);
      }
      return restored;
    }

    _restoreClipFields(state);

    if (trackHasAudio(0)) {
      if (!bridge.setTrackAudioGain(0, state.layers[_baseLayerIndex].audioGain)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 1 audio level.'
            : bridge.lastError;
        return false;
      }
      _syncTrackAudioGain(0);
    }

    if (state.layers[_secondaryLayerIndex].path != null && hasLayer(_secondaryLayerIndex)) {
      if (!bridge.setSecondaryGeometry(
        state.layers[_secondaryLayerIndex].x,
        state.layers[_secondaryLayerIndex].y,
        state.layers[_secondaryLayerIndex].scale,
      )) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 2 geometry.'
            : bridge.lastError;
        return false;
      }
      _syncSecondaryGeometry();

      final effectiveOpacity = state.layers[_secondaryLayerIndex].visible
          ? state.layers[_secondaryLayerIndex].opacity
          : 0.0;
      if (!bridge.setSecondaryOpacity(effectiveOpacity)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 2 opacity.'
            : bridge.lastError;
        return false;
      }
      _layers[_secondaryLayerIndex].opacity = state.layers[_secondaryLayerIndex].opacity;
      _layers[_secondaryLayerIndex].visible = state.layers[_secondaryLayerIndex].visible;

      if (!bridge.setSecondaryAlphaMode(state.layers[_secondaryLayerIndex].alphaMode)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 2 alpha interpretation.'
            : bridge.lastError;
        return false;
      }
      _layers[_secondaryLayerIndex].alphaMode =
          bridge.secondaryAlphaMode.clamp(0, 2).toInt();

      if (trackHasAudio(1)) {
        if (!bridge.setTrackAudioGain(1, state.layers[_secondaryLayerIndex].audioGain)) {
          _error = bridge.lastError.isEmpty
              ? 'MLT could not restore Layer 2 audio level.'
              : bridge.lastError;
          return false;
        }
        _syncTrackAudioGain(1);
      }
    }

    if (state.layers[_tertiaryLayerIndex].path != null && hasLayer(_tertiaryLayerIndex)) {
      if (!bridge.setLayerGeometry(
        2,
        state.layers[_tertiaryLayerIndex].x,
        state.layers[_tertiaryLayerIndex].y,
        state.layers[_tertiaryLayerIndex].scale,
      )) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 3 geometry.'
            : bridge.lastError;
        return false;
      }
      _syncTertiaryGeometry();

      final effectiveOpacity = state.layers[_tertiaryLayerIndex].visible
          ? state.layers[_tertiaryLayerIndex].opacity
          : 0.0;
      if (!bridge.setLayerOpacity(2, effectiveOpacity)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 3 opacity.'
            : bridge.lastError;
        return false;
      }
      _layers[_tertiaryLayerIndex].opacity = state.layers[_tertiaryLayerIndex].opacity;
      _layers[_tertiaryLayerIndex].visible = state.layers[_tertiaryLayerIndex].visible;

      if (!bridge.setLayerAlphaMode(2, state.layers[_tertiaryLayerIndex].alphaMode)) {
        _error = bridge.lastError.isEmpty
            ? 'MLT could not restore Layer 3 alpha interpretation.'
            : bridge.lastError;
        return false;
      }
      _layers[_tertiaryLayerIndex].alphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();

      if (trackHasAudio(2)) {
        if (!bridge.setTrackAudioGain(2, state.layers[_tertiaryLayerIndex].audioGain)) {
          _error = bridge.lastError.isEmpty
              ? 'MLT could not restore Layer 3 audio level.'
              : bridge.lastError;
          return false;
        }
        _syncTrackAudioGain(2);
      }
    }

    if (!listEquals(state.visualOrder, _visualOrder) &&
        trackCount > 1 &&
        !_setVisualOrderNative(state.visualOrder)) {
      return false;
    }

    _assignEditStateFields(state);
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
    if (_restoringEditState ||
        (!_editStateTestMode && _media == null)) {
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

    final basePath = _editStateTestMode ? '' : _media!.path;
    final playheadFrame =
        _editStateTestMode ? 0 : bridge.positionFrame;

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
    _resetLayerStates();
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

    _syncBaseLayerFromMedia(path);

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

  Future<bool> _addTrackAtFrame(
    String path,
    int startFrame, {
    int? endFrame,
    int? sourceInFrame,
    int? sourceOutFrame,
  }) async {
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

    final targetLayerIndex = hasLayer(_secondaryLayerIndex) ? 2 : 1;

    var clampedStart = startFrame;
    if (clampedStart < 0) {
      clampedStart = 0;
    }
    if (media.frames > 0 && clampedStart >= media.frames) {
      clampedStart = media.frames - 1;
    }

    int? clampedEnd = endFrame;
    if (clampedEnd != null && media.frames > 0) {
      clampedEnd = clampedEnd.clamp(clampedStart, media.frames - 1).toInt();
    }

    _addingTrack = true;
    _error = null;
    notifyListeners();

    bool added;
    try {
      if (sourceInFrame != null && sourceOutFrame != null) {
        final requestedEnd = clampedEnd ?? (media.frames - 1);
        added = await addTrackBoundedSourceOnHelperIsolate(
          bridge.engineAddress,
          path,
          startFrame: clampedStart,
          endFrame: requestedEnd,
          sourceInFrame: sourceInFrame,
          sourceOutFrame: sourceOutFrame,
        );
      } else {
        added = clampedEnd == null
            ? await addTrackOnHelperIsolate(
                path,
                clampedStart,
                bridge.engineAddress,
              )
            : await addTrackBoundedOnHelperIsolate(
                bridge.engineAddress,
                path,
                startFrame: clampedStart,
                endFrame: clampedEnd,
              );
      }
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
      _layers[_secondaryLayerIndex].path = path;
      final nativeStartFrame = bridge.layerStartFrame(1);
      _layers[_secondaryLayerIndex].startFrame =
          nativeStartFrame >= 0 ? nativeStartFrame : clampedStart;
      final nativeEndFrame = bridge.layerEndFrame(1);
      _layers[_secondaryLayerIndex].endFrame =
          nativeEndFrame >= 0 ? nativeEndFrame : clampedEnd;
      _layers[_secondaryLayerIndex].opacity =
          bridge.layerOpacity(1).clamp(0.0, 1.0).toDouble();
      _layers[_secondaryLayerIndex].x = bridge.layerX(1);
      _layers[_secondaryLayerIndex].y = bridge.layerY(1);
      _layers[_secondaryLayerIndex].scale = bridge.layerScale(1).clamp(0.10, 3.0).toDouble();
      _layers[_secondaryLayerIndex].visible = true;
      _layers[_secondaryLayerIndex].isStill = bridge.layerIsStill(1);
      _layers[_secondaryLayerIndex].hasAlpha = bridge.layerHasAlpha(1);
      _layers[_secondaryLayerIndex].alphaMode = bridge.layerAlphaMode(1).clamp(0, 2).toInt();
      _layers[_secondaryLayerIndex].hasAudio = bridge.trackHasAudio(1);
      _layers[_secondaryLayerIndex].audioGain =
          bridge.trackAudioGain(1).clamp(0.0, 1.0).toDouble();
    } else {
      _layers[_tertiaryLayerIndex].path = path;
      final nativeStartFrame = bridge.layerStartFrame(2);
      _layers[_tertiaryLayerIndex].startFrame =
          nativeStartFrame >= 0 ? nativeStartFrame : clampedStart;
      final nativeEndFrame = bridge.layerEndFrame(2);
      _layers[_tertiaryLayerIndex].endFrame =
          nativeEndFrame >= 0 ? nativeEndFrame : clampedEnd;
      _layers[_tertiaryLayerIndex].opacity =
          bridge.layerOpacity(2).clamp(0.0, 1.0).toDouble();
      _layers[_tertiaryLayerIndex].x = bridge.layerX(2);
      _layers[_tertiaryLayerIndex].y = bridge.layerY(2);
      _layers[_tertiaryLayerIndex].scale = bridge.layerScale(2).clamp(0.10, 3.0).toDouble();
      _layers[_tertiaryLayerIndex].visible = true;
      _layers[_tertiaryLayerIndex].isStill = bridge.layerIsStill(2);
      _layers[_tertiaryLayerIndex].hasAlpha = bridge.layerHasAlpha(2);
      _layers[_tertiaryLayerIndex].alphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();
      _layers[_tertiaryLayerIndex].hasAudio = bridge.trackHasAudio(2);
      _layers[_tertiaryLayerIndex].audioGain =
          bridge.trackAudioGain(2).clamp(0.0, 1.0).toDouble();
    }

    _syncLayerSourceRangeFromNative(targetLayerIndex);

    final desiredVisualOrder = List<int>.from(_visualOrder)
      ..remove(targetLayerIndex)
      ..add(targetLayerIndex);
    if (!_setVisualOrderNative(desiredVisualOrder)) {
      _error ??= 'MLT added the layer but could not preserve visual order.';
      notifyListeners();
      return false;
    }

    _layers[_baseLayerIndex].audioGain =
        bridge.trackAudioGain(0).clamp(0.0, 1.0).toDouble();
    if (hasLayer(_secondaryLayerIndex)) {
      _layers[_secondaryLayerIndex].hasAudio = bridge.trackHasAudio(1);
      _layers[_secondaryLayerIndex].audioGain =
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
  Future<bool> removeLayer(int layerIndex) async {
    if (layerIndex == _secondaryLayerIndex) {
      return _removeSecondaryLayer();
    }
    if (layerIndex == _tertiaryLayerIndex) {
      return _removeTertiaryLayer();
    }
    return false;
  }

  Future<bool> replaceLayerSource(int layerIndex, String path) async {
    switch (layerIndex) {
      case _baseLayerIndex:
        return _replacePrimaryLayerSource(path);
      case _secondaryLayerIndex:
        return _replaceSecondaryLayerSource(path);
      case _tertiaryLayerIndex:
        return _replaceTertiaryLayerSource(path);
      default:
        return false;
    }
  }

  Future<bool> _removeSecondaryLayer() async {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        !hasLayer(_secondaryLayerIndex) ||
        hasLayer(_tertiaryLayerIndex) ||
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
      primaryGain: before.layers[_baseLayerIndex].audioGain,
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
  Future<bool> _removeTertiaryLayer() async {
    final media = _media;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        !hasLayer(_secondaryLayerIndex) ||
        !hasLayer(_tertiaryLayerIndex) ||
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
        secondaryPath: before.layers[_secondaryLayerIndex].path,
        secondaryStartFrame: before.layers[_secondaryLayerIndex].startFrame,
        secondaryEndFrame: before.layers[_secondaryLayerIndex].endFrame,
        tertiaryPath: null,
        tertiaryStartFrame: null,
        playheadFrame: playheadFrame,
        primaryGain: before.layers[_baseLayerIndex].audioGain,
        secondaryGain: before.layers[_secondaryLayerIndex].audioGain,
        tertiaryGain: 1.0,
        secondaryOpacity: before.layers[_secondaryLayerIndex].opacity,
        secondaryX: before.layers[_secondaryLayerIndex].x,
        secondaryY: before.layers[_secondaryLayerIndex].y,
        secondaryScale: before.layers[_secondaryLayerIndex].scale,
        secondaryVisible: before.layers[_secondaryLayerIndex].visible,
        secondaryAlphaMode: before.layers[_secondaryLayerIndex].alphaMode,
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
  Future<bool> _replaceSecondaryLayerSource(String path) async {
    final media = _media;
    final oldSecondaryPath = _layers[_secondaryLayerIndex].path;

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
        secondaryStartFrame: editState.layers[_secondaryLayerIndex].startFrame,
        secondaryEndFrame: editState.layers[_secondaryLayerIndex].endFrame,
        tertiaryPath: editState.layers[_tertiaryLayerIndex].path,
        tertiaryStartFrame: editState.layers[_tertiaryLayerIndex].startFrame,
        tertiaryEndFrame: editState.layers[_tertiaryLayerIndex].endFrame,
        playheadFrame: currentFrame,
        primaryGain: editState.layers[_baseLayerIndex].audioGain,
        secondaryGain: editState.layers[_secondaryLayerIndex].audioGain,
        tertiaryGain: editState.layers[_tertiaryLayerIndex].audioGain,
        secondaryOpacity: editState.layers[_secondaryLayerIndex].opacity,
        secondaryX: editState.layers[_secondaryLayerIndex].x,
        secondaryY: editState.layers[_secondaryLayerIndex].y,
        secondaryScale: editState.layers[_secondaryLayerIndex].scale,
        secondaryVisible: editState.layers[_secondaryLayerIndex].visible,
        secondaryAlphaMode: secondaryAlphaMode,
        tertiaryOpacity: editState.layers[_tertiaryLayerIndex].opacity,
        tertiaryX: editState.layers[_tertiaryLayerIndex].x,
        tertiaryY: editState.layers[_tertiaryLayerIndex].y,
        tertiaryScale: editState.layers[_tertiaryLayerIndex].scale,
        tertiaryVisible: editState.layers[_tertiaryLayerIndex].visible,
        tertiaryAlphaMode: editState.layers[_tertiaryLayerIndex].alphaMode,
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
      editState.layers[_secondaryLayerIndex].alphaMode,
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
  Future<bool> _replaceTertiaryLayerSource(String path) async {
    final media = _media;
    final oldTertiaryPath = _layers[_tertiaryLayerIndex].path;

    if (!initialized ||
        media == null ||
        media.isStill ||
        !media.hasVideo ||
        oldTertiaryPath == null ||
        !hasLayer(_secondaryLayerIndex) ||
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
        secondaryPath: editState.layers[_secondaryLayerIndex].path,
        secondaryStartFrame: editState.layers[_secondaryLayerIndex].startFrame,
        secondaryEndFrame: editState.layers[_secondaryLayerIndex].endFrame,
        tertiaryPath: tertiaryPath,
        tertiaryStartFrame: editState.layers[_tertiaryLayerIndex].startFrame,
        tertiaryEndFrame: editState.layers[_tertiaryLayerIndex].endFrame,
        playheadFrame: currentFrame,
        primaryGain: editState.layers[_baseLayerIndex].audioGain,
        secondaryGain: editState.layers[_secondaryLayerIndex].audioGain,
        tertiaryGain: editState.layers[_tertiaryLayerIndex].audioGain,
        secondaryOpacity: editState.layers[_secondaryLayerIndex].opacity,
        secondaryX: editState.layers[_secondaryLayerIndex].x,
        secondaryY: editState.layers[_secondaryLayerIndex].y,
        secondaryScale: editState.layers[_secondaryLayerIndex].scale,
        secondaryVisible: editState.layers[_secondaryLayerIndex].visible,
        secondaryAlphaMode: editState.layers[_secondaryLayerIndex].alphaMode,
        tertiaryOpacity: editState.layers[_tertiaryLayerIndex].opacity,
        tertiaryX: editState.layers[_tertiaryLayerIndex].x,
        tertiaryY: editState.layers[_tertiaryLayerIndex].y,
        tertiaryScale: editState.layers[_tertiaryLayerIndex].scale,
        tertiaryVisible: editState.layers[_tertiaryLayerIndex].visible,
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
      editState.layers[_tertiaryLayerIndex].alphaMode,
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
  Future<bool> _replacePrimaryLayerSource(String path) async {
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
    final secondaryStartSeconds = oldEditState.layers[_secondaryLayerIndex].path != null &&
            oldEditState.layers[_secondaryLayerIndex].startFrame != null &&
            oldMedia.fps > 0
        ? oldEditState.layers[_secondaryLayerIndex].startFrame! / oldMedia.fps
        : 0.0;
    final tertiaryStartSeconds = oldEditState.layers[_tertiaryLayerIndex].path != null &&
            oldEditState.layers[_tertiaryLayerIndex].startFrame != null &&
            oldMedia.fps > 0
        ? oldEditState.layers[_tertiaryLayerIndex].startFrame! / oldMedia.fps
        : 0.0;
    final secondaryEndSeconds = oldEditState.layers[_secondaryLayerIndex].path != null &&
            oldEditState.layers[_secondaryLayerIndex].endFrame != null &&
            oldMedia.fps > 0
        ? (oldEditState.layers[_secondaryLayerIndex].endFrame! + 1) / oldMedia.fps
        : 0.0;
    final tertiaryEndSeconds = oldEditState.layers[_tertiaryLayerIndex].path != null &&
            oldEditState.layers[_tertiaryLayerIndex].endFrame != null &&
            oldMedia.fps > 0
        ? (oldEditState.layers[_tertiaryLayerIndex].endFrame! + 1) / oldMedia.fps
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
        secondaryPath: oldEditState.layers[_secondaryLayerIndex].path,
        secondaryStartFrame: oldEditState.layers[_secondaryLayerIndex].startFrame,
        secondaryEndFrame: oldEditState.layers[_secondaryLayerIndex].endFrame,
        tertiaryPath: oldEditState.layers[_tertiaryLayerIndex].path,
        tertiaryStartFrame: oldEditState.layers[_tertiaryLayerIndex].startFrame,
        tertiaryEndFrame: oldEditState.layers[_tertiaryLayerIndex].endFrame,
        playheadFrame: oldPlayheadFrame,
        primaryGain: oldEditState.layers[_baseLayerIndex].audioGain,
        secondaryGain: oldEditState.layers[_secondaryLayerIndex].audioGain,
        tertiaryGain: oldEditState.layers[_tertiaryLayerIndex].audioGain,
        secondaryOpacity: oldEditState.layers[_secondaryLayerIndex].opacity,
        secondaryX: oldEditState.layers[_secondaryLayerIndex].x,
        secondaryY: oldEditState.layers[_secondaryLayerIndex].y,
        secondaryScale: oldEditState.layers[_secondaryLayerIndex].scale,
        secondaryVisible: oldEditState.layers[_secondaryLayerIndex].visible,
        secondaryAlphaMode: oldEditState.layers[_secondaryLayerIndex].alphaMode,
        tertiaryOpacity: oldEditState.layers[_tertiaryLayerIndex].opacity,
        tertiaryX: oldEditState.layers[_tertiaryLayerIndex].x,
        tertiaryY: oldEditState.layers[_tertiaryLayerIndex].y,
        tertiaryScale: oldEditState.layers[_tertiaryLayerIndex].scale,
        tertiaryVisible: oldEditState.layers[_tertiaryLayerIndex].visible,
        tertiaryAlphaMode: oldEditState.layers[_tertiaryLayerIndex].alphaMode,
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
    final newSecondaryStart = oldEditState.layers[_secondaryLayerIndex].path != null && newFps > 0
        ? (secondaryStartSeconds * newFps).round()
        : null;
    final newTertiaryStart = oldEditState.layers[_tertiaryLayerIndex].path != null && newFps > 0
        ? (tertiaryStartSeconds * newFps).round()
        : null;
    final newSecondaryEnd = oldEditState.layers[_secondaryLayerIndex].path != null &&
            oldEditState.layers[_secondaryLayerIndex].endFrame != null &&
            newFps > 0
        ? ((secondaryEndSeconds * newFps).round() - 1)
            .clamp(0, replacementMedia.frames - 1)
            .toInt()
        : null;
    final newTertiaryEnd = oldEditState.layers[_tertiaryLayerIndex].path != null &&
            oldEditState.layers[_tertiaryLayerIndex].endFrame != null &&
            newFps > 0
        ? ((tertiaryEndSeconds * newFps).round() - 1)
            .clamp(0, replacementMedia.frames - 1)
            .toInt()
        : null;

    if (oldEditState.layers[_secondaryLayerIndex].path != null) {
      final rebuilt = await _rebuildLayerStack(
        primaryPath: path,
        secondaryPath: oldEditState.layers[_secondaryLayerIndex].path,
        secondaryStartFrame: newSecondaryStart,
        secondaryEndFrame: newSecondaryEnd,
        tertiaryPath: oldEditState.layers[_tertiaryLayerIndex].path,
        tertiaryStartFrame: newTertiaryStart,
        tertiaryEndFrame: newTertiaryEnd,
        playheadFrame: newPlayheadFrame,
        primaryGain: oldEditState.layers[_baseLayerIndex].audioGain,
        secondaryGain: oldEditState.layers[_secondaryLayerIndex].audioGain,
        tertiaryGain: oldEditState.layers[_tertiaryLayerIndex].audioGain,
        secondaryOpacity: oldEditState.layers[_secondaryLayerIndex].opacity,
        secondaryX: oldEditState.layers[_secondaryLayerIndex].x,
        secondaryY: oldEditState.layers[_secondaryLayerIndex].y,
        secondaryScale: oldEditState.layers[_secondaryLayerIndex].scale,
        secondaryVisible: oldEditState.layers[_secondaryLayerIndex].visible,
        secondaryAlphaMode: oldEditState.layers[_secondaryLayerIndex].alphaMode,
        tertiaryOpacity: oldEditState.layers[_tertiaryLayerIndex].opacity,
        tertiaryX: oldEditState.layers[_tertiaryLayerIndex].x,
        tertiaryY: oldEditState.layers[_tertiaryLayerIndex].y,
        tertiaryScale: oldEditState.layers[_tertiaryLayerIndex].scale,
        tertiaryVisible: oldEditState.layers[_tertiaryLayerIndex].visible,
        tertiaryAlphaMode: oldEditState.layers[_tertiaryLayerIndex].alphaMode,
      );

      if (!rebuilt) {
        final replaceError = _error;
        await _rebuildLayerStack(
          primaryPath: oldBasePath,
          secondaryPath: oldEditState.layers[_secondaryLayerIndex].path,
          secondaryStartFrame: oldEditState.layers[_secondaryLayerIndex].startFrame,
          secondaryEndFrame: oldEditState.layers[_secondaryLayerIndex].endFrame,
          tertiaryPath: oldEditState.layers[_tertiaryLayerIndex].path,
          tertiaryStartFrame: oldEditState.layers[_tertiaryLayerIndex].startFrame,
          tertiaryEndFrame: oldEditState.layers[_tertiaryLayerIndex].endFrame,
          playheadFrame: oldPlayheadFrame,
          primaryGain: oldEditState.layers[_baseLayerIndex].audioGain,
          secondaryGain: oldEditState.layers[_secondaryLayerIndex].audioGain,
          tertiaryGain: oldEditState.layers[_tertiaryLayerIndex].audioGain,
          secondaryOpacity: oldEditState.layers[_secondaryLayerIndex].opacity,
          secondaryX: oldEditState.layers[_secondaryLayerIndex].x,
          secondaryY: oldEditState.layers[_secondaryLayerIndex].y,
          secondaryScale: oldEditState.layers[_secondaryLayerIndex].scale,
          secondaryVisible: oldEditState.layers[_secondaryLayerIndex].visible,
          secondaryAlphaMode: oldEditState.layers[_secondaryLayerIndex].alphaMode,
          tertiaryOpacity: oldEditState.layers[_tertiaryLayerIndex].opacity,
          tertiaryX: oldEditState.layers[_tertiaryLayerIndex].x,
          tertiaryY: oldEditState.layers[_tertiaryLayerIndex].y,
          tertiaryScale: oldEditState.layers[_tertiaryLayerIndex].scale,
          tertiaryVisible: oldEditState.layers[_tertiaryLayerIndex].visible,
          tertiaryAlphaMode: oldEditState.layers[_tertiaryLayerIndex].alphaMode,
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
        setTrackAudioGain(0, oldEditState.layers[_baseLayerIndex].audioGain, recordEdit: false);
      }
    }

    _error = null;
    notifyListeners();
    return true;
  }

  /// Exchange the media occupying the Layer 1/base and Layer 2/overlay roles.
  ///
  /// This is intentionally stronger than a visual Z-order swap. The promoted
  /// Layer 2 source becomes the authoritative base movie, while the displaced
  /// old base is rebuilt into Layer 2 and therefore receives the normal
  /// overlay controls (timing, opacity, geometry, visibility, alpha, audio).
  ///
  /// Layer 3, when present, keeps its logical Layer-3 role and media-owned
  /// source/presentation/audio state. Its movie-timeline START/END and timed
  /// SOURCE IN/OUT are converted through seconds when the promoted base changes
  /// frame rate, because MLT reopens overlay producers against the base profile.
  ///
  /// The role boundary remains timed-video-only: a still cannot become Layer 1.
  Future<bool> _swapBaseAndSecondaryRoles() async {
    final oldMedia = _media;
    final oldSecondaryPath = _layers[_secondaryLayerIndex].path;

    if (!initialized ||
        oldMedia == null ||
        oldMedia.isStill ||
        !oldMedia.hasVideo ||
        oldSecondaryPath == null ||
        _layers[_secondaryLayerIndex].isStill ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      if (_layers[_secondaryLayerIndex].isStill) {
        _error = 'A still image cannot become the base layer.';
        notifyListeners();
      }
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    // First-swap preflight: allocate the inactive GL texture to the exact
    // profile dimensions Layer 2 will use when promoted to Layer 1. This runs
    // while the current composition is still fully visible and before Flutter
    // freezes presentation, so the first cross-aspect swap pays no lazy GL
    // allocation cost. Subsequent swaps are already hot, but repeating this
    // preflight is cheap and also covers a replaced Layer-2 source.
    final prewarmSerialBefore = bridge.previewPrewarmSerial;
    if (bridge.prewarmPreviewLayer(_secondaryLayerIndex)) {
      await _waitForPreviewPrewarm(prewarmSerialBefore);
    }

    // Keep the last fully composed frame published while `open()` temporarily
    // creates the promoted base with default properties and the old base plus
    // optional Layer 3 are rebuilt behind it. Nested preview-update holds are
    // supported natively, so every helper below remains inside one atomic
    // presentation transaction.
    return _runWithFrozenPreview(() async {
      final oldBasePath = oldMedia.path;
      final oldPlayheadFrame = bridge.positionFrame;
      final oldPlayheadSeconds = oldMedia.fps > 0
          ? oldPlayheadFrame / oldMedia.fps
          : 0.0;

      final oldEditState = _captureEditState();
      final oldUndoState = List<_ClipEditState>.from(_undoStack);
      final oldRedoState = List<_ClipEditState>.from(_redoStack);

      final oldBaseState = oldEditState.layers[_baseLayerIndex];
      final oldSecondaryState = oldEditState.layers[_secondaryLayerIndex];
      final oldTertiaryState = oldEditState.layers[_tertiaryLayerIndex];
      final oldTertiaryPath = oldTertiaryState.path;

      Future<bool> restoreOldComposition() {
        return _rebuildLayerStack(
          primaryPath: oldBasePath,
          secondaryPath: oldSecondaryPath,
          secondaryStartFrame: oldSecondaryState.startFrame,
          secondaryEndFrame: oldSecondaryState.endFrame,
          secondarySourceInFrame: oldSecondaryState.sourceInFrame,
          secondarySourceOutFrame: oldSecondaryState.sourceOutFrame,
          tertiaryPath: oldTertiaryPath,
          tertiaryStartFrame: oldTertiaryState.startFrame,
          tertiaryEndFrame: oldTertiaryState.endFrame,
          tertiarySourceInFrame: oldTertiaryState.sourceInFrame,
          tertiarySourceOutFrame: oldTertiaryState.sourceOutFrame,
          playheadFrame: oldPlayheadFrame,
          primaryGain: oldBaseState.audioGain,
          secondaryGain: oldSecondaryState.audioGain,
          tertiaryGain: oldTertiaryState.audioGain,
          secondaryOpacity: oldSecondaryState.opacity,
          secondaryX: oldSecondaryState.x,
          secondaryY: oldSecondaryState.y,
          secondaryScale: oldSecondaryState.scale,
          secondaryVisible: oldSecondaryState.visible,
          secondaryAlphaMode: oldSecondaryState.alphaMode,
          tertiaryOpacity: oldTertiaryState.opacity,
          tertiaryX: oldTertiaryState.x,
          tertiaryY: oldTertiaryState.y,
          tertiaryScale: oldTertiaryState.scale,
          tertiaryVisible: oldTertiaryState.visible,
          tertiaryAlphaMode: oldTertiaryState.alphaMode,
          editState: oldEditState,
          undoState: oldUndoState,
          redoState: oldRedoState,
          visualOrder: oldEditState.visualOrder,
        );
      }

      // Probe the would-be base through the normal open path so its frame rate,
      // dimensions, duration, and timed/still classification become authoritative.
      final opened = await open(oldSecondaryPath);
      final newBase = _media;

      if (!opened ||
          newBase == null ||
          newBase.isStill ||
          !newBase.hasVideo) {
        final swapError = !opened
            ? _error
            : 'Only a timed video can become the base layer.';

        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? (swapError ?? 'The layer roles could not be changed.')
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }

      final newFps = newBase.fps;
      final newPlayheadFrame = newFps > 0
          ? (oldPlayheadSeconds * newFps).round()
          : 0;

      int? convertStartBoundary(
        int? sourceFrame, {
        int? maximumFrame,
      }) {
        if (sourceFrame == null || oldMedia.fps <= 0 || newFps <= 0) {
          return sourceFrame;
        }

        final converted =
            ((sourceFrame / oldMedia.fps) * newFps).round();
        if (maximumFrame == null) {
          return converted < 0 ? 0 : converted;
        }
        return converted.clamp(0, maximumFrame).toInt();
      }

      int? convertInclusiveEnd(
        int? sourceFrame, {
        required int? convertedStart,
        int? maximumFrame,
      }) {
        if (sourceFrame == null || oldMedia.fps <= 0 || newFps <= 0) {
          return sourceFrame;
        }

        // END/OUT are inclusive. Convert the exclusive boundary through time
        // and subtract one so the represented duration survives the rate change.
        final sourceBoundarySeconds =
            (sourceFrame + 1) / oldMedia.fps;
        var converted =
            (sourceBoundarySeconds * newFps).round() - 1;
        final minimum = convertedStart ?? 0;
        if (converted < minimum) {
          converted = minimum;
        }
        if (maximumFrame != null && converted > maximumFrame) {
          converted = maximumFrame;
        }
        return converted;
      }

      final newTimelineMaximum =
          newBase.frames > 0 ? newBase.frames - 1 : null;
      final newTertiaryStart =
          oldTertiaryPath != null
              ? convertStartBoundary(
                  oldTertiaryState.startFrame,
                  maximumFrame: newTimelineMaximum,
                )
              : null;
      final newTertiaryEnd =
          oldTertiaryPath != null
              ? convertInclusiveEnd(
                  oldTertiaryState.endFrame,
                  convertedStart: newTertiaryStart,
                  maximumFrame: newTimelineMaximum,
                )
              : null;
      final newTertiarySourceIn =
          oldTertiaryPath != null && !oldTertiaryState.isStill
              ? convertStartBoundary(oldTertiaryState.sourceInFrame)
              : null;
      final newTertiarySourceOut =
          oldTertiaryPath != null && !oldTertiaryState.isStill
              ? convertInclusiveEnd(
                  oldTertiaryState.sourceOutFrame,
                  convertedStart: newTertiarySourceIn,
                )
              : null;

      // Presentation/edit properties belong to the media asset, not to the
      // numbered role it happens to occupy. The promoted former Layer 2 now
      // becomes a normal full-frame base. The displaced old base is added back
      // as a fresh overlay at frame zero so native MLT computes an appropriate
      // fit/center geometry for the *new* canvas. In particular, do not copy a
      // vertical clip's old X/Y/scale onto a landscape clip (or vice versa).
      final addedOldBase = await _addTrackAtFrame(
        oldBasePath,
        0,
        endFrame: newBase.frames > 0 ? newBase.frames - 1 : null,
      );

      if (!addedOldBase) {
        final swapError = _error;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? (swapError ?? 'The displaced base could not become Layer 2.')
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }

      if (trackHasAudio(_baseLayerIndex)) {
        setTrackAudioGain(
          _baseLayerIndex,
          oldSecondaryState.audioGain,
          recordEdit: false,
        );
      }
      if (trackHasAudio(_secondaryLayerIndex)) {
        setTrackAudioGain(
          _secondaryLayerIndex,
          oldBaseState.audioGain,
          recordEdit: false,
        );
      }

      if (oldTertiaryPath != null) {
        final addedTertiary = await _addTrackAtFrame(
          oldTertiaryPath,
          newTertiaryStart ?? 0,
          endFrame: newTertiaryEnd,
          sourceInFrame: newTertiarySourceIn,
          sourceOutFrame: newTertiarySourceOut,
        );

        if (!addedTertiary) {
          final swapError = _error;
          final rolledBack = await restoreOldComposition();
          _error = rolledBack
              ? (swapError ?? 'Layer 3 could not survive the base-role change.')
              : 'Layer role swap failed and the previous composition could not be restored.';
          notifyListeners();
          return false;
        }

        if (!bridge.setLayerGeometry(
          _tertiaryLayerIndex,
          oldTertiaryState.x,
          oldTertiaryState.y,
          oldTertiaryState.scale,
        )) {
          final swapError = bridge.lastError.isEmpty
              ? 'Layer 3 geometry could not be restored after role promotion.'
              : bridge.lastError;
          final rolledBack = await restoreOldComposition();
          _error = rolledBack
              ? swapError
              : 'Layer role swap failed and the previous composition could not be restored.';
          notifyListeners();
          return false;
        }
        _syncTertiaryGeometry();

        final effectiveTertiaryOpacity = oldTertiaryState.visible
            ? oldTertiaryState.opacity
            : 0.0;
        if (!bridge.setLayerOpacity(
          _tertiaryLayerIndex,
          effectiveTertiaryOpacity,
        )) {
          final swapError = bridge.lastError.isEmpty
              ? 'Layer 3 opacity could not be restored after role promotion.'
              : bridge.lastError;
          final rolledBack = await restoreOldComposition();
          _error = rolledBack
              ? swapError
              : 'Layer role swap failed and the previous composition could not be restored.';
          notifyListeners();
          return false;
        }
        _layers[_tertiaryLayerIndex].opacity = oldTertiaryState.opacity;
        _layers[_tertiaryLayerIndex].visible = oldTertiaryState.visible;

        if (!bridge.setLayerAlphaMode(
          _tertiaryLayerIndex,
          oldTertiaryState.alphaMode,
        )) {
          final swapError = bridge.lastError.isEmpty
              ? 'Layer 3 alpha interpretation could not be restored after role promotion.'
              : bridge.lastError;
          final rolledBack = await restoreOldComposition();
          _error = rolledBack
              ? swapError
              : 'Layer role swap failed and the previous composition could not be restored.';
          notifyListeners();
          return false;
        }
        _layers[_tertiaryLayerIndex].alphaMode =
            bridge.layerAlphaMode(_tertiaryLayerIndex).clamp(0, 2).toInt();

        _layers[_tertiaryLayerIndex].hasAudio =
            bridge.trackHasAudio(_tertiaryLayerIndex);
        if (_layers[_tertiaryLayerIndex].hasAudio) {
          if (!bridge.setTrackAudioGain(
            _tertiaryLayerIndex,
            oldTertiaryState.audioGain,
          )) {
            final swapError = bridge.lastError.isEmpty
                ? 'Layer 3 audio level could not be restored after role promotion.'
                : bridge.lastError;
            final rolledBack = await restoreOldComposition();
            _error = rolledBack
                ? swapError
                : 'Layer role swap failed and the previous composition could not be restored.';
            notifyListeners();
            return false;
          }
          _syncTrackAudioGain(_tertiaryLayerIndex);
        }
      }

      // Keep the numeric visual permutation that existed before the boundary
      // crossing. Because media identities just exchanged logical slots 0/1,
      // leaving the permutation unchanged produces exactly the visible A<->B
      // crossing the user requested while Layer 3 stays in its prior position.
      if (!_setVisualOrderNative(oldEditState.visualOrder)) {
        final swapError = _error;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? (swapError ?? 'The visual layer order could not be restored.')
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }

      _seekSourceFrameClamped(newPlayheadFrame);

      // A base-role change creates a new clip authority (profile, duration,
      // frame zero). Treat it as a new composition baseline rather than
      // allowing older history entries from the previous base to rebuild
      // against incompatible clip coordinates.
      _undoStack.clear();
      _redoStack.clear();
      _error = null;
      notifyListeners();
      return true;
    });
  }


  /// Exchange the media occupying the Layer 1/base and Layer 3/overlay roles.
  ///
  /// Layer 3 becomes the authoritative base movie. Existing Layer 2 keeps its
  /// logical Layer-2 role and media-owned timing/source/presentation/audio
  /// state, converted through time when the new base frame rate differs. The
  /// displaced old base is rebuilt as a fresh Layer 3 so native MLT computes
  /// fit/center geometry for the new canvas instead of inheriting unrelated
  /// overlay transforms.
  ///
  /// As with Layer 2 promotion, the role boundary is timed-video-only: a still
  /// image cannot become Layer 1.
  Future<bool> _swapBaseAndTertiaryRoles() async {
    final oldMedia = _media;
    final oldSecondaryPath = _layers[_secondaryLayerIndex].path;
    final oldTertiaryPath = _layers[_tertiaryLayerIndex].path;

    if (!initialized ||
        oldMedia == null ||
        oldMedia.isStill ||
        !oldMedia.hasVideo ||
        oldSecondaryPath == null ||
        oldTertiaryPath == null ||
        _layers[_tertiaryLayerIndex].isStill ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      if (_layers[_tertiaryLayerIndex].isStill) {
        _error = 'A still image cannot become the base layer.';
        notifyListeners();
      }
      return false;
    }

    if (!await _parkPlaybackForLayerChange()) {
      return false;
    }

    // Prewarm the exact profile dimensions Layer 3 will use as the new base.
    // The current composition remains visible while the inactive GL texture
    // allocates, preserving the same hitch-free first-swap path as Layer 2.
    final prewarmSerialBefore = bridge.previewPrewarmSerial;
    if (bridge.prewarmPreviewLayer(_tertiaryLayerIndex)) {
      await _waitForPreviewPrewarm(prewarmSerialBefore);
    }

    return _runWithFrozenPreview(() async {
      final oldBasePath = oldMedia.path;
      final oldPlayheadFrame = bridge.positionFrame;
      final oldPlayheadSeconds =
          oldMedia.fps > 0 ? oldPlayheadFrame / oldMedia.fps : 0.0;

      final oldEditState = _captureEditState();
      final oldUndoState = List<_ClipEditState>.from(_undoStack);
      final oldRedoState = List<_ClipEditState>.from(_redoStack);

      final oldBaseState = oldEditState.layers[_baseLayerIndex];
      final oldSecondaryState = oldEditState.layers[_secondaryLayerIndex];
      final oldTertiaryState = oldEditState.layers[_tertiaryLayerIndex];

      Future<bool> restoreOldComposition() {
        return _rebuildLayerStack(
          primaryPath: oldBasePath,
          secondaryPath: oldSecondaryPath,
          secondaryStartFrame: oldSecondaryState.startFrame,
          secondaryEndFrame: oldSecondaryState.endFrame,
          secondarySourceInFrame: oldSecondaryState.sourceInFrame,
          secondarySourceOutFrame: oldSecondaryState.sourceOutFrame,
          tertiaryPath: oldTertiaryPath,
          tertiaryStartFrame: oldTertiaryState.startFrame,
          tertiaryEndFrame: oldTertiaryState.endFrame,
          tertiarySourceInFrame: oldTertiaryState.sourceInFrame,
          tertiarySourceOutFrame: oldTertiaryState.sourceOutFrame,
          playheadFrame: oldPlayheadFrame,
          primaryGain: oldBaseState.audioGain,
          secondaryGain: oldSecondaryState.audioGain,
          tertiaryGain: oldTertiaryState.audioGain,
          secondaryOpacity: oldSecondaryState.opacity,
          secondaryX: oldSecondaryState.x,
          secondaryY: oldSecondaryState.y,
          secondaryScale: oldSecondaryState.scale,
          secondaryVisible: oldSecondaryState.visible,
          secondaryAlphaMode: oldSecondaryState.alphaMode,
          tertiaryOpacity: oldTertiaryState.opacity,
          tertiaryX: oldTertiaryState.x,
          tertiaryY: oldTertiaryState.y,
          tertiaryScale: oldTertiaryState.scale,
          tertiaryVisible: oldTertiaryState.visible,
          tertiaryAlphaMode: oldTertiaryState.alphaMode,
          editState: oldEditState,
          undoState: oldUndoState,
          redoState: oldRedoState,
          visualOrder: oldEditState.visualOrder,
        );
      }

      final opened = await open(oldTertiaryPath);
      final newBase = _media;

      if (!opened ||
          newBase == null ||
          newBase.isStill ||
          !newBase.hasVideo) {
        final swapError =
            !opened ? _error : 'Only a timed video can become the base layer.';
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? (swapError ?? 'The layer roles could not be changed.')
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }

      final newFps = newBase.fps;
      final newPlayheadFrame =
          newFps > 0 ? (oldPlayheadSeconds * newFps).round() : 0;

      int? convertStartBoundary(
        int? sourceFrame, {
        int? maximumFrame,
      }) {
        if (sourceFrame == null || oldMedia.fps <= 0 || newFps <= 0) {
          return sourceFrame;
        }

        final converted = ((sourceFrame / oldMedia.fps) * newFps).round();
        if (maximumFrame == null) {
          return converted < 0 ? 0 : converted;
        }
        return converted.clamp(0, maximumFrame).toInt();
      }

      int? convertInclusiveEnd(
        int? sourceFrame, {
        required int? convertedStart,
        int? maximumFrame,
      }) {
        if (sourceFrame == null || oldMedia.fps <= 0 || newFps <= 0) {
          return sourceFrame;
        }

        final sourceBoundarySeconds = (sourceFrame + 1) / oldMedia.fps;
        var converted = (sourceBoundarySeconds * newFps).round() - 1;
        final minimum = convertedStart ?? 0;
        if (converted < minimum) {
          converted = minimum;
        }
        if (maximumFrame != null && converted > maximumFrame) {
          converted = maximumFrame;
        }
        return converted;
      }

      final newTimelineMaximum =
          newBase.frames > 0 ? newBase.frames - 1 : null;
      final newSecondaryStart = convertStartBoundary(
        oldSecondaryState.startFrame,
        maximumFrame: newTimelineMaximum,
      );
      final newSecondaryEnd = convertInclusiveEnd(
        oldSecondaryState.endFrame,
        convertedStart: newSecondaryStart,
        maximumFrame: newTimelineMaximum,
      );
      final newSecondarySourceIn = !oldSecondaryState.isStill
          ? convertStartBoundary(oldSecondaryState.sourceInFrame)
          : null;
      final newSecondarySourceOut = !oldSecondaryState.isStill
          ? convertInclusiveEnd(
              oldSecondaryState.sourceOutFrame,
              convertedStart: newSecondarySourceIn,
            )
          : null;

      // Rebuild the surviving Layer 2 first so the displaced old base can then
      // occupy the real Layer-3 slot. The surviving asset keeps its temporal
      // selection while the new base defines the profile/frame clock.
      final addedSecondary = await _addTrackAtFrame(
        oldSecondaryPath,
        newSecondaryStart ?? 0,
        endFrame: newSecondaryEnd,
        sourceInFrame: newSecondarySourceIn,
        sourceOutFrame: newSecondarySourceOut,
      );

      if (!addedSecondary) {
        final swapError = _error;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? (swapError ?? 'Layer 2 could not survive the base-role change.')
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }

      // The displaced old base enters Layer 3 as a fresh overlay. Do not carry
      // the promoted Layer 3's old overlay transform into it.
      final addedOldBase = await _addTrackAtFrame(
        oldBasePath,
        0,
        endFrame: newBase.frames > 0 ? newBase.frames - 1 : null,
      );

      if (!addedOldBase) {
        final swapError = _error;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? (swapError ?? 'The displaced base could not become Layer 3.')
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }

      // Restore the surviving Layer 2's media-owned presentation state after
      // both overlays exist so no later tractor rebuild can disturb it.
      if (!bridge.setSecondaryGeometry(
        oldSecondaryState.x,
        oldSecondaryState.y,
        oldSecondaryState.scale,
      )) {
        final swapError = bridge.lastError.isEmpty
            ? 'Layer 2 geometry could not be restored after Layer 3 promotion.'
            : bridge.lastError;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? swapError
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }
      _syncSecondaryGeometry();

      final effectiveSecondaryOpacity = oldSecondaryState.visible
          ? oldSecondaryState.opacity
          : 0.0;
      if (!bridge.setSecondaryOpacity(effectiveSecondaryOpacity)) {
        final swapError = bridge.lastError.isEmpty
            ? 'Layer 2 opacity could not be restored after Layer 3 promotion.'
            : bridge.lastError;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? swapError
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }
      _layers[_secondaryLayerIndex].opacity = oldSecondaryState.opacity;
      _layers[_secondaryLayerIndex].visible = oldSecondaryState.visible;

      if (!bridge.setSecondaryAlphaMode(oldSecondaryState.alphaMode)) {
        final swapError = bridge.lastError.isEmpty
            ? 'Layer 2 alpha interpretation could not be restored after Layer 3 promotion.'
            : bridge.lastError;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? swapError
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }
      _layers[_secondaryLayerIndex].alphaMode =
          bridge.secondaryAlphaMode.clamp(0, 2).toInt();

      // Audio gain follows each media asset through the role exchange.
      if (trackHasAudio(_baseLayerIndex)) {
        setTrackAudioGain(
          _baseLayerIndex,
          oldTertiaryState.audioGain,
          recordEdit: false,
        );
      }
      if (trackHasAudio(_secondaryLayerIndex)) {
        setTrackAudioGain(
          _secondaryLayerIndex,
          oldSecondaryState.audioGain,
          recordEdit: false,
        );
      }
      if (trackHasAudio(_tertiaryLayerIndex)) {
        setTrackAudioGain(
          _tertiaryLayerIndex,
          oldBaseState.audioGain,
          recordEdit: false,
        );
      }

      // Keep the numeric visual permutation. Media identities exchanged slots
      // 0/2, so the requested adjacent crossing becomes visible while Layer 2
      // stays exactly where it was in the stack.
      if (!_setVisualOrderNative(oldEditState.visualOrder)) {
        final swapError = _error;
        final rolledBack = await restoreOldComposition();
        _error = rolledBack
            ? (swapError ?? 'The visual layer order could not be restored.')
            : 'Layer role swap failed and the previous composition could not be restored.';
        notifyListeners();
        return false;
      }

      _seekSourceFrameClamped(newPlayheadFrame);

      _undoStack.clear();
      _redoStack.clear();
      _error = null;
      notifyListeners();
      return true;
    });
  }

  List<int> _presentVisualOrder() => _visualOrder
      .where((int layerIndex) => hasLayer(layerIndex))
      .toList(growable: false);

  bool canMoveLayerUp(int layerIndex) {
    if (!hasLayer(layerIndex) ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      return false;
    }
    final present = _presentVisualOrder();
    final position = present.indexOf(layerIndex);
    return position >= 0 && position < present.length - 1;
  }

  bool canMoveLayerDown(int layerIndex) {
    if (!hasLayer(layerIndex) ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      return false;
    }
    final present = _presentVisualOrder();
    final position = present.indexOf(layerIndex);
    return position > 0;
  }

  bool _moveCrossesBaseSecondaryBoundary(
    int layerIndex,
    int direction,
  ) {
    final present = _presentVisualOrder();
    final position = present.indexOf(layerIndex);
    final otherPosition = position + direction;

    if (position < 0 ||
        otherPosition < 0 ||
        otherPosition >= present.length) {
      return false;
    }

    final otherLayer = present[otherPosition];
    return (layerIndex == _baseLayerIndex &&
            otherLayer == _secondaryLayerIndex) ||
        (layerIndex == _secondaryLayerIndex &&
            otherLayer == _baseLayerIndex);
  }

  @visibleForTesting
  bool moveCrossesBaseSecondaryBoundaryForTesting(
    int layerIndex,
    int direction,
  ) =>
      _moveCrossesBaseSecondaryBoundary(layerIndex, direction);

  bool _moveCrossesBaseTertiaryBoundary(
    int layerIndex,
    int direction,
  ) {
    final present = _presentVisualOrder();
    final position = present.indexOf(layerIndex);
    final otherPosition = position + direction;

    if (position < 0 ||
        otherPosition < 0 ||
        otherPosition >= present.length) {
      return false;
    }

    final otherLayer = present[otherPosition];
    return (layerIndex == _baseLayerIndex &&
            otherLayer == _tertiaryLayerIndex) ||
        (layerIndex == _tertiaryLayerIndex &&
            otherLayer == _baseLayerIndex);
  }

  @visibleForTesting
  bool moveCrossesBaseTertiaryBoundaryForTesting(
    int layerIndex,
    int direction,
  ) =>
      _moveCrossesBaseTertiaryBoundary(layerIndex, direction);

  Future<bool> moveLayerUp(int layerIndex) async {
    if (!canMoveLayerUp(layerIndex)) {
      return false;
    }

    // Any timed overlay crossing the Layer-1 boundary exchanges roles with
    // the base. Layer 2 promotion preserves Layer 3; Layer 3 promotion preserves
    // Layer 2. Overlay-to-overlay crossings remain visual-order only.
    if (!_editStateTestMode) {
      if (_moveCrossesBaseSecondaryBoundary(layerIndex, 1)) {
        return _swapBaseAndSecondaryRoles();
      }
      if (_moveCrossesBaseTertiaryBoundary(layerIndex, 1)) {
        return _swapBaseAndTertiaryRoles();
      }
    }

    return _moveLayerVisualOrder(layerIndex, 1);
  }

  Future<bool> moveLayerDown(int layerIndex) async {
    if (!canMoveLayerDown(layerIndex)) {
      return false;
    }

    if (!_editStateTestMode) {
      if (_moveCrossesBaseSecondaryBoundary(layerIndex, -1)) {
        return _swapBaseAndSecondaryRoles();
      }
      if (_moveCrossesBaseTertiaryBoundary(layerIndex, -1)) {
        return _swapBaseAndTertiaryRoles();
      }
    }

    return _moveLayerVisualOrder(layerIndex, -1);
  }

  List<int> _visualOrderMoved(int layerIndex, int direction) {
    final result = List<int>.from(_visualOrder);
    final present = _presentVisualOrder();
    final currentPresentPosition = present.indexOf(layerIndex);
    final swapPresentPosition = currentPresentPosition + direction;
    final otherLayer = present[swapPresentPosition];
    final a = result.indexOf(layerIndex);
    final b = result.indexOf(otherLayer);
    result[a] = otherLayer;
    result[b] = layerIndex;
    return result;
  }

  Future<bool> _moveLayerVisualOrder(int layerIndex, int direction) async {
    final before = _captureEditState();
    final desired = _ClipEditState(
      trimInFrame: before.trimInFrame,
      trimOutFrame: before.trimOutFrame,
      inFrame: before.inFrame,
      outFrame: before.outFrame,
      layers: before.layers,
      visualOrder: _visualOrderMoved(layerIndex, direction),
    );
    final originalUndo = List<_ClipEditState>.from(_undoStack);
    final originalRedo = List<_ClipEditState>.from(_redoStack);

    String basePath = '';
    int playheadFrame = 0;

    if (!_editStateTestMode) {
      final media = _media;
      if (!initialized || media == null || media.isStill || !media.hasVideo) {
        return false;
      }
      if (!await _parkPlaybackForLayerChange()) {
        return false;
      }
      basePath = _layers[_baseLayerIndex].path ?? media.path;
      playheadFrame = bridge.positionFrame;
    }

    _finishContinuousEditGroup();
    _restoringEditState = true;
    notifyListeners();

    try {
      final reordered = await _applyEditState(
        desired,
        basePath: basePath,
        playheadFrame: playheadFrame,
      );

      if (!reordered) {
        final reorderError = _error;
        final rolledBack = await _applyEditState(
          before,
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
            ? (reorderError ?? 'The layer order could not be changed.')
            : 'Layer reorder failed and the previous composition could not be restored.';
        return false;
      }

      final after = _captureEditState();
      _undoStack
        ..clear()
        ..addAll(originalUndo);
      _redoStack.clear();
      if (!before.sameAs(after)) {
        _undoStack.add(before);
      }
      _error = null;
      return true;
    } finally {
      _restoringEditState = false;
      notifyListeners();
    }
  }

  /// Compatibility alias for the old two-layer swap command.
  ///
  /// The generalized ordering model no longer exchanges source identities.
  /// It swaps only visual Z-order while Layer 1 remains the base authority.
  Future<bool> swapLayerOrder() async {
    if (trackCount != 2) {
      return false;
    }
    if (canMoveLayerUp(_baseLayerIndex)) {
      return moveLayerUp(_baseLayerIndex);
    }
    if (canMoveLayerDown(_baseLayerIndex)) {
      return moveLayerDown(_baseLayerIndex);
    }
    return false;
  }

  Future<bool> _rebuildLayerStack({
    required String primaryPath,
    required String? secondaryPath,
    required int? secondaryStartFrame,
    int? secondaryEndFrame,
    int? secondarySourceInFrame,
    int? secondarySourceOutFrame,
    String? tertiaryPath,
    int? tertiaryStartFrame,
    int? tertiaryEndFrame,
    int? tertiarySourceInFrame,
    int? tertiarySourceOutFrame,
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
    List<int>? visualOrder,
  }) async {
    final preservedVisualOrder = List<int>.from(
      visualOrder ?? editState?.visualOrder ?? _visualOrder,
    );
    final preservedExportRangeMode =
        editState != null ? _exportRangeMode : null;
    final preservedExportRangeModeExplicit =
        editState != null ? _exportRangeModeExplicit : null;

    if (tertiaryPath != null && secondaryPath == null) {
      _error = 'Layer 3 requires Layer 2 underneath it.';
      notifyListeners();
      return false;
    }

    final resolvedSecondarySourceIn = secondarySourceInFrame ??
        editState?.layers[_secondaryLayerIndex].sourceInFrame;
    final resolvedSecondarySourceOut = secondarySourceOutFrame ??
        editState?.layers[_secondaryLayerIndex].sourceOutFrame;
    final resolvedTertiarySourceIn = tertiarySourceInFrame ??
        editState?.layers[_tertiaryLayerIndex].sourceInFrame;
    final resolvedTertiarySourceOut = tertiarySourceOutFrame ??
        editState?.layers[_tertiaryLayerIndex].sourceOutFrame;

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
        endFrame: secondaryEndFrame,
        sourceInFrame: resolvedSecondarySourceIn,
        sourceOutFrame: resolvedSecondarySourceOut,
      );
      if (!added) {
        return false;
      }
    }

    if (tertiaryPath != null) {
      final added = await _addTrackAtFrame(
        tertiaryPath,
        tertiaryStartFrame ?? 0,
        endFrame: tertiaryEndFrame,
        sourceInFrame: resolvedTertiarySourceIn,
        sourceOutFrame: resolvedTertiarySourceOut,
      );
      if (!added) {
        return false;
      }
    }

    if (trackHasAudio(0)) {
      setTrackAudioGain(0, primaryGain, recordEdit: false);
    }

    if (secondaryPath != null && hasLayer(_secondaryLayerIndex)) {
      _setSecondaryLayerGeometry(
        x: secondaryX,
        y: secondaryY,
        scale: secondaryScale,
        recordEdit: false,
      );
      _setSecondaryLayerOpacity(secondaryOpacity, recordEdit: false);
      if (!secondaryVisible) {
        _setSecondaryLayerVisible(false, recordEdit: false);
      }
      _setSecondaryLayerAlphaMode(secondaryAlphaMode, recordEdit: false);
      if (trackHasAudio(1)) {
        setTrackAudioGain(1, secondaryGain, recordEdit: false);
      }
    }

    if (tertiaryPath != null && hasLayer(_tertiaryLayerIndex)) {
      _setTertiaryLayerGeometry(
        x: tertiaryX,
        y: tertiaryY,
        scale: tertiaryScale,
        recordEdit: false,
      );
      _setTertiaryLayerOpacity(tertiaryOpacity, recordEdit: false);
      if (!tertiaryVisible) {
        _setTertiaryLayerVisible(false, recordEdit: false);
      }
      _setTertiaryLayerAlphaMode(tertiaryAlphaMode, recordEdit: false);
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

    final desiredVisualOrder = preservedVisualOrder;
    if (trackCount > 1 && !_setVisualOrderNative(desiredVisualOrder)) {
      notifyListeners();
      return false;
    }
    _visualOrder = List<int>.from(desiredVisualOrder);

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
  void setLayerOpacity(
    int layerIndex,
    double value, {
    bool recordEdit = true,
  }) {
    switch (layerIndex) {
      case _secondaryLayerIndex:
        _setSecondaryLayerOpacity(value, recordEdit: recordEdit);
        return;
      case _tertiaryLayerIndex:
        _setTertiaryLayerOpacity(value, recordEdit: recordEdit);
        return;
    }
  }

  void setLayerVisible(
    int layerIndex,
    bool visible, {
    bool recordEdit = true,
  }) {
    switch (layerIndex) {
      case _secondaryLayerIndex:
        _setSecondaryLayerVisible(visible, recordEdit: recordEdit);
        return;
      case _tertiaryLayerIndex:
        _setTertiaryLayerVisible(visible, recordEdit: recordEdit);
        return;
    }
  }

  void toggleLayerVisible(int layerIndex) {
    if (!hasLayer(layerIndex) || layerIndex == _baseLayerIndex) {
      return;
    }
    setLayerVisible(layerIndex, !_layers[layerIndex].visible);
  }

  Future<bool> setLayerTiming(
    int layerIndex, {
    required int startFrame,
    required int endFrame,
  }) async {
    final media = _media;
    if (!initialized ||
        media == null ||
        media.isStill ||
        media.frames <= 0 ||
        layerIndex <= _baseLayerIndex ||
        layerIndex >= _layerSlotCount ||
        !hasLayer(layerIndex) ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      return false;
    }

    if (startFrame > endFrame) {
      return false;
    }

    final requestedStart = startFrame.clamp(0, media.frames - 1).toInt();
    final requestedEnd = endFrame.clamp(requestedStart, media.frames - 1).toInt();

    final layer = _layers[layerIndex];
    if (layer.startFrame == requestedStart &&
        layer.endFrame == requestedEnd) {
      return true;
    }

    final before = _captureEditState();
    final originalUndo = List<_ClipEditState>.from(_undoStack);
    final originalRedo = List<_ClipEditState>.from(_redoStack);
    final desiredLayers = List<_LayerEditState>.from(before.layers);
    final old = desiredLayers[layerIndex];
    desiredLayers[layerIndex] = _LayerEditState(
      present: old.present,
      path: old.path,
      startFrame: requestedStart,
      endFrame: requestedEnd,
      sourceInFrame: old.sourceInFrame,
      sourceOutFrame: old.sourceOutFrame,
      sourceFrameCount: old.sourceFrameCount,
      opacity: old.opacity,
      x: old.x,
      y: old.y,
      scale: old.scale,
      visible: old.visible,
      isStill: old.isStill,
      hasAlpha: old.hasAlpha,
      alphaMode: old.alphaMode,
      hasAudio: old.hasAudio,
      audioGain: old.audioGain,
    );

    final desired = _ClipEditState(
      trimInFrame: before.trimInFrame,
      trimOutFrame: before.trimOutFrame,
      inFrame: before.inFrame,
      outFrame: before.outFrame,
      layers: desiredLayers,
      visualOrder: before.visualOrder,
    );

    final basePath = _layers[_baseLayerIndex].path ?? media.path;

    _finishContinuousEditGroup();
    _restoringEditState = true;
    notifyListeners();

    bool restored = false;
    String? timingError;
    try {
      if (!await _parkPlaybackForLayerChange()) {
        return false;
      }

      final playheadFrame = bridge.positionFrame;

      restored = await _runWithFrozenPreview(
        () => _applyEditState(
          desired,
          basePath: basePath,
          playheadFrame: playheadFrame,
        ),
      );

      if (!restored) {
        timingError = _error;
        final rolledBack = await _runWithFrozenPreview(
          () => _applyEditState(
            before,
            basePath: basePath,
            playheadFrame: playheadFrame,
          ),
        );

        _undoStack
          ..clear()
          ..addAll(originalUndo);
        _redoStack
          ..clear()
          ..addAll(originalRedo);

        _error = rolledBack
            ? (timingError ?? 'The layer timing could not be changed.')
            : 'Layer timing failed and the previous composition could not be restored.';
        return false;
      }

      _syncLayerTimingFromNative(layerIndex);
      final after = _captureEditState();

      _undoStack
        ..clear()
        ..addAll(originalUndo);
      _redoStack.clear();

      if (!before.sameAs(after)) {
        _undoStack.add(before);
      }

      _error = null;
      return true;
    } finally {
      _restoringEditState = false;
      notifyListeners();
    }
  }

  Future<bool> nudgeLayerStart(int layerIndex, int deltaFrames) {
    final layer = layerState(layerIndex);
    final start = layer.startFrame;
    final end = layer.endFrame;
    if (!layer.present || start == null || end == null) {
      return Future<bool>.value(false);
    }
    final media = _media;
    if (media == null || media.frames <= 0) {
      return Future<bool>.value(false);
    }

    final target = (start + deltaFrames).clamp(0, end).toInt();
    return setLayerTiming(
      layerIndex,
      startFrame: target,
      endFrame: end,
    );
  }

  Future<bool> nudgeLayerEnd(int layerIndex, int deltaFrames) {
    final layer = layerState(layerIndex);
    final start = layer.startFrame;
    final end = layer.endFrame;
    if (!layer.present || start == null || end == null) {
      return Future<bool>.value(false);
    }
    final media = _media;
    if (media == null || media.frames <= 0) {
      return Future<bool>.value(false);
    }

    final target =
        (end + deltaFrames).clamp(start, media.frames - 1).toInt();
    return setLayerTiming(
      layerIndex,
      startFrame: start,
      endFrame: target,
    );
  }

  Future<bool> setLayerSourceRange(
    int layerIndex, {
    required int sourceInFrame,
    required int sourceOutFrame,
  }) async {
    final media = _media;
    final layer = layerState(layerIndex);
    final sourceFrameCount = layer.sourceFrameCount;

    if (!initialized ||
        media == null ||
        media.isStill ||
        layerIndex <= _baseLayerIndex ||
        layerIndex >= _layerSlotCount ||
        !layer.present ||
        layer.isStill ||
        sourceFrameCount == null ||
        sourceFrameCount <= 0 ||
        _opening ||
        _addingTrack ||
        _exporting ||
        _restoringEditState) {
      return false;
    }

    if (sourceInFrame > sourceOutFrame) {
      return false;
    }

    final requestedIn = sourceInFrame.clamp(0, sourceFrameCount - 1).toInt();
    final requestedOut =
        sourceOutFrame.clamp(requestedIn, sourceFrameCount - 1).toInt();

    if (layer.sourceInFrame == requestedIn &&
        layer.sourceOutFrame == requestedOut) {
      return true;
    }

    final before = _captureEditState();
    final originalUndo = List<_ClipEditState>.from(_undoStack);
    final originalRedo = List<_ClipEditState>.from(_redoStack);
    final desiredLayers = List<_LayerEditState>.from(before.layers);
    final old = desiredLayers[layerIndex];

    desiredLayers[layerIndex] = _LayerEditState(
      present: old.present,
      path: old.path,
      startFrame: old.startFrame,
      endFrame: old.endFrame,
      sourceInFrame: requestedIn,
      sourceOutFrame: requestedOut,
      sourceFrameCount: old.sourceFrameCount,
      opacity: old.opacity,
      x: old.x,
      y: old.y,
      scale: old.scale,
      visible: old.visible,
      isStill: old.isStill,
      hasAlpha: old.hasAlpha,
      alphaMode: old.alphaMode,
      hasAudio: old.hasAudio,
      audioGain: old.audioGain,
    );

    final desired = _ClipEditState(
      trimInFrame: before.trimInFrame,
      trimOutFrame: before.trimOutFrame,
      inFrame: before.inFrame,
      outFrame: before.outFrame,
      layers: desiredLayers,
      visualOrder: before.visualOrder,
    );

    final basePath = _layers[_baseLayerIndex].path ?? media.path;

    _finishContinuousEditGroup();
    _restoringEditState = true;
    notifyListeners();

    try {
      if (!await _parkPlaybackForLayerChange()) {
        return false;
      }

      final playheadFrame = bridge.positionFrame;
      final restored = await _runWithFrozenPreview(
        () => _applyEditState(
          desired,
          basePath: basePath,
          playheadFrame: playheadFrame,
        ),
      );

      if (!restored) {
        final sourceError = _error;
        final rolledBack = await _runWithFrozenPreview(
          () => _applyEditState(
            before,
            basePath: basePath,
            playheadFrame: playheadFrame,
          ),
        );

        _undoStack
          ..clear()
          ..addAll(originalUndo);
        _redoStack
          ..clear()
          ..addAll(originalRedo);

        _error = rolledBack
            ? (sourceError ?? 'The layer source range could not be changed.')
            : 'Layer source trim failed and the previous composition could not be restored.';
        return false;
      }

      _syncLayerSourceRangeFromNative(layerIndex);
      _syncLayerTimingFromNative(layerIndex);
      final after = _captureEditState();

      _undoStack
        ..clear()
        ..addAll(originalUndo);
      _redoStack.clear();

      if (!before.sameAs(after)) {
        _undoStack.add(before);
      }

      _error = null;
      return true;
    } finally {
      _restoringEditState = false;
      notifyListeners();
    }
  }

  Future<bool> nudgeLayerSourceIn(int layerIndex, int deltaFrames) {
    final layer = layerState(layerIndex);
    final sourceIn = layer.sourceInFrame;
    final sourceOut = layer.sourceOutFrame;
    if (!layer.present || layer.isStill || sourceIn == null || sourceOut == null) {
      return Future<bool>.value(false);
    }

    final target = (sourceIn + deltaFrames).clamp(0, sourceOut).toInt();
    return setLayerSourceRange(
      layerIndex,
      sourceInFrame: target,
      sourceOutFrame: sourceOut,
    );
  }

  Future<bool> nudgeLayerSourceOut(int layerIndex, int deltaFrames) {
    final layer = layerState(layerIndex);
    final sourceIn = layer.sourceInFrame;
    final sourceOut = layer.sourceOutFrame;
    final sourceFrameCount = layer.sourceFrameCount;
    if (!layer.present ||
        layer.isStill ||
        sourceIn == null ||
        sourceOut == null ||
        sourceFrameCount == null ||
        sourceFrameCount <= 0) {
      return Future<bool>.value(false);
    }

    final target =
        (sourceOut + deltaFrames).clamp(sourceIn, sourceFrameCount - 1).toInt();
    return setLayerSourceRange(
      layerIndex,
      sourceInFrame: sourceIn,
      sourceOutFrame: target,
    );
  }

  void setLayerGeometry({
    required int layerIndex,
    required double x,
    required double y,
    required double scale,
    bool recordEdit = true,
  }) {
    switch (layerIndex) {
      case _secondaryLayerIndex:
        _setSecondaryLayerGeometry(
          x: x,
          y: y,
          scale: scale,
          recordEdit: recordEdit,
        );
        return;
      case _tertiaryLayerIndex:
        _setTertiaryLayerGeometry(
          x: x,
          y: y,
          scale: scale,
          recordEdit: recordEdit,
        );
        return;
    }
  }

  void setLayerX(int layerIndex, double value) {
    if (!hasLayer(layerIndex) || layerIndex == _baseLayerIndex) {
      return;
    }
    setLayerGeometry(
      layerIndex: layerIndex,
      x: value,
      y: _layers[layerIndex].y,
      scale: _layers[layerIndex].scale,
    );
  }

  void setLayerY(int layerIndex, double value) {
    if (!hasLayer(layerIndex) || layerIndex == _baseLayerIndex) {
      return;
    }
    setLayerGeometry(
      layerIndex: layerIndex,
      x: _layers[layerIndex].x,
      y: value,
      scale: _layers[layerIndex].scale,
    );
  }

  void setLayerScale(int layerIndex, double value) {
    if (!hasLayer(layerIndex) || layerIndex == _baseLayerIndex) {
      return;
    }
    setLayerGeometry(
      layerIndex: layerIndex,
      x: _layers[layerIndex].x,
      y: _layers[layerIndex].y,
      scale: value,
    );
  }

  void setLayerAnchor(int layerIndex, int anchor) {
    switch (layerIndex) {
      case _secondaryLayerIndex:
        _setSecondaryLayerAnchor(anchor);
        return;
      case _tertiaryLayerIndex:
        _setTertiaryLayerAnchor(anchor);
        return;
    }
  }

  void setLayerAlphaMode(
    int layerIndex,
    int mode, {
    bool recordEdit = true,
  }) {
    switch (layerIndex) {
      case _secondaryLayerIndex:
        _setSecondaryLayerAlphaMode(mode, recordEdit: recordEdit);
        return;
      case _tertiaryLayerIndex:
        _setTertiaryLayerAlphaMode(mode, recordEdit: recordEdit);
        return;
    }
  }

  void _setSecondaryLayerOpacity(
    double value, {
    bool recordEdit = true,
  }) {
    if (!hasLayer(_secondaryLayerIndex) || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();
    final before = recordEdit ? _captureEditState() : null;

    if (!_layers[_secondaryLayerIndex].visible) {
      _layers[_secondaryLayerIndex].opacity = requested;
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
      _layers[_secondaryLayerIndex].opacity =
          bridge.secondaryOpacity.clamp(0.0, 1.0).toDouble();
      notifyListeners();
      return;
    }

    _layers[_secondaryLayerIndex].opacity =
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
  /// requested opacity remains stored in _layers[_secondaryLayerIndex].opacity.
  void _setSecondaryLayerVisible(
    bool visible, {
    bool recordEdit = true,
  }) {
    if (!hasLayer(_secondaryLayerIndex) ||
        visible == _layers[_secondaryLayerIndex].visible ||
        (recordEdit && _restoringEditState)) {
      return;
    }

    final before = recordEdit ? _captureEditState() : null;
    final effectiveOpacity = visible ? _layers[_secondaryLayerIndex].opacity : 0.0;

    if (!bridge.setSecondaryOpacity(effectiveOpacity)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 2 visibility.'
          : bridge.lastError;
      notifyListeners();
      return;
    }

    _layers[_secondaryLayerIndex].visible = visible;
    _error = null;

    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }

    notifyListeners();
  }

  /// POC 10.8: move and uniformly scale Layer 2 without rebuilding the tractor.
  /// Coordinates are base-frame pixels measured from the top-left corner.
  void _setSecondaryLayerGeometry({
    required double x,
    required double y,
    required double scale,
    bool recordEdit = true,
  }) {
    if (!hasLayer(_secondaryLayerIndex) || (recordEdit && _restoringEditState)) {
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

  /// Anchor indices are row-major: 0 top-left through 8 bottom-right.
  void _setSecondaryLayerAnchor(int anchor) {
    if (!hasLayer(_secondaryLayerIndex) || _restoringEditState) {
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
    _layers[_secondaryLayerIndex].x = bridge.secondaryX;
    _layers[_secondaryLayerIndex].y = bridge.secondaryY;
    _layers[_secondaryLayerIndex].scale =
        bridge.secondaryScale.clamp(0.10, 3.0).toDouble();
  }

  /// POC 10.6: interpret layer 2 alpha without rebuilding the tractor.
  ///
  /// 0 = Auto/native decode, 1 = Straight/native decode,
  /// 2 = Premultiplied (native bridge unpremultiplies RGB before composite).
  void _setSecondaryLayerAlphaMode(
    int mode, {
    bool recordEdit = true,
  }) {
    if (!hasLayer(_secondaryLayerIndex) || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = mode.clamp(0, 2).toInt();
    final before = recordEdit ? _captureEditState() : null;

    if (!bridge.setSecondaryAlphaMode(requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change layer 2 alpha interpretation.'
          : bridge.lastError;
      _layers[_secondaryLayerIndex].alphaMode =
          bridge.secondaryAlphaMode.clamp(0, 2).toInt();
      notifyListeners();
      return;
    }

    _layers[_secondaryLayerIndex].alphaMode =
        bridge.secondaryAlphaMode.clamp(0, 2).toInt();
    _error = null;

    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }

    notifyListeners();
  }

  void _setTertiaryLayerOpacity(
    double value, {
    bool recordEdit = true,
  }) {
    if (!hasLayer(_tertiaryLayerIndex) || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = value.clamp(0.0, 1.0).toDouble();
    final before = recordEdit ? _captureEditState() : null;

    if (!_layers[_tertiaryLayerIndex].visible) {
      _layers[_tertiaryLayerIndex].opacity = requested;
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
      _layers[_tertiaryLayerIndex].opacity =
          bridge.layerOpacity(2).clamp(0.0, 1.0).toDouble();
      notifyListeners();
      return;
    }

    _layers[_tertiaryLayerIndex].opacity =
        bridge.layerOpacity(2).clamp(0.0, 1.0).toDouble();
    _error = null;
    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before, continuousKey: 'tertiary-opacity');
    }
    notifyListeners();
  }

  void _setTertiaryLayerVisible(
    bool visible, {
    bool recordEdit = true,
  }) {
    if (!hasLayer(_tertiaryLayerIndex) ||
        visible == _layers[_tertiaryLayerIndex].visible ||
        (recordEdit && _restoringEditState)) {
      return;
    }

    final before = recordEdit ? _captureEditState() : null;
    final effectiveOpacity = visible ? _layers[_tertiaryLayerIndex].opacity : 0.0;
    if (!bridge.setLayerOpacity(2, effectiveOpacity)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 3 visibility.'
          : bridge.lastError;
      notifyListeners();
      return;
    }

    _layers[_tertiaryLayerIndex].visible = visible;
    _error = null;
    if (before != null && !before.sameAs(_captureEditState())) {
      _recordEditBeforeChange(before);
    }
    notifyListeners();
  }

  void _setTertiaryLayerGeometry({
    required double x,
    required double y,
    required double scale,
    bool recordEdit = true,
  }) {
    if (!hasLayer(_tertiaryLayerIndex) || (recordEdit && _restoringEditState)) {
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

  void _setTertiaryLayerAnchor(int anchor) {
    if (!hasLayer(_tertiaryLayerIndex) || _restoringEditState) {
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
    _layers[_tertiaryLayerIndex].x = bridge.layerX(2);
    _layers[_tertiaryLayerIndex].y = bridge.layerY(2);
    _layers[_tertiaryLayerIndex].scale = bridge.layerScale(2).clamp(0.10, 3.0).toDouble();
  }

  void _setTertiaryLayerAlphaMode(
    int mode, {
    bool recordEdit = true,
  }) {
    if (!hasLayer(_tertiaryLayerIndex) || (recordEdit && _restoringEditState)) {
      return;
    }

    final requested = mode.clamp(0, 2).toInt();
    final before = recordEdit ? _captureEditState() : null;
    if (!bridge.setLayerAlphaMode(2, requested)) {
      _error = bridge.lastError.isEmpty
          ? 'MLT could not change Layer 3 alpha interpretation.'
          : bridge.lastError;
      _layers[_tertiaryLayerIndex].alphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();
      notifyListeners();
      return;
    }

    _layers[_tertiaryLayerIndex].alphaMode = bridge.layerAlphaMode(2).clamp(0, 2).toInt();
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
    if (trackIndex < 0 || trackIndex >= _layerSlotCount) {
      return false;
    }
    final layer = _layers[trackIndex];
    return layer.present && layer.hasAudio;
  }

  double trackAudioGain(int trackIndex) {
    if (trackIndex < 0 || trackIndex >= _layerSlotCount) {
      return 1.0;
    }
    return _layers[trackIndex].audioGain;
  }

  void _syncTrackAudioGain(int trackIndex) {
    if (trackIndex < 0 || trackIndex >= _layerSlotCount) {
      return;
    }

    _layers[trackIndex].audioGain =
        bridge.trackAudioGain(trackIndex).clamp(0.0, 1.0).toDouble();
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
    if (!_editStateTestMode) {
      bridge.shutdown();
    }
    super.dispose();
  }
}