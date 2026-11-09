// lib/services/startup_project_request.dart

import '../models/workspace_project.dart';
import 'workspace_project_service.dart';

/// An optional project selection delivered to MLT Player at process startup.
/// It does not connect to Redleaf, generate an ID, or synchronize an archive.
class StartupProjectRequest {
  const StartupProjectRequest._({
    this.redleafInstanceId,
    this.error,
  });

  final String? redleafInstanceId;
  final String? error;

  static StartupProjectRequest parse(List<String> arguments) {
    String? selectedInstanceId;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      String? requestedId;

      if (argument == '--redleaf-project') {
        if (index + 1 >= arguments.length ||
            arguments[index + 1].startsWith('--')) {
          return const StartupProjectRequest._(
            error: 'The --redleaf-project option requires a Redleaf instance ID.',
          );
        }
        requestedId = arguments[++index];
      } else if (argument.startsWith('--redleaf-project=')) {
        requestedId = argument.substring('--redleaf-project='.length);
      } else {
        continue;
      }

      if (selectedInstanceId != null) {
        return const StartupProjectRequest._(
          error: 'Specify --redleaf-project only once.',
        );
      }

      var normalized = (requestedId ?? '').trim();
      if (normalized.startsWith('redleaf:')) {
        normalized = normalized.substring('redleaf:'.length).trim();
      }
      if (normalized.isEmpty) {
        return const StartupProjectRequest._(
          error: 'The --redleaf-project option requires a Redleaf instance ID.',
        );
      }
      selectedInstanceId = normalized;
    }

    return StartupProjectRequest._(redleafInstanceId: selectedInstanceId);
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
