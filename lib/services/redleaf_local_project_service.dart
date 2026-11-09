// lib/services/redleaf_local_project_service.dart

import 'dart:io';

/// Reads a local Redleaf database identity without starting its Flask server.
///
/// Uses Python's standard SQLite library, already required by Redleaf.
/// The database is opened read-only; no Redleaf project data is modified.
class RedleafLocalProjectService {
  static const String _readIdentityScript = r'''
import sqlite3
import sys
from pathlib import Path

database = Path(sys.argv[1]).resolve()
try:
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    try:
        row = connection.execute(
            "SELECT value FROM app_settings WHERE key = ?",
            ("instance_id",)
        ).fetchone()
        print(str(row[0]) if row and row[0] is not None else "")
    finally:
        connection.close()
except sqlite3.Error as error:
    print(error, file=sys.stderr)
    sys.exit(2)
''';

  Future<RedleafLocalProjectIdentity> read(String rawProjectPath) async {
    final path = rawProjectPath.trim();
    if (path.isEmpty) {
      throw const RedleafLocalProjectException(
        'Select a Redleaf project folder.',
      );
    }

    final folder = Directory(path).absolute;
    if (!await folder.exists()) {
      throw RedleafLocalProjectException(
        'The Redleaf project folder does not exist: ${folder.path}',
      );
    }

    final database = File('${folder.path}/knowledge_base.db');
    if (!await database.exists()) {
      throw RedleafLocalProjectException(
        'No knowledge_base.db was found in ${folder.path}. '
        'Open an initialized Redleaf project folder.',
      );
    }

    ProcessResult result;
    try {
      result = await Process.run(
        'python3',
        <String>['-c', _readIdentityScript, database.path],
      );
    } on ProcessException {
      throw const RedleafLocalProjectException(
        'Python 3 is required to read a local Redleaf project.',
      );
    }

    if (result.exitCode != 0) {
      throw RedleafLocalProjectException(
        'Could not read the Redleaf project database: '
        '${result.stderr.toString().trim()}',
      );
    }

    final instanceId = result.stdout.toString().trim();
    if (instanceId.isEmpty) {
      throw const RedleafLocalProjectException(
        'This Redleaf database has no instance ID yet. '
        'Initialize it through Redleaf once, then launch it offline.',
      );
    }
    if (instanceId.contains('\n') || instanceId.contains('\r')) {
      throw const RedleafLocalProjectException(
        'The Redleaf database has an invalid instance ID.',
      );
    }

    final normalizedFolder = folder.path.replaceFirst(RegExp(r'[/\\]+$'), '');
    final name = normalizedFolder.split(Platform.pathSeparator).last;

    return RedleafLocalProjectIdentity(
      instanceId: instanceId,
      projectName: name.isEmpty ? 'Redleaf' : name,
    );
  }
}

class RedleafLocalProjectIdentity {
  const RedleafLocalProjectIdentity({
    required this.instanceId,
    required this.projectName,
  });

  final String instanceId;
  final String projectName;
}

class RedleafLocalProjectException implements Exception {
  const RedleafLocalProjectException(this.message);

  final String message;

  @override
  String toString() => message;
}
