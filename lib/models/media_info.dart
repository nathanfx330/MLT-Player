// lib/models/media_info.dart

class SourceTimecode {
  const SourceTimecode._({
    required this.raw,
    required this.startFrame,
    required this.nominalFps,
    required this.dropFrame,
  });

  final String raw;
  final int startFrame;
  final int nominalFps;
  final bool dropFrame;

  static SourceTimecode? tryParse(String value, double fps) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || fps <= 0) {
      return null;
    }

    final match = RegExp(
      r'^(\d{1,2}):(\d{2}):(\d{2})([:;])(\d{2})$',
    ).firstMatch(trimmed);

    if (match == null) {
      return null;
    }

    final hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    final separator = match.group(4)!;
    final frames = int.parse(match.group(5)!);

    final nominal = fps.round();
    if (minutes > 59 ||
        seconds > 59 ||
        nominal <= 0 ||
        frames >= nominal) {
      return null;
    }

    final drop =
        separator == ';' &&
        ((fps - (30000 / 1001)).abs() < 0.02 ||
            (fps - (60000 / 1001)).abs() < 0.02);

    var start =
        ((hours * 3600 + minutes * 60 + seconds) * nominal) + frames;

    if (drop) {
      final dropFrames = nominal == 60 ? 4 : 2;
      final totalMinutes = hours * 60 + minutes;
      start -= dropFrames * (totalMinutes - (totalMinutes ~/ 10));
    }

    return SourceTimecode._(
      raw: trimmed,
      startFrame: start,
      nominalFps: nominal,
      dropFrame: drop,
    );
  }

  String atOffset(int frameOffset) {
    final frameNumber = startFrame + frameOffset;

    if (!dropFrame) {
      return _formatNonDrop(frameNumber);
    }

    return _formatDrop(frameNumber);
  }

  String _formatNonDrop(int frameNumber) {
    final framesPer24Hours = nominalFps * 60 * 60 * 24;
    var value = frameNumber % framesPer24Hours;
    if (value < 0) {
      value += framesPer24Hours;
    }

    final hours = value ~/ (nominalFps * 3600);
    value %= nominalFps * 3600;
    final minutes = value ~/ (nominalFps * 60);
    value %= nominalFps * 60;
    final seconds = value ~/ nominalFps;
    final frames = value % nominalFps;

    return _compose(hours, minutes, seconds, frames, ':');
  }

  String _formatDrop(int frameNumber) {
    final dropFrames = nominalFps == 60 ? 4 : 2;
    final framesPerHour = nominalFps * 3600 - dropFrames * 54;
    final framesPer24Hours = framesPerHour * 24;
    final framesPer10Minutes = nominalFps * 600 - dropFrames * 9;
    final framesPerMinute = nominalFps * 60 - dropFrames;

    var value = frameNumber % framesPer24Hours;
    if (value < 0) {
      value += framesPer24Hours;
    }

    final tenMinuteBlocks = value ~/ framesPer10Minutes;
    final remainder = value % framesPer10Minutes;

    value += dropFrames * 9 * tenMinuteBlocks;
    if (remainder > dropFrames) {
      value += dropFrames * ((remainder - dropFrames) ~/ framesPerMinute);
    }

    final hours = value ~/ (nominalFps * 3600);
    value %= nominalFps * 3600;
    final minutes = value ~/ (nominalFps * 60);
    value %= nominalFps * 60;
    final seconds = value ~/ nominalFps;
    final frames = value % nominalFps;

    return _compose(hours, minutes, seconds, frames, ';');
  }

  static String _compose(
    int hours,
    int minutes,
    int seconds,
    int frames,
    String frameSeparator,
  ) {
    final hh = hours.toString().padLeft(2, '0');
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    final ff = frames.toString().padLeft(2, '0');

    return '$hh:$mm:$ss$frameSeparator$ff';
  }
}

class StreamInfo {
  const StreamInfo({
    required this.index,
    required this.type,
    required this.codecName,
    required this.codecLongName,
    required this.language,
    required this.channels,
    required this.sampleRate,
    required this.width,
    required this.height,
    required this.bitRate,
    required this.selected,
  });

  final int index;
  final String type;
  final String codecName;
  final String codecLongName;
  final String language;
  final int channels;
  final int sampleRate;
  final int width;
  final int height;
  final int bitRate;
  final bool selected;

  String get typeLabel {
    if (type.isEmpty || type == 'other') {
      return 'Other';
    }
    return '${type[0].toUpperCase()}${type.substring(1)}';
  }

  String? get codecLabel => MediaInfo._codecLabel(codecName, codecLongName);

  String get detailLabel {
    final parts = <String>[];

    if (codecLabel != null) {
      parts.add(codecLabel!);
    }
    if (width > 0 && height > 0) {
      parts.add('$width x $height');
    }
    if (channels > 0) {
      parts.add('$channels ch');
    }
    if (sampleRate > 0) {
      final khz = sampleRate / 1000.0;
      final text = khz == khz.roundToDouble()
          ? khz.toStringAsFixed(0)
          : khz.toStringAsFixed(1);
      parts.add('$text kHz');
    }
    if (bitRate > 0) {
      if (bitRate >= 1000000) {
        parts.add('${(bitRate / 1000000.0).toStringAsFixed(2)} Mb/s');
      } else {
        parts.add('${(bitRate / 1000.0).toStringAsFixed(0)} kb/s');
      }
    }
    if (language.isNotEmpty) {
      parts.add(language.toUpperCase());
    }
    if (selected) {
      parts.add('Selected');
    }

    return parts.isEmpty ? 'No additional metadata' : parts.join('  ·  ');
  }
}

class MediaInfo {
  const MediaInfo({
    required this.path,
    required this.width,
    required this.height,
    required this.displayAspect,
    required this.fps,
    required this.frames,
    required this.durationMs,
    required this.fileSizeBytes,
    required this.hasAudio,
    required this.isStill,
    required this.streamCount,
    required this.streams,
    required this.videoStreamIndex,
    required this.audioStreamIndex,
    required this.videoCodecName,
    required this.videoCodecLongName,
    required this.audioCodecName,
    required this.audioCodecLongName,
    required this.videoPixelFormat,
    required this.videoColorspace,
    required this.videoColorTrc,
    required this.videoColorRange,
    required this.sourceTimecode,
  });

  final String path;
  final int width;
  final int height;
  final double displayAspect;
  final double fps;
  final int frames;
  final int durationMs;
  final int fileSizeBytes;
  final bool hasAudio;
  final bool isStill;
  final int streamCount;
  final List<StreamInfo> streams;
  final int videoStreamIndex;
  final int audioStreamIndex;
  final String videoCodecName;
  final String videoCodecLongName;
  final String audioCodecName;
  final String audioCodecLongName;
  final String videoPixelFormat;
  final int videoColorspace;
  final int videoColorTrc;
  final String videoColorRange;
  final SourceTimecode? sourceTimecode;

  String? get videoCodecLabel =>
      _codecLabel(videoCodecName, videoCodecLongName);

  String? get audioCodecLabel =>
      _codecLabel(audioCodecName, audioCodecLongName);

  static String? _codecLabel(String shortName, String longName) {
    if (longName.isNotEmpty && shortName.isNotEmpty && longName != shortName) {
      return '$longName ($shortName)';
    }
    if (longName.isNotEmpty) {
      return longName;
    }
    if (shortName.isNotEmpty) {
      return shortName;
    }
    return null;
  }

  String? get videoColorspaceLabel {
    switch (videoColorspace) {
      case 240:
        return 'SMPTE ST240';
      case 601:
        return 'ITU-R BT.601';
      case 709:
        return 'ITU-R BT.709';
      case 9:
      case 10:
      case 2020:
      case 2021:
        return 'ITU-R BT.2020';
      default:
        return videoColorspace >= 0 ? 'Unknown ($videoColorspace)' : null;
    }
  }

  String? get videoColorTrcLabel {
    switch (videoColorTrc) {
      case 0:
        return 'N/A';
      case 1:
        return 'ITU-R BT.709';
      case 6:
        return 'ITU-R BT.601';
      case 7:
        return 'SMPTE ST240';
      case 11:
        return 'IEC 61966-2-4';
      case 13:
        return 'sRGB';
      case 14:
      case 15:
        return 'ITU-R BT.2020';
      case 16:
        return 'SMPTE ST2084 (PQ)';
      case 17:
        return 'SMPTE ST428';
      case 18:
        return 'ARIB B67 (HLG)';
      default:
        return videoColorTrc >= 0 ? 'Unknown ($videoColorTrc)' : null;
    }
  }

  String? get dataSizeLabel {
    if (fileSizeBytes <= 0) {
      return null;
    }

    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double value = fileSizeBytes.toDouble();
    var unitIndex = 0;

    while (value >= 1000.0 && unitIndex < units.length - 1) {
      value /= 1000.0;
      unitIndex++;
    }

    final decimals = unitIndex == 0 ? 0 : (value >= 100.0 ? 0 : 1);
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  String? get averageDataRateLabel {
    if (fileSizeBytes <= 0 || durationMs <= 0) {
      return null;
    }

    final bitsPerSecond =
        (fileSizeBytes * 8.0) / (durationMs / 1000.0);

    if (bitsPerSecond >= 1000000000.0) {
      return '${(bitsPerSecond / 1000000000.0).toStringAsFixed(2)} Gb/s';
    }
    if (bitsPerSecond >= 1000000.0) {
      return '${(bitsPerSecond / 1000000.0).toStringAsFixed(1)} Mb/s';
    }
    if (bitsPerSecond >= 1000.0) {
      return '${(bitsPerSecond / 1000.0).toStringAsFixed(1)} kb/s';
    }
    return '${bitsPerSecond.toStringAsFixed(0)} b/s';
  }

  String get name {
    final normalised = path.replaceAll('\\', '/');
    final slash = normalised.lastIndexOf('/');
    return slash == -1 ? normalised : normalised.substring(slash + 1);
  }

  bool get hasVideo => width > 0 && height > 0;

  /// Pixel dimensions divided by display aspect tells you whether the
  /// source is anamorphic, which the viewport has to correct for.
  bool get isAnamorphic {
    if (!hasVideo || displayAspect <= 0) {
      return false;
    }
    final pixelAspect = width / height;
    return (pixelAspect - displayAspect).abs() > 0.01;
  }

  double get viewportAspect {
    if (displayAspect > 0) {
      return displayAspect;
    }
    if (hasVideo) {
      return width / height;
    }
    return 16 / 9;
  }
}
