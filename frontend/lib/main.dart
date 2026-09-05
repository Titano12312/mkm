import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/motion.dart';
import 'services/auth_service.dart';
import 'services/call_service.dart';
import 'services/socket_service.dart';
import 'services/voice_service.dart';
import 'screens/login_screen.dart';
import 'widgets/call_overlay.dart';
import 'widgets/channel_sidebar.dart';
import 'widgets/chat_view.dart';
import 'widgets/home_empty.dart';
import 'widgets/voice_bar.dart';

/// Breakpoint: ≥800 logical px = desktop (persistent sidebar),
/// below = mobile (drawer + top bar). Matches Flutter/Discord conventions
/// for 7" tablets vs desktop windows.
const double kDesktopBreakpoint = 800;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService.init();
  runApp(const TellAvivApp());
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
      home: const AuthGate(),
    );
  }
}

/// Shows LoginScreen until a Supabase session exists, then the chat shell.
/// The shell is keyed by user id so logout/login-as-other fully resets
/// socket + voice state (no cross-account leakage).
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: AuthService.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = AuthService.client.auth.currentSession;
        if (session == null) return const LoginScreen();
        return SessionShell(key: ValueKey(session.user.id), session: session);
      },
    );
  }
}

class SessionShell extends StatefulWidget {
  final Session session;
  const SessionShell({super.key, required this.session});

  @override
  State<SessionShell> createState() => _SessionShellState();
}

class _SessionShellState extends State<SessionShell> {
  late final SocketService _chat;
  StreamSubscription<AuthState>? _authSub;

  String? _token() => AuthService.client.auth.currentSession?.accessToken;

  @override
  void initState() {
    super.initState();
    _chat = SocketService(
      username: AuthService.displayName(widget.session.user),
      userId: widget.session.user.id,
      tokenProvider: _token,
    );
    // Re-auth the socket when Supabase rotates the access token.
    _authSub = AuthService.client.auth.onAuthStateChange.listen((_) {
      _chat.refreshAuth();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SocketService>.value(value: _chat),
        ChangeNotifierProxyProvider<SocketService, VoiceService>(
          create: (ctx) => VoiceService(ctx.read<SocketService>()),
          update: (_, signaling, prev) => prev ?? VoiceService(signaling),
        ),
        ChangeNotifierProxyProvider<SocketService, CallService>(
          create: (ctx) => CallService(ctx.read<SocketService>()),
          update: (_, signaling, prev) => prev ?? CallService(signaling),
        ),
      ],
      child: const _Connector(),
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
  Widget build(BuildContext context) {
    // Call overlay floats above the shell on both layouts.
    return const Stack(
      children: [
        HomeShell(),
        CallOverlayHost(),
      ],
    );
  }
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

/// Desktop: persistent sidebar | main pane (chat or empty home) + voice bar.
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
                Expanded(child: _MainPane()),
                VoiceBar(), // collapses to zero height when not in call
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Main pane: conversation/channel view, or the empty home when nothing
/// is open (the normal state in a friends-first app with no seed channels).
/// Motion: cross-fade on switch so navigation preserves continuity instead
/// of a hard cut. Fade only (no slide) — Operate mode keeps routine
/// transitions fast; reduced motion shortens to a near-instant cut.
class _MainPane extends StatelessWidget {
  const _MainPane();

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    final hasView =
        chat.activeConversationId != null || chat.activeTextChannelId != null;
    final reduce = Motion.reduce(context);
    return AnimatedSwitcher(
      duration: reduce ? Motion.fastExit : Motion.fast,
      reverseDuration: Motion.fastExit,
      switchInCurve: Motion.standard,
      switchOutCurve: Motion.standard,
      child: hasView
          ? const ChatView(key: ValueKey('pane-chat'))
          : const HomeEmpty(key: ValueKey('pane-home')),
    );
  }
}

/// Mobile: drawer for channels, main pane fills screen, voice bar visible.
class MobileLayout extends StatelessWidget {
  const MobileLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          chat.conversationById(chat.activeConversationId)?.title(chat.userId) ??
              (chat.activeTextChannelId != null ? '# ${chat.activeTextChannelId}' : 'TellAviv'),
        ),
      ),
      drawer: Drawer(
        width: 300,
        child: SafeArea(
          child: ChannelSidebar(onNavigate: () => Navigator.of(context).pop()),
        ),
      ),
      body: const Column(
        children: [
          Expanded(child: _MainPane()),
          VoiceBar(),
        ],
      ),
    );
  }
}
