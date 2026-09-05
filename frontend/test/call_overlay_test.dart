import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tellaviv/services/call_service.dart';
import 'package:tellaviv/services/socket_service.dart';
import 'package:tellaviv/widgets/call_overlay.dart';

Widget _harness(SocketService chat, CallService call) {
  return MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<SocketService>.value(value: chat),
        ChangeNotifierProvider<CallService>.value(value: call),
      ],
      child: const Scaffold(body: CallOverlayHost()),
    ),
  );
}

void main() {
  testWidgets('idle call shows nothing, outcome toasts once', (tester) async {
    final chat = SocketService(username: 'marco', userId: 'u1');
    final call = CallService(chat)..lastOutcome = 'declined';
    await tester.pumpWidget(_harness(chat, call));
    await tester.pump(); // post-frame snackbar
    await tester.pump();
    expect(find.text('Call declined.'), findsOneWidget);
    expect(call.lastOutcome, isNull); // consumed
  });

  testWidgets('incoming call shows accept and decline', (tester) async {
    final chat = SocketService(username: 'marco', userId: 'u1');
    final call = CallService(chat)
      ..phase = CallPhase.incoming
      ..callId = 'c1'
      ..peerUserId = 'u2'
      ..peerUsername = 'anna';
    await tester.pumpWidget(_harness(chat, call));
    await tester.pump();
    expect(find.text('anna'), findsOneWidget);
    expect(find.text('Incoming call…'), findsOneWidget);
    expect(find.byIcon(Icons.call), findsOneWidget);
    expect(find.byIcon(Icons.call_end), findsOneWidget);
    // Flush the ringing loop, unmount, flush stragglers before teardown.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('active call shows timer and mute', (tester) async {
    final chat = SocketService(username: 'marco', userId: 'u1');
    final call = CallService(chat)
      ..phase = CallPhase.active
      ..callId = 'c1'
      ..peerUserId = 'u2'
      ..peerUsername = 'anna'
      ..connectedAt = DateTime.now();
    await tester.pumpWidget(_harness(chat, call));
    await tester.pump();
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.call_end), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d\d:\d\d')), findsOneWidget);
    // Unmount to dispose the 1s ticker, flush stragglers before teardown.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  });
}
