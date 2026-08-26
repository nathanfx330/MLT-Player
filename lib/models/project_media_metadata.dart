// lib/models/project_media_metadata.dart

class ProjectMediaMetadata {
  const ProjectMediaMetadata({
    this.rating = 0,
    this.tags = const <String>[],
    this.colorHex,
    this.bookmarkFrames = const <int>[],
  });

  static const ProjectMediaMetadata empty = ProjectMediaMetadata();

  final int rating;
  final List<String> tags;
  final String? colorHex;
  final List<int> bookmarkFrames;

  bool get isEmpty =>
      rating == 0 &&
      tags.isEmpty &&
      colorHex == null &&
      bookmarkFrames.isEmpty;

  ProjectMediaMetadata copyWith({
    int? rating,
    List<String>? tags,
    String? colorHex,
    bool clearColor = false,
    List<int>? bookmarkFrames,
  }) {
    return ProjectMediaMetadata(
      rating: rating ?? this.rating,
      tags: tags ?? this.tags,
      colorHex: clearColor ? null : (colorHex ?? this.colorHex),
      bookmarkFrames: bookmarkFrames ?? this.bookmarkFrames,
    );
  }
}
