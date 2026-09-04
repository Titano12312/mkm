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
