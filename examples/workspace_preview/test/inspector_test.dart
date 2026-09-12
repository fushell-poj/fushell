import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workspace_preview/inspector.dart';

Future<void> showInspector(
  WidgetTester tester, {
  List<EntryView> entries = const [],
  List<GroupView> groups = const [],
  bool connected = true,
  String? error,
  ValueChanged<int>? onActivate,
  ValueChanged<EntryView>? onActivateEntry,
  VoidCallback? onReconnect,
  VoidCallback? onQuit,
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: WorkspaceInspector(
      entries: entries,
      groups: groups,
      status: connected ? 'Connected' : 'Disconnected',
      connected: connected,
      error: error,
      onActivate:
          onActivateEntry ?? (entry) => onActivate?.call(entry.objectId),
      onReconnect: onReconnect ?? () {},
      onQuit: onQuit ?? () {},
    ),
  ),
);

void main() {
  testWidgets(
    'old row callback retains its snapshot when an object ID is reused',
    (tester) async {
      final originalToken = Object();
      final replacementToken = Object();
      final delivered = <Object?>[];
      final original = EntryView(
        objectId: 7,
        canActivate: true,
        activationToken: originalToken,
      );
      final replacement = EntryView(
        objectId: 7,
        canActivate: true,
        activationToken: replacementToken,
      );
      void activate(EntryView entry) => delivered.add(entry.activationToken);
      await showInspector(
        tester,
        entries: [original],
        onActivateEntry: activate,
      );
      final button = find.byKey(const ValueKey('activate-7'));
      final oldCallback = tester.widget<FilledButton>(button).onPressed!;
      await showInspector(
        tester,
        entries: [replacement],
        onActivateEntry: activate,
      );
      oldCallback();
      expect(delivered, [same(originalToken)]);
      await tester.tap(button);
      expect(delivered, [same(originalToken), same(replacementToken)]);
    },
  );
  testWidgets(
    'groups, output metadata and unassigned entries remain distinct',
    (tester) async {
      tester.view.physicalSize = const Size(960, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showInspector(
        tester,
        groups: [
          GroupView(
            objectId: 10,
            outputs: ['DP-1 · Desk'],
            canCreateWorkspace: true,
          ),
        ],
        entries: [
          EntryView(
            objectId: 11,
            groupId: 10,
            name: 'Code',
            id: 'stable-code',
            coordinates: [2, 3],
            isActive: true,
            isUrgent: true,
            isHidden: true,
            canActivate: true,
            canAssign: true,
          ),
          EntryView(objectId: 12, name: 'Detached'),
          EntryView(objectId: 13, name: 'Missing group', groupId: 99),
        ],
      );
      expect(find.text('Group 10'), findsOneWidget);
      expect(find.text('Output: DP-1 · Desk'), findsOneWidget);
      expect(find.text('Create workspace: supported'), findsOneWidget);
      expect(find.text('Unassigned workspaces'), findsOneWidget);
      expect(find.text('Detached'), findsOneWidget);
      expect(find.text('Missing group'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);
      expect(find.text('Hidden'), findsOneWidget);
      expect(find.text('Persistent ID: stable-code'), findsOneWidget);
      expect(find.text('Coordinates: 2, 3'), findsOneWidget);
      expect(find.text('Capabilities: activate, assign'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only enabled explicit activation delivers the matching object ID',
    (tester) async {
      final activations = <int>[];
      await showInspector(
        tester,
        entries: [
          EntryView(objectId: 1, name: 'Allowed', canActivate: true),
          EntryView(objectId: 2, name: 'Unsupported'),
        ],
        onActivate: activations.add,
      );
      expect(activations, isEmpty);
      final enabled = find.byKey(const ValueKey('activate-1'));
      final disabled = find.byKey(const ValueKey('activate-2'));
      expect(tester.widget<FilledButton>(disabled).onPressed, isNull);
      await tester.tap(enabled);
      expect(activations, [1]);
      await showInspector(
        tester,
        connected: false,
        entries: [EntryView(objectId: 1, canActivate: true)],
        onActivate: activations.add,
      );
      expect(tester.widget<FilledButton>(enabled).onPressed, isNull);
      expect(activations, [1]);
    },
  );

  testWidgets('480 pixel viewport wraps long metadata without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await showInspector(
      tester,
      error:
          'UnsupportedProtocol: This compositor does not advertise ext_workspace_manager_v1. Reconnect after changing compositor.',
      groups: [
        GroupView(
          objectId: 10,
          outputs: [List.filled(20, 'Very long output description').join(' ')],
        ),
      ],
      entries: [
        EntryView(
          objectId: 1,
          groupId: 10,
          name:
              'An unusually long workspace name that needs to wrap over multiple lines',
          id: List.filled(120, 'x').join(),
          coordinates: [1, 2, 3],
          isActive: true,
          isUrgent: true,
          isHidden: true,
          canActivate: true,
          canDeactivate: true,
          canRemove: true,
          canAssign: true,
        ),
      ],
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('activate-1')),
      250,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('activate-1')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets(
    'disconnected errors omit unknown counts and offer reconnect and quit',
    (tester) async {
      var reconnects = 0;
      var quits = 0;
      await showInspector(
        tester,
        connected: false,
        error: 'UnsupportedProtocol: ext_workspace_manager_v1 is unavailable',
        onReconnect: () => reconnects++,
        onQuit: () => quits++,
      );
      expect(find.textContaining('UnsupportedProtocol'), findsOneWidget);
      expect(find.text('0 workspaces · 0 groups'), findsNothing);
      await tester.tap(find.byTooltip('Reconnect'));
      await tester.tap(find.byTooltip('Quit'));
      expect(reconnects, 1);
      expect(quits, 1);
    },
  );

  testWidgets('empty advertised group remains visible', (tester) async {
    await showInspector(tester, groups: [GroupView(objectId: 42)]);
    expect(find.text('Group 42'), findsOneWidget);
    expect(find.text('No outputs advertised'), findsOneWidget);
    expect(find.text('No workspaces in this group.'), findsOneWidget);
    expect(find.text('0 workspaces · 1 group'), findsOneWidget);
  });
}
