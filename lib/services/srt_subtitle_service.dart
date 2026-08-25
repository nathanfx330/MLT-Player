// lib/services/srt_subtitle_service.dart

import 'dart:convert';
import 'dart:io';

class SubtitleCue {
  const SubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;

  bool isActiveAt(int positionMs) =>
      positionMs >= startMs && positionMs < endMs;
}

class SubtitleTrack {
  SubtitleTrack({
    required this.path,
    required List<SubtitleCue> cues,
  })  : cues = List<SubtitleCue>.unmodifiable(cues),
        _prefixMaxEnd = _buildPrefixMaxEnd(cues);

  final String path;
  final List<SubtitleCue> cues;
  final List<int> _prefixMaxEnd;

  bool get isEmpty => cues.isEmpty;
  bool get isNotEmpty => cues.isNotEmpty;

  String? textAt(int positionMs) {
    if (cues.isEmpty || positionMs < cues.first.startMs) {
      return null;
    }

    var low = 0;
    var high = cues.length - 1;
    var lastStarted = -1;

    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      if (cues[middle].startMs <= positionMs) {
        lastStarted = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }

    if (lastStarted < 0) {
      return null;
    }

    final active = <String>[];

    for (var index = lastStarted; index >= 0; index--) {
      if (_prefixMaxEnd[index] <= positionMs) {
        break;
      }

      final cue = cues[index];
      if (cue.isActiveAt(positionMs) && cue.text.isNotEmpty) {
        active.add(cue.text);
      }
    }

    if (active.isEmpty) {
      return null;
    }

    return active.reversed.join('\n');
  }

  static List<int> _buildPrefixMaxEnd(List<SubtitleCue> cues) {
    final result = List<int>.filled(cues.length, 0, growable: false);
    var maximum = 0;

    for (var index = 0; index < cues.length; index++) {
      if (cues[index].endMs > maximum) {
        maximum = cues[index].endMs;
      }
      result[index] = maximum;
    }

    return result;
  }
}

class SrtSubtitleService {
  const SrtSubtitleService._();

  static final RegExp _timingPattern = RegExp(
    r'^\s*(\d+):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*'
    r'(\d+):(\d{2}):(\d{2})[,.](\d{1,3})(?:\s+.*)?$',
  );

  static Future<SubtitleTrack?> loadForMedia(String mediaPath) async {
    final sidecar = await findSidecarForMedia(mediaPath);
    if (sidecar == null) {
      return null;
    }

    try {
      final bytes = await sidecar.readAsBytes();
      final source = _decode(bytes);
      final track = parse(source, path: sidecar.absolute.path);
      return track.isEmpty ? null : track;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Future<File?> findSidecarForMedia(String mediaPath) async {
    final media = File(mediaPath).absolute;
    final directory = media.parent;
    final mediaName = _basename(media.path);
    final stem = _stem(mediaName);

    final exact = File(_join(directory.path, '$stem.srt'));
    try {
      if (await exact.exists()) {
        return exact;
      }
    } on FileSystemException {
      return null;
    }

    // Linux paths are case-sensitive. Accept Movie.SRT for Movie.mp4 while
    // still requiring the complete media stem to match.
    final wanted = '$stem.srt'.toLowerCase();
    final matches = <File>[];

    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }

        if (_basename(entity.path).toLowerCase() == wanted) {
          matches.add(entity);
        }
      }
    } on FileSystemException {
      return null;
    }

    if (matches.isEmpty) {
      return null;
    }

    matches.sort((a, b) => a.path.compareTo(b.path));
    return matches.first;
  }

  static SubtitleTrack parse(
    String source, {
    String path = '',
  }) {
    final normalized = source
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();

    if (normalized.isEmpty) {
      return SubtitleTrack(path: path, cues: const <SubtitleCue>[]);
    }

    final blocks = normalized.split(RegExp(r'\n[ \t]*\n+'));
    final cues = <SubtitleCue>[];

    for (final block in blocks) {
      final lines = block.split('\n');
      if (lines.isEmpty) {
        continue;
      }

      var timingLineIndex = -1;
      RegExpMatch? timing;

      for (var index = 0; index < lines.length && index < 3; index++) {
        final match = _timingPattern.firstMatch(lines[index]);
        if (match != null) {
          timingLineIndex = index;
          timing = match;
          break;
        }
      }

      if (timingLineIndex < 0 || timing == null) {
        continue;
      }

      final startMs = _timestampToMs(
        timing.group(1)!,
        timing.group(2)!,
        timing.group(3)!,
        timing.group(4)!,
      );
      final endMs = _timestampToMs(
        timing.group(5)!,
        timing.group(6)!,
        timing.group(7)!,
        timing.group(8)!,
      );

      if (endMs <= startMs) {
        continue;
      }

      final text = _cleanText(lines.skip(timingLineIndex + 1).join('\n'));
      if (text.isEmpty) {
        continue;
      }

      cues.add(
        SubtitleCue(
          startMs: startMs,
          endMs: endMs,
          text: text,
        ),
      );
    }

    cues.sort((a, b) {
      final start = a.startMs.compareTo(b.startMs);
      return start != 0 ? start : a.endMs.compareTo(b.endMs);
    });

    return SubtitleTrack(path: path, cues: cues);
  }

  static int _timestampToMs(
    String hours,
    String minutes,
    String seconds,
    String fraction,
  ) {
    final h = int.parse(hours);
    final m = int.parse(minutes);
    final s = int.parse(seconds);
    final milliseconds = int.parse(fraction.padRight(3, '0').substring(0, 3));

    return (((h * 60) + m) * 60 + s) * 1000 + milliseconds;
  }

  static String _cleanText(String text) {
    var cleaned = text.trim();

    cleaned = cleaned.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\{\\[^}]+\}'), '');
    cleaned = cleaned.replaceAll(RegExp(r'<[^>]+>'), '');

    const entities = <String, String>{
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&nbsp;': ' ',
    };

    for (final entry in entities.entries) {
      cleaned = cleaned.replaceAll(entry.key, entry.value);
    }

    return cleaned
        .split('\n')
        .map((line) => line.trim())
        .join('\n')
        .trim();
  }

  static const List<int?> _windows1252ControlCodePoints = <int?>[
    0x20AC,
    null,
    0x201A,
    0x0192,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x02C6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    null,
    0x017D,
    null,
    null,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x02DC,
    0x2122,
    0x0161,
    0x203A,
    0x0153,
    null,
    0x017E,
    0x0178,
  ];

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return _decodeWindows1252(bytes) ?? latin1.decode(bytes);
    }
  }

  static String? _decodeWindows1252(List<int> bytes) {
    final codePoints = <int>[];

    for (final byte in bytes) {
      if (byte < 0 || byte > 0xFF) {
        return null;
      }

      if (byte >= 0x80 && byte <= 0x9F) {
        final mapped = _windows1252ControlCodePoints[byte - 0x80];
        if (mapped == null) {
          return null;
        }
        codePoints.add(mapped);
      } else {
        codePoints.add(byte);
      }
    }

    return String.fromCharCodes(codePoints);
  }

  static String _stem(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash == -1 ? normalized : normalized.substring(slash + 1);
  }

  static String _join(String directory, String child) {
    final separator = Platform.pathSeparator;
    return directory.endsWith(separator)
        ? '$directory$child'
        : '$directory$separator$child';
  }
}
