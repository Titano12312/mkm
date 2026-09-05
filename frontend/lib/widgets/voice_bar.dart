import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../services/socket_service.dart';
import '../services/voice_service.dart';

/// Active Voice Bar — pinned above the message input while in a voice room.
/// Shows connected users (avatar + name) + mute / leave controls.
/// Returns SizedBox.shrink() when not in a call so layouts just include it.
///
/// Motion: slides up on join; avatars "breathe" with a staggered glow loop
/// (playful presence cue — NOT live speaking detection, which needs an
/// audio-level spike first). Static under reduced motion.
class VoiceBar extends StatelessWidget {
  const VoiceBar({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    final voice = context.watch<VoiceService>();

    // Error row (mic denied, server silent…): visible even outside a call,
    // tap to reconnect and retry. Never a dead end without explanation.
    if (chat.voiceError != null && (!voice.inCall || chat.activeVoiceChannelId == null)) {
      return InkWell(
        onTap: () {
          chat.setVoiceError(null);
          chat.reconnect();
        },
        child: Container(
          width: double.infinity,
          color: const Color(0xFF3A2323),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            _friendlyVoiceError(chat.voiceError!),
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ),
      );
    }
    if (!voice.inCall || chat.activeVoiceChannelId == null) {
      return const SizedBox.shrink();
    }
    final reduce = Motion.reduce(context);
    final bar = Container(
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
                  for (var i = 0; i < chat.voiceParticipants.length; i++)
                    _ParticipantChip(
                      socketId: chat.voiceParticipants[i].socketId,
                      username: chat.voiceParticipants[i].username,
                      self: chat.voiceParticipants[i].socketId == chat.selfSocketId,
                      index: i,
                      breathing: !reduce,
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
    if (reduce) return bar;
    // Join entrance, played on first build (inCall false→true swaps the tree).
    return bar
        .animate()
        .slideY(begin: 1, end: 0, duration: Motion.base, curve: Motion.standard)
        .fadeIn(duration: Motion.fast);
  }
}

/// Raw server/client voice codes → human tap-to-retry messages.
String _friendlyVoiceError(String code) {
  switch (code) {
    case 'auth-required':
      return 'Login expired — tap to reconnect, then rejoin voice.';
    case 'Mic unavailable':
      return code;
    default:
      return code;
  }
}

class _ParticipantChip extends StatelessWidget {
  final String socketId;
  final String username;
  final bool self;
  final int index;
  final bool breathing;
  const _ParticipantChip({
    required this.socketId,
    required this.username,
    required this.self,
    required this.index,
    required this.breathing,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: 12,
      backgroundColor: self ? const Color(0xFF5865F2) : Colors.grey[700],
      child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?',
          style: const TextStyle(color: Colors.white, fontSize: 11)),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Row(
        children: [
          RepaintBoundary(
            // Isolate the loop so it never repaints the whole bar.
            child: breathing
                ? avatar
                    .animate(onPlay: (c) => c.repeat(reverse: true))
                    .scale(
                      begin: const Offset(1, 1),
                      end: const Offset(1.12, 1.12),
                      duration: const Duration(milliseconds: 1400),
                      delay: Duration(milliseconds: 200 * (index % 4)),
                    )
                : avatar,
          ),
          const SizedBox(width: 4),
          Text(username, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}
