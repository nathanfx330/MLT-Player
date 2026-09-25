// lib/models/project_media_metadata.dart

class ProjectMediaMetadata {
  const ProjectMediaMetadata({
    this.rating = 0,
    this.tags = const <String>[],
    this.colorHex,
    this.bookmarkFrames = const <int>[],
    this.bookmarkHighlightCueStartMs = const <int, int>{},
  });

  static const ProjectMediaMetadata empty = ProjectMediaMetadata();

  final int rating;
  final List<String> tags;
  final String? colorHex;
  final List<int> bookmarkFrames;
  final Map<int, int> bookmarkHighlightCueStartMs;

  bool get isEmpty =>
      rating == 0 &&
      tags.isEmpty &&
      colorHex == null &&
      bookmarkFrames.isEmpty &&
      bookmarkHighlightCueStartMs.isEmpty;

  ProjectMediaMetadata copyWith({
    int? rating,
    List<String>? tags,
    String? colorHex,
    bool clearColor = false,
    List<int>? bookmarkFrames,
    Map<int, int>? bookmarkHighlightCueStartMs,
  }) {
    return ProjectMediaMetadata(
      rating: rating ?? this.rating,
      tags: tags ?? this.tags,
      colorHex: clearColor ? null : (colorHex ?? this.colorHex),
      bookmarkFrames: bookmarkFrames ?? this.bookmarkFrames,
      bookmarkHighlightCueStartMs:
          bookmarkHighlightCueStartMs ?? this.bookmarkHighlightCueStartMs,
    );
  }
}
