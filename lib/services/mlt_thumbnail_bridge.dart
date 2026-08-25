// lib/services/mlt_thumbnail_bridge.dart

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class MltThumbnailGenerationResult {
  const MltThumbnailGenerationResult({
    required this.succeeded,
    required this.selectedFrame,
    required this.error,
  });

  final bool succeeded;
  final int selectedFrame;
  final String error;
}

typedef _GenerateThumbnailNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Pointer<Int64>,
  Pointer<Utf8>,
  Int32,
);

typedef _GenerateThumbnailDart = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  Pointer<Int64>,
  Pointer<Utf8>,
  int,
);

class MltThumbnailBridge {
  MltThumbnailBridge()
      : _library = DynamicLibrary.process() {
    _generate = _library.lookupFunction<
        _GenerateThumbnailNative,
        _GenerateThumbnailDart>('mlt_thumbnail_generate');
  }

  static const int _errorCapacity = 512;

  final DynamicLibrary _library;
  late final _GenerateThumbnailDart _generate;

  MltThumbnailGenerationResult generate({
    required String sourcePath,
    required String outputPath,
    required int width,
    required int height,
  }) {
    final source = sourcePath.toNativeUtf8();
    final output = outputPath.toNativeUtf8();
    final selectedFrame = calloc<Int64>();
    final errorBytes = calloc<Uint8>(_errorCapacity);
    final error = errorBytes.cast<Utf8>();

    try {
      final succeeded = _generate(
            source,
            output,
            width,
            height,
            selectedFrame,
            error,
            _errorCapacity,
          ) !=
          0;

      return MltThumbnailGenerationResult(
        succeeded: succeeded,
        selectedFrame: selectedFrame.value,
        error: error.toDartString(),
      );
    } finally {
      calloc.free(errorBytes);
      calloc.free(selectedFrame);
      calloc.free(output);
      calloc.free(source);
    }
  }
}

Future<MltThumbnailGenerationResult> generateMltThumbnail({
  required String sourcePath,
  required String outputPath,
  required int width,
  required int height,
}) async {
  final payload = await Isolate.run<Map<String, Object?>>(() {
    final result = MltThumbnailBridge().generate(
      sourcePath: sourcePath,
      outputPath: outputPath,
      width: width,
      height: height,
    );

    return <String, Object?>{
      'succeeded': result.succeeded,
      'selectedFrame': result.selectedFrame,
      'error': result.error,
    };
  });

  return MltThumbnailGenerationResult(
    succeeded: payload['succeeded'] == true,
    selectedFrame: payload['selectedFrame'] as int? ?? -1,
    error: payload['error'] as String? ?? '',
  );
}
