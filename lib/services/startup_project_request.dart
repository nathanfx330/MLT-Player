// lib/services/startup_project_request.dart

import '../models/workspace_project.dart';
import 'redleaf_local_project_service.dart';
import 'workspace_project_service.dart';

/// An optional project selection delivered to MLT Player at process startup.
/// It does not connect to Redleaf, generate an ID, or synchronize an archive.
class StartupProjectRequest {
  const StartupProjectRequest._({
    this.redleafInstanceId,
    this.redleafProjectPath,
    this.hubProjectPath,
    this.hubServerUrl,
    this.error,
  });

  final String? redleafInstanceId;
  final String? redleafProjectPath;
  /// A Hub launch checks the saved snapshot and onboards unsynced projects.
  /// This is deliberately separate from the offline --redleaf-project-path.
  final String? hubProjectPath;
  final String? hubServerUrl;
  final String? error;

  static StartupProjectRequest parse(List<String> arguments) {
    String? instanceId;
    String? projectPath;
    String? hubPath;
    String? hubUrl;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      final isHubPath = argument == '--redleaf-hub-project-path' ||
          argument.startsWith('--redleaf-hub-project-path=');
      final isHubUrl = argument == '--redleaf-hub-server-url' ||
          argument.startsWith('--redleaf-hub-server-url=');

      if (isHubPath || isHubUrl) {
        final flag = isHubPath
            ? '--redleaf-hub-project-path'
            : '--redleaf-hub-server-url';
        if ((isHubPath && hubPath != null) ||
            (isHubUrl && hubUrl != null)) {
          return const StartupProjectRequest._(
            error: 'Duplicate Redleaf Hub launch option.',
          );
        }

        String value;
        if (argument == flag) {
          if (index + 1 >= arguments.length ||
              arguments[index + 1].startsWith('--')) {
            return const StartupProjectRequest._(
              error: 'The Redleaf Hub launch option requires a value.',
            );
          }
          value = arguments[++index];
        } else {
          value = argument.substring(flag.length + 1);
        }
        value = value.trim();
        if (value.isEmpty) {
          return const StartupProjectRequest._(
            error: 'The Redleaf Hub launch option requires a value.',
          );
        }
        if (isHubPath) {
          hubPath = value;
        } else {
          final url = Uri.tryParse(value);
          if (url == null ||
              (url.scheme != 'http' && url.scheme != 'https') ||
              url.host.isEmpty ||
              url.userInfo.isNotEmpty ||
              url.hasQuery ||
              url.hasFragment) {
            return const StartupProjectRequest._(
              error: 'The Redleaf Hub server URL must be an HTTP or HTTPS address.',
            );
          }
          hubUrl = value;
        }
        continue;
      }
      final isId = argument == '--redleaf-project' ||
          argument.startsWith('--redleaf-project=');
      final isPath = argument == '--redleaf-project-path' ||
          argument.startsWith('--redleaf-project-path=');

      if (!isId && !isPath) continue;
      if (instanceId != null || projectPath != null) {
        return const StartupProjectRequest._(
          error: 'Specify only one Redleaf project at startup.',
        );
      }

      String value;
      if (argument == '--redleaf-project' ||
          argument == '--redleaf-project-path') {
        if (index + 1 >= arguments.length ||
            arguments[index + 1].startsWith('--')) {
          return const StartupProjectRequest._(
            error: 'The Redleaf project launch option requires a value.',
          );
        }
        value = arguments[++index];
      } else {
        value = argument.substring(argument.indexOf('=') + 1);
      }

      var normalized = value.trim();
      if (isId && normalized.startsWith('redleaf:')) {
        normalized = normalized.substring('redleaf:'.length).trim();
      }
      if (normalized.isEmpty) {
        return const StartupProjectRequest._(
          error: 'The Redleaf project launch option requires a value.',
        );
      }

      if (isPath) {
        projectPath = normalized;
      } else {
        instanceId = normalized;
      }
    }

    if (hubPath != null && (instanceId != null || projectPath != null)) {
      return const StartupProjectRequest._(
        error: 'Specify only one Redleaf project launch mode.',
      );
    }
    if (hubUrl != null && hubPath == null) {
      return const StartupProjectRequest._(
        error: 'A Hub server URL requires a Hub project path.',
      );
    }

    return StartupProjectRequest._(
      redleafInstanceId: instanceId,
      redleafProjectPath: projectPath,
      hubProjectPath: hubPath,
      hubServerUrl: hubUrl,
    );
  }

  /// Resolve a local folder offline and register its existing database
  /// identity in MLT Player without making any Redleaf server requests.
  Future<String?> applyTo(
    WorkspaceProjectService workspace, {
    RedleafLocalProjectService? localProjects,
  }) async {
    if (error != null) return error;
    final path = redleafProjectPath;
    if (path == null) return selectIn(workspace);

    if (!workspace.loaded) {
      return 'Could not load MLT Player projects for the Redleaf Hub launch.';
    }

    try {
      final identity =
          await (localProjects ?? RedleafLocalProjectService()).read(path);
      await workspace.selectLocalRedleafProject(
        instanceId: identity.instanceId,
        suggestedName: identity.projectName,
      );
      return null;
    } on RedleafLocalProjectException catch (failure) {
      return failure.message;
    } catch (failure) {
      return 'Could not open the Redleaf project: $failure';
    }
  }

  /// Returns an error message if the identity is invalid or not registered.
  /// Otherwise selects only the matching persisted Redleaf workspace.
  String? selectIn(WorkspaceProjectService workspace) {
    if (error != null) return error;

    final instanceId = redleafInstanceId;
    if (instanceId == null) return null;
    if (!workspace.loaded) {
      return 'Could not load MLT Player projects for the Redleaf Hub launch.';
    }

    final key = WorkspaceProject.redleafKey(instanceId);
    final isSaved = workspace.projects.any(
      (project) => project.isRedleaf && project.key == key,
    );
    if (!isSaved) {
      return 'Redleaf project "$instanceId" is not saved in MLT Player. '
          'Connect to it once from MLT Player Settings, then try again.';
    }

    workspace.select(key);
    return null;
  }
}
