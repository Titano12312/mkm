import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_models.dart';
import '../services/socket_service.dart';
import '../services/voice_service.dart';

/// Left channel sidebar (desktop) / drawer content (mobile).
/// Sections: TEXT CHANNELS (#) and VOICE CHANNELS (🔊 + occupant badge).
/// Voice tap = click-to-join; tapping the active one leaves.
class ChannelSidebar extends StatelessWidget {
  final VoidCallback? onNavigate; // close drawer on mobile after tap
  const ChannelSidebar({super.key, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    final voice = context.watch<VoiceService>();

    return Container(
      color: const Color(0xFF2B2D31),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // App header + username editor
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('TellAviv',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                _UsernameField(initial: chat.username, onSubmit: chat.setUsername),
                const SizedBox(height: 6),
                // Server field recreates on URL change (ValueKey) so it never
                // shows a stale address after reconnect.
                _ServerField(
                  key: ValueKey(chat.serverUrl),
                  initial: chat.serverUrl,
                  onSubmit: (url) async {
                    if (voice.inCall) await voice.leave();
                    await chat.setServerUrl(url);
                  },
                ),
                const SizedBox(height: 4),
                Text(chat.connected ? '● Connected' : '○ Connecting…',
                    style: TextStyle(
                        color: chat.connected ? Colors.greenAccent : Colors.grey, fontSize: 12)),
              ],
            ),
          ),
          const Divider(color: Colors.black38, height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _SectionLabel('TEXT CHANNELS'),
                for (final c in chat.textChannels)
                  _TextRow(
                    channel: c,
                    selected: c.id == chat.activeTextChannelId,
                    onTap: () {
                      chat.selectTextChannel(c.id);
                      onNavigate?.call();
                    },
                  ),
                const SizedBox(height: 12),
                _SectionLabel('VOICE CHANNELS'),
                for (final c in chat.voiceChannels)
                  _VoiceRow(
                    channel: c,
                    count: chat.voiceCounts[c.id] ?? 0,
                    active: c.id == chat.activeVoiceChannelId,
                    onTap: () async {
                      if (chat.activeVoiceChannelId == c.id) {
                        await voice.leave();
                      } else {
                        if (voice.inCall) await voice.leave();
                        await voice.join(c.id);
                      }
                      onNavigate?.call();
                    },
                  ),
              ],
            ),
          ),
          // Bottom user strip (mirrors Discord)
          Container(
            color: const Color(0xFF232428),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: const Color(0xFF5865F2),
                  child: Text(chat.username.isNotEmpty ? chat.username[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(chat.username,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
                if (voice.inCall)
                  IconButton(
                    tooltip: voice.muted ? 'Unmute' : 'Mute',
                    icon: Icon(voice.muted ? Icons.mic_off : Icons.mic, size: 18),
                    color: voice.muted ? Colors.redAccent : Colors.white70,
                    onPressed: voice.toggleMute,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(text,
            style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
      );
}

class _TextRow extends StatelessWidget {
  final Channel channel;
  final bool selected;
  final VoidCallback onTap;
  const _TextRow({required this.channel, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          color: selected ? const Color(0xFF404249) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text('#  ${channel.name}',
                  style: TextStyle(
                      color: selected ? Colors.white : Colors.grey[400], fontSize: 14)),
            ),
          ),
        ),
      );
}

class _VoiceRow extends StatelessWidget {
  final Channel channel;
  final int count;
  final bool active;
  final VoidCallback onTap;
  const _VoiceRow({required this.channel, required this.count, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          color: active ? const Color(0xFF404249) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.volume_up, size: 16, color: active ? Colors.greenAccent : Colors.grey[400]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(channel.name,
                        style: TextStyle(
                            color: active ? Colors.white : Colors.grey[400], fontSize: 14)),
                  ),
                  if (count > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.black38, borderRadius: BorderRadius.circular(10)),
                      child: Text('$count',
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _UsernameField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onSubmit;
  const _UsernameField({required this.initial, required this.onSubmit});
  @override
  State<_UsernameField> createState() => _UsernameFieldState();
}

class _UsernameFieldState extends State<_UsernameField> {
  late final TextEditingController _c;
  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.initial);
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Username',
          hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
          filled: true,
          fillColor: const Color(0xFF1E1F22),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        onSubmitted: widget.onSubmit,
      );
}

/// Discord blurple — kept as a const to avoid extra theme packages.
const kBlurple = Color(0xFF5865F2);

/// Backend address field. Same styling as the username field; submits an
/// async reconnect (caller leaves voice first — see usage above).
class _ServerField extends StatefulWidget {
  final String initial;
  final Future<void> Function(String) onSubmit;
  const _ServerField({super.key, required this.initial, required this.onSubmit});
  @override
  State<_ServerField> createState() => _ServerFieldState();
}

class _ServerFieldState extends State<_ServerField> {
  late final TextEditingController _c;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.initial);
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        enabled: !_busy,
        keyboardType: TextInputType.url,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Server URL',
          hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
          filled: true,
          fillColor: const Color(0xFF1E1F22),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          suffixIcon: _busy
              ? const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : null,
        ),
        onSubmitted: (v) async {
          setState(() => _busy = true);
          try {
            await widget.onSubmit(v);
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        },
      );
}
