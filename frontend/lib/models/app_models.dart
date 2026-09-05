// Shared models — mirrors the backend event contract 1:1.
// Keep these in sync with backend/server.js.

class Channel {
  final String id;
  final String name;
  const Channel({required this.id, required this.name});

  factory Channel.fromJson(Map<String, dynamic> j) =>
      Channel(id: j['id'] as String, name: j['name'] as String);
}

class ChatMessage {
  final String id;
  final String channelId;
  final String authorId;
  final String authorName;
  final String content;
  final DateTime createdAt;

  const ChatMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.authorName,
    required this.content,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        channelId: j['channelId'] as String,
        authorId: (j['authorId'] ?? '') as String,
        authorName: (j['authorName'] ?? 'Unknown') as String,
        content: (j['content'] ?? '') as String,
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
      );
}

class VoiceParticipant {
  final String socketId;
  final String userId;
  final String username;
  const VoiceParticipant({required this.socketId, required this.userId, required this.username});

  factory VoiceParticipant.fromJson(Map<String, dynamic> j) => VoiceParticipant(
        socketId: j['socketId'] as String,
        userId: (j['userId'] ?? '') as String,
        username: (j['username'] ?? 'Unknown') as String,
      );
}

/// A friend / requester (friend:list). `online` is live server presence.
class SocialUser {
  final String userId;
  final String username;
  final String? email;
  final String? avatarUrl;
  final bool online;
  const SocialUser({required this.userId, required this.username, this.email, this.avatarUrl, this.online = false});

  factory SocialUser.fromJson(Map<String, dynamic> j) => SocialUser(
        userId: j['userId'] as String,
        username: (j['username'] ?? 'Unknown') as String,
        email: j['email'] as String?,
        avatarUrl: j['avatarUrl'] as String?,
        online: (j['online'] ?? false) as bool,
      );
}

class ConversationMember {
  final String userId;
  final String username;
  final String? avatarUrl;
  const ConversationMember({required this.userId, required this.username, this.avatarUrl});

  factory ConversationMember.fromJson(Map<String, dynamic> j) => ConversationMember(
        userId: j['userId'] as String,
        username: (j['username'] ?? 'Unknown') as String,
        avatarUrl: j['avatarUrl'] as String?,
      );
}

/// DM (peer = the other member) or opt-in group conversation.
class Conversation {
  final String id;
  final String kind; // 'dm' | 'group'
  final String? name;
  final List<ConversationMember> members;
  const Conversation({required this.id, required this.kind, this.name, this.members = const []});

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        kind: (j['kind'] ?? 'dm') as String,
        name: j['name'] as String?,
        members: ((j['members'] ?? []) as List)
            .map((e) => ConversationMember.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  /// Display title: group name, or the other member's username for DMs.
  String title(String selfUserId) {
    if (kind == 'group') return (name?.isNotEmpty ?? false) ? name! : 'Group';
    for (final m in members) {
      if (m.userId != selfUserId) return m.username;
    }
    return 'Direct message';
  }

  /// The other member's id for DMs (null for groups/solo).
  String? peerId(String selfUserId) {
    if (kind != 'dm') return null;
    for (final m in members) {
      if (m.userId != selfUserId) return m.userId;
    }
    return null;
  }
}

class DmMessage {
  final String id;
  final String conversationId;
  final String authorId;
  final String authorName;
  final String content;
  final DateTime createdAt;

  const DmMessage({
    required this.id,
    required this.conversationId,
    required this.authorId,
    required this.authorName,
    required this.content,
    required this.createdAt,
  });

  factory DmMessage.fromJson(Map<String, dynamic> j) => DmMessage(
        id: j['id'] as String,
        conversationId: (j['conversationId'] ?? '') as String,
        authorId: (j['authorId'] ?? '') as String,
        authorName: (j['authorName'] ?? 'Unknown') as String,
        content: (j['content'] ?? '') as String,
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
      );
}
