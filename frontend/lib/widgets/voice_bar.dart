import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/socket_service.dart';
import '../services/voice_service.dart';

/// Active Voice Bar — pinned above the message input while in a voice room.
/// Shows connected users (avatar + name) + mute / leave controls.
/// Returns SizedBox.shrink() when not in a call so layouts just include it.
class VoiceBar extends StatelessWidget {
  const VoiceBar({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    final voice = context.watch<VoiceService>();

    if (!voice.inCall || chat.activeVoiceChannelId == null) {
      return const SizedBox.shrink();
    }
    return Container(
      color: const Color(0xFF1E1F22),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.volume_up, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in chat.voiceParticipants)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: p.socketId == chat.selfSocketId
                                ? const Color(0xFF5865F2)
                                : Colors.grey[700],
                            child: Text(
                                p.username.isNotEmpty ? p.username[0].toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white, fontSize: 11)),
                          ),
                          const SizedBox(width: 4),
                          Text(p.username,
                              style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: voice.muted ? 'Unmute' : 'Mute',
            icon: Icon(voice.muted ? Icons.mic_off : Icons.mic, size: 20),
            color: voice.muted ? Colors.redAccent : Colors.white,
            onPressed: voice.toggleMute,
          ),
          IconButton(
            tooltip: 'Leave voice',
            icon: const Icon(Icons.call_end, size: 20),
            color: Colors.redAccent,
            onPressed: voice.leave,
          ),
        ],
      ),
    );
  }
}
