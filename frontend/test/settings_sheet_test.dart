import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tellaviv/models/app_models.dart';
import 'package:tellaviv/services/socket_service.dart';
import 'package:tellaviv/widgets/settings_sheet.dart';
import 'package:tellaviv/widgets/social_dialogs.dart';

Widget _harness(SocketService chat, Widget trigger) {
  return MaterialApp(
    home: ChangeNotifierProvider<SocketService>.value(
      value: chat,
      child: Scaffold(body: Builder(builder: (ctx) => trigger)),
    ),
  );
}

void main() {
  testWidgets('settings sheet renders its content', (tester) async {
    final chat = SocketService(username: 'marco', userId: 'u1');
    await tester.pumpWidget(_harness(
      chat,
      Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () => showSettingsSheet(ctx),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('marco'), findsWidgets);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('create-group dialog renders with friends', (tester) async {
    final chat = SocketService(username: 'marco', userId: 'u1')
      ..friends = [const SocialUser(userId: 'u2', username: 'anna')];
    await tester.pumpWidget(_harness(
      chat,
      Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () => showCreateGroupDialog(ctx),
          child: const Text('new group'),
        ),
      ),
    ));
    await tester.tap(find.text('new group'));
    await tester.pumpAndSettle();
    expect(find.text('New group'), findsOneWidget);
    expect(find.text('anna'), findsOneWidget);
  });
}
