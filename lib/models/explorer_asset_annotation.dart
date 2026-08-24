// lib/models/explorer_asset_annotation.dart

class ExplorerAssetAnnotation {
  const ExplorerAssetAnnotation({
    this.rating = 0,
    this.tags = const <String>[],
  });

  static const ExplorerAssetAnnotation empty = ExplorerAssetAnnotation();

  final int rating;
  final List<String> tags;

  bool get isEmpty => rating == 0 && tags.isEmpty;

  ExplorerAssetAnnotation copyWith({
    int? rating,
    List<String>? tags,
  }) {
    return ExplorerAssetAnnotation(
      rating: rating ?? this.rating,
      tags: tags ?? this.tags,
    );
  }
}
