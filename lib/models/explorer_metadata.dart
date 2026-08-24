// lib/models/explorer_metadata.dart

class ExplorerMetadata {
  const ExplorerMetadata({
    required this.modified,
    this.byteSize,
    this.pixelWidth,
    this.pixelHeight,
  });

  final DateTime modified;
  final int? byteSize;
  final int? pixelWidth;
  final int? pixelHeight;

  bool get hasDimensions =>
      pixelWidth != null && pixelWidth! > 0 &&
      pixelHeight != null && pixelHeight! > 0;
}
