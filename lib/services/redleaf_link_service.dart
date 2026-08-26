// lib/services/redleaf_link_service.dart

import 'dart:io';

class RedleafLink {
  const RedleafLink({
    required this.linkPath,
    required this.aliasName,
    required this.targetPath,
    required this.targetExists,
  });

  final String linkPath;
  final String aliasName;
  final String targetPath;
  final bool targetExists;

  bool containsPhysicalPath(String path) {
    final root = Directory(targetPath).absolute.path;
    final candidate = Directory(path).absolute.path;

    if (candidate == root) {
      return true;
    }

    final prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    return candidate.startsWith(prefix);
  }

  String virtualPathFor(String physicalPath) {
    final root = Directory(targetPath).absolute.path;
    final candidate = Directory(physicalPath).absolute.path;

    if (candidate == root) {
      return aliasName;
    }

    final prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';

    if (!candidate.startsWith(prefix)) {
      return aliasName;
    }

    final relative = candidate.substring(prefix.length);
    if (relative.isEmpty) {
      return aliasName;
    }

    return <String>[
      aliasName,
      ...relative
          .split(Platform.pathSeparator)
          .where((segment) => segment.isNotEmpty),
    ].join(' / ');
  }
}

class RedleafLinkService {
  static const String extension = '.rlink';

  bool isRlinkPath(String path) => path.toLowerCase().endsWith(extension);

  Future<RedleafLink> readLink(String linkPath) async {
    if (!isRlinkPath(linkPath)) {
      throw ArgumentError.value(
        linkPath,
        'linkPath',
        'Redleaf virtual folders must use the .rlink extension.',
      );
    }

    final linkFile = File(linkPath);
    if (!await linkFile.exists()) {
      throw FileSystemException('R.link file does not exist.', linkPath);
    }

    final target = (await linkFile.readAsString()).trim();
    if (target.isEmpty) {
      throw const FormatException('R.link target path is empty.');
    }

    final targetDirectory = Directory(target);
    final absoluteTarget = targetDirectory.absolute.path;

    return RedleafLink(
      linkPath: linkFile.absolute.path,
      aliasName: _basename(linkFile.path),
      targetPath: absoluteTarget,
      targetExists: await Directory(absoluteTarget).exists(),
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash == -1 ? normalized : normalized.substring(slash + 1);
  }
}
