import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../models/app_models.dart';

/// SocketService — single owner of the Socket.io connection.
///
/// ARCHITECTURE: one singleton ChangeNotifier, exposed via Provider.
/// All screens/widgets read from here; widgets never hold sockets directly.
/// This keeps text, presence, and voice-signaling state consistent across
/// desktop/mobile layouts.
///
/// Server URL resolution: `--dart-define=API_URL=...` baked at build time
/// as the default, overridable at runtime via [setServerUrl] (sidebar field)
/// so the app can follow the backend (LAN IP changes, public deploy)
/// without rebuilding. Fallback covers Windows desktop dev.
class SocketService extends ChangeNotifier {
  io.Socket? _socket;

  String username;
  final String userId;
  String serverUrl;

  /// Provides the current Supabase access token (wired by AuthGate).
  /// Identity for server writes comes ONLY from this verified token.
  final String? Function() tokenProvider;

  bool connected = false;
  bool authed = false; // server confirmed our token via auth:ok
  String? authError;
  List<Channel> textChannels = [];
  List<Channel> voiceChannels = [];
  Map<String, int> voiceCounts = {}; // voiceChannelId -> occupant count

  String? activeTextChannelId;
  final Map<String, List<ChatMessage>> messagesByChannel = {};

  /// Ephemeral typing state: channelId -> { userId: username }.
  final Map<String, Map<String, String>> typingByChannel = {};

  String? activeVoiceChannelId;
  List<VoiceParticipant> voiceParticipants = [];
  String? selfSocketId;

  SocketService({required this.username, required this.userId, String? Function()? tokenProvider})
      : tokenProvider = tokenProvider ?? (() => null),
        serverUrl = const String.fromEnvironment(
          'API_URL',
          defaultValue: 'http://localhost:3000',
        );

  List<ChatMessage> messagesFor(String? channelId) =>
      messagesByChannel[channelId] ?? const [];

  void connect() {
    if (_socket != null) return;
    final socket = io.io(
      serverUrl,
      io.OptionBuilder().setTransports(['websocket']).enableAutoConnect().build(),
    );
    _socket = socket;

    socket.onConnect((_) {
      connected = true;
      selfSocketId = socket.id;
      // Auth first: every write (messages, voice seats) requires the server
      // to verify this token. Identity comes from Supabase, never from us.
      final token = tokenProvider();
      if (token != null) socket.emit('auth:token', {'token': token});
      socket.emit('user:online', {'userId': userId, 'username': username});
      // Auto-join first text channel for instant context.
      if (activeTextChannelId != null) {
        socket.emit('channel:join', {'channelId': activeTextChannelId});
      }
      notifyListeners();
    });

    socket.onDisconnect((_) {
      connected = false;
      authed = false;
      notifyListeners();
    });

    socket.on('auth:ok', (_) {
      authed = true;
      authError = null;
      notifyListeners();
    });

    socket.on('auth:error', (data) {
      authed = false;
      try {
        authError = (Map<String, dynamic>.from(data as Map))['error'] as String?;
      } catch (_) {
        authError = 'auth failed';
      }
      notifyListeners();
    });

    socket.on('channels:list', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      textChannels = (m['text'] as List).map((e) => Channel.fromJson(Map<String, dynamic>.from(e))).toList();
      voiceChannels = (m['voice'] as List).map((e) => Channel.fromJson(Map<String, dynamic>.from(e))).toList();
      activeTextChannelId ??= textChannels.isNotEmpty ? textChannels.first.id : null;
      if (activeTextChannelId != null && connected) {
        socket.emit('channel:join', {'channelId': activeTextChannelId});
      }
      notifyListeners();
    });

    socket.on('channel:history', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      final id = m['channelId'] as String;
      messagesByChannel[id] = (m['messages'] as List)
          .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
    });

    socket.on('message:receive', (data) {
      final msg = ChatMessage.fromJson(Map<String, dynamic>.from(data as Map));
      final list = messagesByChannel.putIfAbsent(msg.channelId, () => []);
      if (list.any((m) => m.id == msg.id)) return; // idempotent on reconnect
      list.add(msg);
      notifyListeners();
    });

    socket.on('voice:directory', (data) {
      final list = (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
      voiceCounts = {for (final e in list) e['channelId'] as String: (e['count'] ?? 0) as int};
      notifyListeners();
    });

    socket.on('voice:joined', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      activeVoiceChannelId = m['channelId'] as String;
      selfSocketId = (m['selfId'] as String?) ?? selfSocketId;
      voiceParticipants = (m['participants'] as List)
          .map((e) => VoiceParticipant.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
    });

    socket.on('voice:update', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      if (m['channelId'] == activeVoiceChannelId) {
        voiceParticipants = (m['participants'] as List)
            .map((e) => VoiceParticipant.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        notifyListeners();
      }
    });

    socket.on('typing:update', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      final channelId = m['channelId'] as String;
      final userId = (m['userId'] ?? '') as String;
      final typing = (m['typing'] ?? false) as bool;
      final bucket = typingByChannel.putIfAbsent(channelId, () => {});
      if (typing) {
        bucket[userId] = (m['username'] ?? 'Someone') as String;
      } else {
        bucket.remove(userId);
      }
      notifyListeners();
    });

    socket.connect();
  }

  /// Re-send the current access token (call on Supabase token refresh).
  void refreshAuth() {
    final token = tokenProvider();
    if (connected && token != null) {
      _socket?.emit('auth:token', {'token': token});
    }
  }

  void selectTextChannel(String channelId) {
    if (activeTextChannelId == channelId) return;
    final prev = activeTextChannelId;
    activeTextChannelId = channelId;
    if (prev != null) _socket?.emit('channel:leave', {'channelId': prev});
    _socket?.emit('channel:join', {'channelId': channelId});
    notifyListeners();
  }

  void sendMessage(String content) {
    final text = content.trim();
    if (text.isEmpty || activeTextChannelId == null) return;
    // No author fields: the server stamps identity from the verified token.
    _socket?.emit('message:send', {
      'channelId': activeTextChannelId,
      'content': text,
    });
    // No optimistic insert: server echoes via message:receive (single path).
  }

  /// Notify the channel that we're typing (ChatView debounces the stop).
  void sendTyping(bool typing) {
    if (activeTextChannelId == null) return;
    _socket?.emit(typing ? 'typing:start' : 'typing:stop', {
      'channelId': activeTextChannelId,
    });
  }

  List<String> typingNames(String? channelId) =>
      typingByChannel[channelId]?.values.toList() ?? const [];

  /// Raw socket access for VoiceService signaling — nothing else should use this.
  io.Socket? get rawSocket => _socket;

  /// Point the app at a (new) backend and reconnect from scratch.
  /// Callers must leave any voice call first (sidebar does this) because
  /// RTCPeerConnections are bound to the old socket's session.
  /// Message cache is kept: server echoes are deduplicated by id on resync.
  Future<void> setServerUrl(String raw) async {
    var url = raw.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    url = url.replaceAll(RegExp(r'/+$'), '');
    if (url == serverUrl) return;
    serverUrl = url;
    _socket?.dispose();
    _socket = null;
    connected = false;
    activeVoiceChannelId = null;
    voiceParticipants = [];
    selfSocketId = null;
    notifyListeners();
    connect(); // re-emits user:online + re-joins activeTextChannelId
  }

  @override
  void dispose() {
    _socket?.dispose();
    super.dispose();
  }
}
