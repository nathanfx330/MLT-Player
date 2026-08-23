// lib/services/mlt_layer_bridge.dart

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'mlt_bridge.dart';

typedef _PreviewUpdateNative = Int32 Function(Pointer<Void>);
typedef _PreviewUpdateDart = int Function(Pointer<Void>);


typedef _AddLayerWithStateNative = Int32 Function(
  Int32,
  Pointer<Utf8>,
  Int64,
  Double,
  Double,
  Double,
  Double,
  Int32,
  Double,
);
typedef _AddLayerWithStateDart = int Function(
  int,
  Pointer<Utf8>,
  int,
  double,
  double,
  double,
  double,
  int,
  double,
);

typedef _IndexedInt64Native = Int64 Function(Int32);
typedef _IndexedInt64Dart = int Function(int);

typedef _IndexedIntNative = Int32 Function(Int32);
typedef _IndexedIntDart = int Function(int);

typedef _IndexedDoubleNative = Double Function(Int32);
typedef _IndexedDoubleDart = double Function(int);

typedef _IndexedSetDoubleNative = Int32 Function(Int32, Double);
typedef _IndexedSetDoubleDart = int Function(int, double);

typedef _IndexedSetIntNative = Int32 Function(Int32, Int32);
typedef _IndexedSetIntDart = int Function(int, int);

typedef _IndexedGeometryNative = Int32 Function(
  Int32,
  Double,
  Double,
  Double,
);
typedef _IndexedGeometryDart = int Function(
  int,
  double,
  double,
  double,
);

/// Indexed composition-layer API introduced with the Layer 3 native graph.
///
/// Indices are stable and zero-based:
///   0 = Layer 1 / base
///   1 = Layer 2
///   2 = Layer 3
///
/// The existing MltBridge Layer-2 methods remain intact. This extension keeps
/// the new indexed ABI isolated so older bridge code does not need to be
/// rewritten just to expose Layer 3 to Dart.
extension MltLayerBridge on MltBridge {
  static final DynamicLibrary _library = DynamicLibrary.process();

  static final _PreviewUpdateDart _previewUpdateBegin =
      _library.lookupFunction<_PreviewUpdateNative, _PreviewUpdateDart>(
    'mlt_bridge_preview_update_begin',
  );

  static final _PreviewUpdateDart _previewUpdateEnd =
      _library.lookupFunction<_PreviewUpdateNative, _PreviewUpdateDart>(
    'mlt_bridge_preview_update_end',
  );


  static final _AddLayerWithStateDart _addLayerWithState =
      _library.lookupFunction<_AddLayerWithStateNative, _AddLayerWithStateDart>(
    'mlt_bridge_add_layer_with_state',
  );

  static final _IndexedInt64Dart _layerStartFrame =
      _library.lookupFunction<_IndexedInt64Native, _IndexedInt64Dart>(
    'mlt_bridge_layer_start_frame',
  );

  static final _IndexedSetDoubleDart _setLayerOpacity =
      _library.lookupFunction<_IndexedSetDoubleNative, _IndexedSetDoubleDart>(
    'mlt_bridge_set_layer_opacity',
  );

  static final _IndexedDoubleDart _layerOpacity =
      _library.lookupFunction<_IndexedDoubleNative, _IndexedDoubleDart>(
    'mlt_bridge_layer_opacity',
  );

  static final _IndexedGeometryDart _setLayerGeometry =
      _library.lookupFunction<_IndexedGeometryNative, _IndexedGeometryDart>(
    'mlt_bridge_set_layer_geometry',
  );

  static final _IndexedSetIntDart _setLayerAnchor =
      _library.lookupFunction<_IndexedSetIntNative, _IndexedSetIntDart>(
    'mlt_bridge_set_layer_anchor',
  );

  static final _IndexedDoubleDart _layerX =
      _library.lookupFunction<_IndexedDoubleNative, _IndexedDoubleDart>(
    'mlt_bridge_layer_x',
  );

  static final _IndexedDoubleDart _layerY =
      _library.lookupFunction<_IndexedDoubleNative, _IndexedDoubleDart>(
    'mlt_bridge_layer_y',
  );

  static final _IndexedDoubleDart _layerScale =
      _library.lookupFunction<_IndexedDoubleNative, _IndexedDoubleDart>(
    'mlt_bridge_layer_scale',
  );

  static final _IndexedIntDart _layerIsStill =
      _library.lookupFunction<_IndexedIntNative, _IndexedIntDart>(
    'mlt_bridge_layer_is_still',
  );

  static final _IndexedIntDart _layerHasAlpha =
      _library.lookupFunction<_IndexedIntNative, _IndexedIntDart>(
    'mlt_bridge_layer_has_alpha',
  );

  static final _IndexedSetIntDart _setLayerAlphaMode =
      _library.lookupFunction<_IndexedSetIntNative, _IndexedSetIntDart>(
    'mlt_bridge_set_layer_alpha_mode',
  );

  static final _IndexedIntDart _layerAlphaMode =
      _library.lookupFunction<_IndexedIntNative, _IndexedIntDart>(
    'mlt_bridge_layer_alpha_mode',
  );

  Pointer<Void> get _layerEnginePointer =>
      Pointer<Void>.fromAddress(engineAddress);

  bool beginPreviewUpdate() =>
      _previewUpdateBegin(_layerEnginePointer) != 0;

  bool endPreviewUpdate() =>
      _previewUpdateEnd(_layerEnginePointer) != 0;


  bool addLayerWithState(
    int layerIndex,
    String path, {
    required int startFrame,
    required double x,
    required double y,
    required double scale,
    required double opacity,
    required int alphaMode,
    required double audioGain,
  }) {
    final nativePath = path.toNativeUtf8();
    try {
      return _addLayerWithState(
            layerIndex,
            nativePath,
            startFrame,
            x,
            y,
            scale,
            opacity,
            alphaMode,
            audioGain,
          ) !=
          0;
    } finally {
      malloc.free(nativePath);
    }
  }

  int layerStartFrame(int layerIndex) => _layerStartFrame(layerIndex);

  bool setLayerOpacity(int layerIndex, double opacity) =>
      _setLayerOpacity(layerIndex, opacity) != 0;

  double layerOpacity(int layerIndex) => _layerOpacity(layerIndex);

  bool setLayerGeometry(
    int layerIndex,
    double x,
    double y,
    double scale,
  ) =>
      _setLayerGeometry(layerIndex, x, y, scale) != 0;

  bool setLayerAnchor(int layerIndex, int anchor) =>
      _setLayerAnchor(layerIndex, anchor) != 0;

  double layerX(int layerIndex) => _layerX(layerIndex);

  double layerY(int layerIndex) => _layerY(layerIndex);

  double layerScale(int layerIndex) => _layerScale(layerIndex);

  bool layerIsStill(int layerIndex) => _layerIsStill(layerIndex) != 0;

  bool layerHasAlpha(int layerIndex) => _layerHasAlpha(layerIndex) != 0;

  bool setLayerAlphaMode(int layerIndex, int mode) =>
      _setLayerAlphaMode(layerIndex, mode) != 0;

  int layerAlphaMode(int layerIndex) => _layerAlphaMode(layerIndex);
}

/// Restores Layer 3 on a helper isolate with its final state already installed
/// before native preview resumes. This keeps Undo from exposing intermediate
/// Layer-2-only/default-Layer-3 frames.
Future<bool> addLayerWithStateOnHelperIsolate(
  int engineAddress,
  int layerIndex,
  String path, {
  required int startFrame,
  required double x,
  required double y,
  required double scale,
  required double opacity,
  required int alphaMode,
  required double audioGain,
}) {
  return Isolate.run(() {
    final bridge = MltBridge.attach(engineAddress);
    return bridge.addLayerWithState(
      layerIndex,
      path,
      startFrame: startFrame,
      x: x,
      y: y,
      scale: scale,
      opacity: opacity,
      alphaMode: alphaMode,
      audioGain: audioGain,
    );
  });
}

