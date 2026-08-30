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

class MltThumbnailBatchGenerationResult {
  const MltThumbnailBatchGenerationResult({
    required this.succeeded,
    required this.generatedCount,
    required this.error,
  });

  final bool succeeded;
  final int generatedCount;
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

typedef _GenerateThumbnailAtFrameNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Int64,
  Pointer<Int64>,
  Pointer<Utf8>,
  Int32,
);

typedef _GenerateThumbnailAtFrameDart = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  int,
  Pointer<Int64>,
  Pointer<Utf8>,
  int,
);

typedef _GenerateThumbnailFrameBatchNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Pointer<Int64>,
  Int32,
  Pointer<Int32>,
  Pointer<Utf8>,
  Int32,
);

typedef _GenerateThumbnailFrameBatchDart = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  Pointer<Int64>,
  int,
  Pointer<Int32>,
  Pointer<Utf8>,
  int,
);

class MltThumbnailBridge {
  MltThumbnailBridge() : _library = DynamicLibrary.process() {
    _generate = _library.lookupFunction<
      _GenerateThumbnailNative,
      _GenerateThumbnailDart
    >('mlt_thumbnail_generate');
    _generateAtFrame = _library.lookupFunction<
      _GenerateThumbnailAtFrameNative,
      _GenerateThumbnailAtFrameDart
    >('mlt_thumbnail_generate_at_frame');
    _generateFrameBatch = _library.lookupFunction<
      _GenerateThumbnailFrameBatchNative,
      _GenerateThumbnailFrameBatchDart
    >('mlt_thumbnail_generate_frame_batch');
  }

  static const int _errorCapacity = 512;

  final DynamicLibrary _library;
  late final _GenerateThumbnailDart _generate;
  late final _GenerateThumbnailAtFrameDart _generateAtFrame;
  late final _GenerateThumbnailFrameBatchDart _generateFrameBatch;

  MltThumbnailGenerationResult generate({
    required String sourcePath,
    required String outputPath,
    required int width,
    required int height,
  }) {
    return _invoke(
      sourcePath: sourcePath,
      outputPath: outputPath,
      width: width,
      height: height,
      requestedFrame: null,
    );
  }

  MltThumbnailGenerationResult generateAtFrame({
    required String sourcePath,
    required String outputPath,
    required int width,
    required int height,
    required int requestedFrame,
  }) {
    return _invoke(
      sourcePath: sourcePath,
      outputPath: outputPath,
      width: width,
      height: height,
      requestedFrame: requestedFrame,
    );
  }

  MltThumbnailBatchGenerationResult generateFrameBatch({
    required String sourcePath,
    required String outputDirectory,
    required int width,
    required int height,
    required List<int> requestedFrames,
  }) {
    if (requestedFrames.isEmpty) {
      return const MltThumbnailBatchGenerationResult(
        succeeded: true,
        generatedCount: 0,
        error: '',
      );
    }

    final source = sourcePath.toNativeUtf8();
    final outputDirectoryNative = outputDirectory.toNativeUtf8();
    final frames = calloc<Int64>(requestedFrames.length);
    final generatedCount = calloc<Int32>();
    final errorBytes = calloc<Uint8>(_errorCapacity);
    final error = errorBytes.cast<Utf8>();

    try {
      for (var index = 0; index < requestedFrames.length; index++) {
        frames[index] = requestedFrames[index];
      }

      final succeeded = _generateFrameBatch(
            source,
            outputDirectoryNative,
            width,
            height,
            frames,
            requestedFrames.length,
            generatedCount,
            error,
            _errorCapacity,
          ) !=
          0;

      return MltThumbnailBatchGenerationResult(
        succeeded: succeeded,
        generatedCount: generatedCount.value,
        error: error.toDartString(),
      );
    } finally {
      calloc.free(errorBytes);
      calloc.free(generatedCount);
      calloc.free(frames);
      calloc.free(outputDirectoryNative);
      calloc.free(source);
    }
  }

  MltThumbnailGenerationResult _invoke({
    required String sourcePath,
    required String outputPath,
    required int width,
    required int height,
    required int? requestedFrame,
  }) {
    final source = sourcePath.toNativeUtf8();
    final output = outputPath.toNativeUtf8();
    final selectedFrame = calloc<Int64>();
    final errorBytes = calloc<Uint8>(_errorCapacity);
    final error = errorBytes.cast<Utf8>();

    try {
      final succeeded = requestedFrame == null
          ? _generate(
                source,
                output,
                width,
                height,
                selectedFrame,
                error,
                _errorCapacity,
              ) !=
              0
          : _generateAtFrame(
                source,
                output,
                width,
                height,
                requestedFrame,
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

Future<MltThumbnailGenerationResult> generateMltThumbnailAtFrame({
  required String sourcePath,
  required String outputPath,
  required int width,
  required int height,
  required int requestedFrame,
}) async {
  final payload = await Isolate.run<Map<String, Object?>>(() {
    final result = MltThumbnailBridge().generateAtFrame(
      sourcePath: sourcePath,
      outputPath: outputPath,
      width: width,
      height: height,
      requestedFrame: requestedFrame,
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

Future<MltThumbnailBatchGenerationResult> generateMltThumbnailFrameBatch({
  required String sourcePath,
  required String outputDirectory,
  required int width,
  required int height,
  required List<int> requestedFrames,
}) async {
  if (requestedFrames.isEmpty) {
    return const MltThumbnailBatchGenerationResult(
      succeeded: true,
      generatedCount: 0,
      error: '',
    );
  }

  final immutableFrames = List<int>.from(requestedFrames, growable: false);
  final payload = await Isolate.run<Map<String, Object?>>(() {
    final result = MltThumbnailBridge().generateFrameBatch(
      sourcePath: sourcePath,
      outputDirectory: outputDirectory,
      width: width,
      height: height,
      requestedFrames: immutableFrames,
    );

    return <String, Object?>{
      'succeeded': result.succeeded,
      'generatedCount': result.generatedCount,
      'error': result.error,
    };
  });

  return MltThumbnailBatchGenerationResult(
    succeeded: payload['succeeded'] == true,
    generatedCount: payload['generatedCount'] as int? ?? 0,
    error: payload['error'] as String? ?? '',
  );
}
