import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../services/call_service.dart';
import '../services/socket_service.dart';
import 'user_avatar.dart';

/// Full-screen call overlay, shown above everything while a call is live.
/// Also surfaces one-shot outcomes (declined/missed) as a toast when idle.
class CallOverlayHost extends StatelessWidget {
  const CallOverlayHost({super.key});

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallService>();

    if (call.phase == CallPhase.idle) {
      if (call.lastOutcome != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_outcomeText(call.lastOutcome!))),
          );
          call.clearOutcome();
        });
      }
      return const SizedBox.shrink();
    }

    final chat = context.watch<SocketService>();
    final peerName = call.peerUsername ?? 'Friend';
    final avatarUrl = call.peerUserId != null ? chat.avatarFor(call.peerUserId!) : null;
    final reduce = Motion.reduce(context);

    final overlay = Material(
      color: const Color(0xF21E1F22),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            children: [
              const Spacer(),
              _RingingAvatar(
                avatarUrl: avatarUrl,
                username: peerName,
                ringing: call.phase != CallPhase.active,
              ),
              const SizedBox(height: 24),
              Text(peerName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _StatusLine(call: call),
              const Spacer(),
              _Controls(call: call),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );

    // Continuity: full-screen takeover fades in (fast), exits faster.
    // Reduced motion: fade only, no scale — feedback stays legible.
    if (reduce) {
      return overlay.animate().fadeIn(duration: Motion.fastExit);
    }
    return overlay
        .animate()
        .fadeIn(duration: Motion.fast)
        .scale(
          begin: const Offset(0.96, 0.96),
          end: const Offset(1, 1),
          duration: Motion.base,
          curve: Motion.standard,
        );
  }
}

String _outcomeText(String outcome) {
  switch (outcome) {
    case 'declined':
      return 'Call declined.';
    case 'missed':
      return 'No answer — call ended.';
    default:
      return outcome;
  }
}

/// Avatar with a ringing pulse (static under reduced motion).
class _RingingAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String username;
  final bool ringing;
  const _RingingAvatar({required this.avatarUrl, required this.username, required this.ringing});

  @override
  Widget build(BuildContext context) {
    final avatar = UserAvatar(avatarUrl: avatarUrl, username: username, radius: 48);
    if (!ringing || Motion.reduce(context)) return avatar;
    return RepaintBoundary(
      child: avatar
          .animate(onPlay: (c) => c.repeat(reverse: true))
          .scale(
            begin: const Offset(1, 1),
            end: const Offset(1.08, 1.08),
            duration: const Duration(milliseconds: 900),
          ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final CallService call;
  const _StatusLine({required this.call});

  @override
  Widget build(BuildContext context) {
    switch (call.phase) {
      case CallPhase.outgoing:
        return const Text('Calling…', style: TextStyle(color: Colors.grey, fontSize: 15));
      case CallPhase.incoming:
        return const Text('Incoming call…', style: TextStyle(color: Colors.grey, fontSize: 15));
      case CallPhase.active:
        return _CallTimer(since: call.connectedAt ?? DateTime.now());
      case CallPhase.idle:
        return const SizedBox.shrink();
    }
  }
}

class _CallTimer extends StatefulWidget {
  final DateTime since;
  const _CallTimer({required this.since});

  @override
  State<_CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<_CallTimer> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.since);
    final mm = elapsed.inMinutes.toString().padLeft(2, '0');
    final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Text('$mm:$ss', style: const TextStyle(color: Colors.grey, fontSize: 15));
  }
}

class _Controls extends StatelessWidget {
  final CallService call;
  const _Controls({required this.call});

  @override
  Widget build(BuildContext context) {
    if (call.phase == CallPhase.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CallButton(
            icon: Icons.call_end,
            color: Colors.redAccent,
            tooltip: 'Decline',
            onPressed: call.decline,
          ),
          _CallButton(
            icon: Icons.call,
            color: Colors.green,
            tooltip: 'Accept',
            onPressed: call.accept,
          ),
        ],
      );
    }
    // Outgoing ringing: cancel. Active: mute + hang up.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        if (call.phase == CallPhase.active)
          _CallButton(
            key: ValueKey('call-mute-${call.muted}'),
            icon: call.muted ? Icons.mic_off : Icons.mic,
            color: call.muted ? Colors.redAccent : const Color(0xFF404249),
            tooltip: call.muted ? 'Unmute' : 'Mute',
            onPressed: call.toggleMute,
          ),
        _CallButton(
          icon: Icons.call_end,
          color: Colors.redAccent,
          tooltip: call.phase == CallPhase.active ? 'Hang up' : 'Cancel',
          onPressed: call.end,
        ),
      ],
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  const _CallButton({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}
