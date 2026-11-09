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
    this.error,
  });

  final String? redleafInstanceId;
  final String? redleafProjectPath;
  final String? error;

  static StartupProjectRequest parse(List<String> arguments) {
    String? instanceId;
    String? projectPath;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
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

    return StartupProjectRequest._(
      redleafInstanceId: instanceId,
      redleafProjectPath: projectPath,
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
