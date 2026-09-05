import 'dart:async';

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
  String? voiceError;

  // -- Own profile (server source of truth; refreshed with social state) ------
  String? myEmail;
  String? myAvatarUrl;

  // -- Social: friends, DMs, opt-in groups ------------------------------------
  List<SocialUser> friends = [];
  List<SocialUser> pendingIn = [];
  List<SocialUser> pendingOut = [];
  List<Conversation> conversations = [];
  String? activeConversationId;
  final Map<String, List<DmMessage>> dmMessagesByConv = {};

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
      // Generous timeouts: Render free tier cold-starts can take 30s+.
      // Socket.io auto-reconnects with backoff after that.
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setTimeout(20000)
          .setReconnectionDelay(2000)
          .setReconnectionDelayMax(15000)
          .enableAutoConnect()
          .build(),
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

    socket.on('auth:ok', (data) {
      authed = true;
      authError = null;
      try {
        final m = Map<String, dynamic>.from(data as Map);
        final serverName = ((m['username'] ?? '') as String).trim();
        // Server is the source of truth for names (dedup suffixes live
        // there), so the sidebar never shows a stale local guess.
        if (serverName.isNotEmpty) username = serverName;
      } catch (_) {}
      notifyListeners();
      // Pull social state on every (re-)auth: friends, requests, DMs.
      refreshSocial();
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

    socket.on('voice:error', (data) {
      try {
        voiceError = (Map<String, dynamic>.from(data as Map))['error'] as String?;
      } catch (_) {
        voiceError = 'voice failed';
      }
      notifyListeners();
    });

    socket.on('social:refresh', (_) => refreshSocial());

    socket.on('dm:receive', (data) {
      final msg = DmMessage.fromJson(Map<String, dynamic>.from(data as Map));
      final list = dmMessagesByConv.putIfAbsent(msg.conversationId, () => []);
      if (list.any((m) => m.id == msg.id)) return; // idempotent on reconnect
      list.add(msg);
      notifyListeners();
    });

    socket.on('dm:history', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      final id = m['conversationId'] as String;
      dmMessagesByConv[id] = (m['messages'] as List)
          .map((e) => DmMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
    });

    socket.on('conv:update', (_) => refreshSocial());

    socket.on('typing:update', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      // Channels and conversations share the bucket map (ids never collide:
      // slugs vs UUIDs). ChatView/DmView read their own key only.
      final key = (m['conversationId'] ?? m['channelId']) as String?;
      if (key == null) return;
      final userId = (m['userId'] ?? '') as String;
      final typing = (m['typing'] ?? false) as bool;
      final bucket = typingByChannel.putIfAbsent(key, () => {});
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
    activeConversationId = null; // channel mode and conversation mode exclude each other
    if (activeTextChannelId == channelId) {
      notifyListeners();
      return;
    }
    final prev = activeTextChannelId;
    activeTextChannelId = channelId;
    if (prev != null) _socket?.emit('channel:leave', {'channelId': prev});
    _socket?.emit('channel:join', {'channelId': channelId});
    notifyListeners();
  }

  /// Emit with server ack, guarded by a timeout so UI never hangs on a
  /// dead socket (e.g. Render cold start). Returns the ack map or null.
  Future<Map<String, dynamic>?> _emitAck(String event, Map<String, dynamic> data) {
    final socket = _socket;
    if (socket == null || !connected) return Future.value(null);
    final completer = Completer<Map<String, dynamic>?>();
    socket.emitWithAck(event, data, ack: (dynamic res) {
      if (completer.isCompleted) return;
      try {
        completer.complete(res == null ? null : Map<String, dynamic>.from(res as Map));
      } catch (_) {
        completer.complete(null);
      }
    });
    Future<void>.delayed(const Duration(seconds: 12), () {
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future;
  }

  /// Send a channel message. Returns true on server ack. On auth-required,
  /// refreshes the token once and retries (covers expired-JWT races);
  /// the caller surfaces a SnackBar when it still fails — sends are never
  /// silently dropped anymore.
  Future<bool> sendMessage(String content) {
    final text = content.trim();
    if (text.isEmpty || activeTextChannelId == null) return Future.value(false);
    // No author fields: the server stamps identity from the verified token.
    return _sendWithAuthRetry(
      () => _emitAck('message:send', {'channelId': activeTextChannelId, 'content': text}),
    );
  }

  Future<bool> _sendWithAuthRetry(Future<Map<String, dynamic>?> Function() send) async {
    var ack = await send();
    if (ack != null && ack['ok'] == true) return true;
    if (ack != null && ack['error'] == 'auth-required') {
      refreshAuth();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      ack = await send();
      if (ack != null && ack['ok'] == true) return true;
    }
    return false;
  }

  /// Notify the active target that we're typing (ChatView debounces the stop).
  void sendTyping(bool typing, {String? conversationId}) {
    final data = <String, dynamic>{};
    if (conversationId != null) {
      data['conversationId'] = conversationId;
    } else {
      if (activeTextChannelId == null) return;
      data['channelId'] = activeTextChannelId;
    }
    _socket?.emit(typing ? 'typing:start' : 'typing:stop', data);
  }

  List<String> typingNames(String? key) =>
      typingByChannel[key]?.values.toList() ?? const [];

  /// Manual reconnect (sidebar status tap). Disposes the dead socket so
  /// connect() builds a fresh one; caches survive (dedup by id on resync).
  void reconnect() {
    _socket?.dispose();
    _socket = null;
    connected = false;
    authed = false;
    notifyListeners();
    connect();
  }

  void setVoiceError(String? err) {
    voiceError = err;
    notifyListeners();
  }

  // -- Social API (ack-based; null/non-ok = show it, never swallow) -----------

  Future<void> refreshSocial() async {
    if (!connected) return;
    await _refreshMyProfile();
    final friendsAck = await _emitAck('friend:list', {});
    if (friendsAck != null && friendsAck['ok'] == true) {
      friends = ((friendsAck['friends'] ?? []) as List)
          .map((e) => SocialUser.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      pendingIn = ((friendsAck['pendingIn'] ?? []) as List)
          .map((e) => SocialUser.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      pendingOut = ((friendsAck['pendingOut'] ?? []) as List)
          .map((e) => SocialUser.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    final convAck = await _emitAck('conversation:list', {});
    if (convAck != null && convAck['ok'] == true) {
      conversations = ((convAck['conversations'] ?? []) as List)
          .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    notifyListeners();
  }

  /// Returns null on success, otherwise a short error code for the dialog.
  Future<String?> sendFriendRequest(String username) async {
    final ack = await _emitAck('friend:request', {'username': username.trim()});
    if (ack == null) return 'offline';
    if (ack['ok'] == true) {
      await refreshSocial();
      return null;
    }
    return (ack['error'] ?? 'failed') as String;
  }

  Future<bool> acceptFriend(String userId) async {
    final ack = await _emitAck('friend:accept', {'userId': userId});
    if (ack != null && ack['ok'] == true) {
      await refreshSocial();
      return true;
    }
    return false;
  }

  Future<bool> declineFriend(String userId) async {
    final ack = await _emitAck('friend:decline', {'userId': userId});
    if (ack != null && ack['ok'] == true) {
      await refreshSocial();
      return true;
    }
    return false;
  }

  Conversation? conversationById(String? id) {
    if (id == null) return null;
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<DmMessage> convMessagesFor(String? conversationId) =>
      dmMessagesByConv[conversationId] ?? const [];

  /// Open a 1:1 DM (find-or-create server-side). Returns error code or null.
  Future<String?> openDm(String friendId) async {
    final ack = await _emitAck('dm:open', {'friendId': friendId});
    if (ack == null) return 'offline';
    if (ack['ok'] != true) return (ack['error'] ?? 'failed') as String;
    activeTextChannelId = null;
    activeConversationId = ack['conversationId'] as String;
    await refreshSocial();
    return null;
  }

  /// Open an existing conversation (group tap, or returning to a DM).
  void openConversation(String conversationId) {
    activeTextChannelId = null;
    activeConversationId = conversationId;
    _socket?.emit('conv:history', {'conversationId': conversationId});
    notifyListeners();
  }

  /// Back to server channels (keeps the first text channel as landing).
  void closeConversation() {
    activeConversationId = null;
    if (activeTextChannelId == null && textChannels.isNotEmpty) {
      selectTextChannel(textChannels.first.id);
      return;
    }
    notifyListeners();
  }

  Future<bool> sendConversationMessage(String content) {
    final text = content.trim();
    if (text.isEmpty || activeConversationId == null) return Future.value(false);
    return _sendWithAuthRetry(
      () => _emitAck('conv:send', {'conversationId': activeConversationId, 'content': text}),
    );
  }

  /// Create an opt-in group with friends. Returns conversation id or null.
  Future<String?> createGroup(String name, List<String> memberIds) async {
    final ack = await _emitAck('group:create', {'name': name, 'memberIds': memberIds});
    if (ack != null && ack['ok'] == true) {
      await refreshSocial();
      return ack['conversationId'] as String;
    }
    return null;
  }

  Future<bool> leaveGroup(String conversationId) async {
    final ack = await _emitAck('group:leave', {'conversationId': conversationId});
    if (activeConversationId == conversationId) closeConversation();
    await refreshSocial();
    return ack != null && ack['ok'] == true;
  }

  // -- 1:1 call signaling passthrough (state lives in CallService) ------------
  // Invite is acked (needs the callId); accept/decline/end are fire-and-
  // forget — the server answers with call:accepted/cancelled/ended events.

  Future<Map<String, dynamic>?> callInvite(String targetUserId) =>
      _emitAck('call:invite', {'targetUserId': targetUserId});

  void callAccept(String callId) =>
      _socket?.emit('call:accept', {'callId': callId});

  void callDecline(String callId) =>
      _socket?.emit('call:decline', {'callId': callId});

  void callEnd(String callId) =>
      _socket?.emit('call:end', {'callId': callId});

  // -- Own profile API ----------------------------------------------------------

  Future<void> _refreshMyProfile() async {
    final ack = await _emitAck('profile:me', {});
    if (ack == null || ack['ok'] != true || ack['profile'] == null) return;
    final p = Map<String, dynamic>.from(ack['profile'] as Map);
    final serverName = ((p['username'] ?? '') as String).trim();
    if (serverName.isNotEmpty) username = serverName;
    myEmail = p['email'] as String?;
    myAvatarUrl = p['avatarUrl'] as String?;
    notifyListeners();
  }

  /// Rename. Returns null on success, short error code otherwise.
  Future<String?> updateUsername(String name) async {
    final ack = await _emitAck('profile:set-username', {'username': name.trim()});
    if (ack == null) return 'offline';
    if (ack['ok'] == true) {
      // Server also pushes auth:ok + social:refresh; apply immediately too.
      final fresh = ((ack['username'] ?? '') as String).trim();
      if (fresh.isNotEmpty) username = fresh;
      notifyListeners();
      return null;
    }
    return (ack['error'] ?? 'failed') as String;
  }

  /// Pin an uploaded avatar URL. Returns null on success, error code otherwise.
  Future<String?> updateAvatarUrl(String url) async {
    final ack = await _emitAck('profile:set-avatar', {'avatarUrl': url});
    if (ack == null) return 'offline';
    if (ack['ok'] == true) {
      myAvatarUrl = ((ack['avatarUrl'] ?? url) as String);
      notifyListeners();
      await refreshSocial();
      return null;
    }
    return (ack['error'] ?? 'failed') as String;
  }

  /// Avatar lookup for message/friend rows: self → friends → group members.
  String? avatarFor(String userId) {
    if (userId == this.userId) return myAvatarUrl;
    for (final f in friends) {
      if (f.userId == userId) return f.avatarUrl;
    }
    for (final c in conversations) {
      for (final m in c.members) {
        if (m.userId == userId) return m.avatarUrl;
      }
    }
    return null;
  }

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
