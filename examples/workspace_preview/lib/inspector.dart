import 'package:flutter/material.dart';

/// Presentation-only values keep widget tests independent of a Wayland socket.
@immutable
class EntryView {
  EntryView({
    required this.objectId,
    this.id,
    this.name,
    List<int> coordinates = const [],
    this.isActive = false,
    this.isUrgent = false,
    this.isHidden = false,
    this.canActivate = false,
    this.canDeactivate = false,
    this.canRemove = false,
    this.canAssign = false,
    this.groupId,
    this.activationToken,
  }) : coordinates = List.unmodifiable(coordinates);

  final int objectId;
  final String? id;
  final String? name;
  final List<int> coordinates;
  final bool isActive, isUrgent, isHidden;
  final bool canActivate, canDeactivate, canRemove, canAssign;
  final int? groupId;

  /// Opaque originating snapshot identity, never resolved from a session ID.
  final Object? activationToken;
}

@immutable
class GroupView {
  GroupView({
    required this.objectId,
    List<String> outputs = const [],
    this.canCreateWorkspace = false,
  }) : outputs = List.unmodifiable(outputs);

  final int objectId;
  final List<String> outputs;
  final bool canCreateWorkspace;
}

class WorkspaceInspector extends StatelessWidget {
  const WorkspaceInspector({
    super.key,
    required this.entries,
    required this.groups,
    required this.status,
    required this.connected,
    required this.onActivate,
    required this.onReconnect,
    required this.onQuit,
    this.error,
    this.notice,
    this.pending = const {},
  });

  final List<EntryView> entries;
  final List<GroupView> groups;
  final String status;
  final bool connected;
  final String? error, notice;
  final Set<int> pending;
  final ValueChanged<EntryView> onActivate;
  final VoidCallback onReconnect, onQuit;

  @override
  Widget build(BuildContext context) {
    final groupIds = groups.map((group) => group.objectId).toSet();
    final unassigned = entries
        .where((entry) => !groupIds.contains(entry.groupId))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspace preview'),
        actions: [
          IconButton(
            tooltip: 'Reconnect',
            onPressed: onReconnect,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Quit',
            onPressed: onQuit,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                avatar: Icon(
                  connected ? Icons.check_circle_outline : Icons.info_outline,
                  size: 18,
                ),
                label: Text(status),
              ),
              if (connected)
                Text(
                  '${entries.length} ${entries.length == 1 ? 'workspace' : 'workspaces'} · '
                  '${groups.length} ${groups.length == 1 ? 'group' : 'groups'}',
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Active is compositor-reported workspace state, not keyboard focus. '
            'Activation is requested only when you press Activate.',
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                error!,
                key: const ValueKey('error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          if (notice != null) ...[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(notice!)),
          ],
          const SizedBox(height: 20),
          if (entries.isEmpty && groups.isEmpty)
            Text(
              connected
                  ? 'No workspaces or groups advertised by the compositor.'
                  : 'Workspace data is unavailable. Reconnect to try again.',
            ),
          for (final group in groups)
            _section(
              context,
              'Group ${group.objectId}',
              [
                for (final output in group.outputs) 'Output: $output',
                if (group.outputs.isEmpty) 'No outputs advertised',
                'Create workspace: ${group.canCreateWorkspace ? "supported" : "not advertised"}',
              ],
              entries
                  .where((entry) => entry.groupId == group.objectId)
                  .toList(),
            ),
          if (unassigned.isNotEmpty)
            _section(context, 'Unassigned workspaces', const [
              'No currently advertised group',
            ], unassigned),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<String> details,
    List<EntryView> items,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          for (final detail in details) Text(detail),
          const SizedBox(height: 8),
          if (items.isEmpty) const Text('No workspaces in this group.'),
          for (final entry in items) _entry(context, entry),
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, EntryView entry) {
    final capabilities = <String>[
      if (entry.canActivate) 'activate',
      if (entry.canDeactivate) 'deactivate',
      if (entry.canRemove) 'remove',
      if (entry.canAssign) 'assign',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              entry.name?.isNotEmpty == true
                  ? entry.name!
                  : 'Unnamed workspace',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (entry.isActive) const Chip(label: Text('Active')),
                if (entry.isUrgent) const Chip(label: Text('Urgent')),
                if (entry.isHidden) const Chip(label: Text('Hidden')),
                if (!entry.isActive && !entry.isUrgent && !entry.isHidden)
                  const Chip(label: Text('No state flags')),
              ],
            ),
            const SizedBox(height: 8),
            Text('Session object ID: ${entry.objectId}'),
            if (entry.id != null) Text('Persistent ID: ${entry.id}'),
            if (entry.coordinates.isNotEmpty)
              Text('Coordinates: ${entry.coordinates.join(", ")}'),
            Text(
              'Capabilities: ${capabilities.isEmpty ? "none advertised" : capabilities.join(", ")}',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                key: ValueKey('activate-${entry.objectId}'),
                onPressed:
                    connected &&
                        entry.canActivate &&
                        !pending.contains(entry.objectId)
                    ? () => onActivate(entry)
                    : null,
                child: Text(
                  pending.contains(entry.objectId) ? 'Sending…' : 'Activate',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
