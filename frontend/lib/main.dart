import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'services/socket_service.dart';
import 'services/voice_service.dart';
import 'widgets/channel_sidebar.dart';
import 'widgets/chat_view.dart';
import 'widgets/voice_bar.dart';

/// Breakpoint: ≥800 logical px = desktop (persistent sidebar),
/// below = mobile (drawer + top bar). Matches Flutter/Discord conventions
/// for 7" tablets vs desktop windows.
const double kDesktopBreakpoint = 800;

void main() {
  // Stable per-install identity. Swap for real auth (Firebase/Supabase)
  // without touching the chat/voice widgets — only this wiring changes.
  final userId = const Uuid().v4();
  final chat = SocketService(username: 'Guest-${userId.substring(0, 4)}', userId: userId);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SocketService>.value(value: chat),
        ChangeNotifierProxyProvider<SocketService, VoiceService>(
          create: (ctx) => VoiceService(ctx.read<SocketService>()),
          update: (_, signaling, prev) => prev ?? VoiceService(signaling),
        ),
      ],
      child: const TellAvivApp(),
    ),
  );
}

class TellAvivApp extends StatelessWidget {
  const TellAvivApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Discord-like dark palette applied globally.
    return MaterialApp(
      title: 'TellAviv',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF313338),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF2B2D31)),
      ),
      home: const _Connector(),
    );
  }
}

/// Connects the socket exactly once, then shows the responsive shell.
class _Connector extends StatefulWidget {
  const _Connector();
  @override
  State<_Connector> createState() => _ConnectorState();
}

class _ConnectorState extends State<_Connector> {
  @override
  void initState() {
    super.initState();
    // Post-frame: Provider is mounted by now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SocketService>().connect();
    });
  }

  @override
  Widget build(BuildContext context) => const HomeShell();
}

class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= kDesktopBreakpoint) {
          return const DesktopLayout();
        }
        return const MobileLayout();
      },
    );
  }
}

/// Desktop: persistent sidebar | chat column (messages + voice bar + input).
class DesktopLayout extends StatelessWidget {
  const DesktopLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Row(
        children: [
          SizedBox(width: 280, child: ChannelSidebar()),
          VerticalDivider(width: 1, color: Colors.black38),
          Expanded(
            child: Column(
              children: [
                Expanded(child: ChatView()),
                VoiceBar(), // collapses to zero height when not in call
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Mobile: drawer for channels, chat fills screen, voice bar stays visible.
class MobileLayout extends StatelessWidget {
  const MobileLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    return Scaffold(
      appBar: AppBar(
        title: Text('# ${chat.activeTextChannelId ?? '…'}'),
        actions: [
          IconButton(
            tooltip: 'Mute / unmute',
            icon: Icon(context.watch<VoiceService>().muted ? Icons.mic_off : Icons.mic),
            onPressed: context.read<VoiceService>().toggleMute,
          ),
        ],
      ),
      drawer: Drawer(
        width: 300,
        child: SafeArea(
          child: ChannelSidebar(onNavigate: () => Navigator.of(context).pop()),
        ),
      ),
      body: const Column(
        children: [
          Expanded(child: ChatView()),
          VoiceBar(),
        ],
      ),
    );
  }
}
