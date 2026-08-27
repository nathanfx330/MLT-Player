// lib/ui/widgets/workspace_project_switcher.dart

import 'package:flutter/material.dart';

import '../../models/workspace_project.dart';
import '../../services/workspace_project_service.dart';

class WorkspaceProjectSwitcher extends StatelessWidget {
  const WorkspaceProjectSwitcher({
    super.key,
    required this.service,
    required this.onSelected,
    this.enabled = true,
  });

  final WorkspaceProjectService service;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        if (!service.loaded) {
          return const _LoadingProjectLabel();
        }

        final projects = service.projects;
        final active = service.activeProject;

        if (projects.isEmpty || active == null) {
          return const _LoadingProjectLabel();
        }

        return DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: active.key,
            isExpanded: true,
            dropdownColor: const Color(0xFF252525),
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white70,
            ),
            selectedItemBuilder: (context) {
              return [
                for (final project in projects)
                  _SelectedProjectLabel(project: project),
              ];
            },
            items: [
              for (final project in projects)
                DropdownMenuItem<String>(
                  value: project.key,
                  child: _ProjectMenuLabel(project: project),
                ),
            ],
            onChanged: !enabled
                ? null
                : (value) {
                    if (value != null && value != active.key) {
                      onSelected(value);
                    }
                  },
          ),
        );
      },
    );
  }
}

class _SelectedProjectLabel extends StatelessWidget {
  const _SelectedProjectLabel({
    required this.project,
  });

  final WorkspaceProject project;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(
            project.isRedleaf
                ? Icons.cloud_outlined
                : Icons.folder_outlined,
            size: 14,
            color: project.isRedleaf
                ? const Color(0xFFE8A33D)
                : Colors.white38,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectMenuLabel extends StatelessWidget {
  const _ProjectMenuLabel({
    required this.project,
  });

  final WorkspaceProject project;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          project.isRedleaf
              ? Icons.cloud_outlined
              : Icons.folder_outlined,
          size: 16,
          color: project.isRedleaf
              ? const Color(0xFFE8A33D)
              : Colors.white38,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            project.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (project.isRedleaf) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              color: const Color(0x18E8A33D),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: const Color(0x44E8A33D),
              ),
            ),
            child: const Text(
              'REDLEAF',
              style: TextStyle(
                fontSize: 7.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.7,
                color: Color(0xFFE8A33D),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _LoadingProjectLabel extends StatelessWidget {
  const _LoadingProjectLabel();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.centerLeft,
      child: Text(
        'Loading Projects…',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: Colors.white38,
        ),
      ),
    );
  }
}
