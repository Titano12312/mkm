import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../services/socket_service.dart';

/// Center message viewport + input box.
/// Stateless w.r.t. socket: all state lives in SocketService.
/// Motion: new arrivals fade+rise once (seen-ids guard against re-animating
/// history on rebuild), channel header cross-fades, typing row pulses.
class ChatView extends StatefulWidget {
  const ChatView({super.key});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Ids already shown: prevents history re-animating on every rebuild.
  final Set<String> _seenIds = {};
  String? _seenChannel;
  Timer? _typingTimer;
  int _sentCount = 0;

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: Motion.fast, curve: Motion.standard);
  }

  void _onInputChanged(String text) {
    final chat = context.read<SocketService>();
    _typingTimer?.cancel();
    if (text.trim().isEmpty) {
      chat.sendTyping(false);
      return;
    }
    chat.sendTyping(true);
    // Typing-stop debounce: quiet after 2s without keystrokes.
    _typingTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) context.read<SocketService>().sendTyping(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    final channelId = chat.activeTextChannelId;
    final messages = chat.messagesFor(channelId);
    final typing = chat.typingNames(channelId);

    // Channel switch: absorb all current ids silently so the whole history
    // doesn't animate at once — only true arrivals play the entrance.
    if (_seenChannel != channelId) {
      _seenChannel = channelId;
      _seenIds
        ..clear()
        ..addAll(messages.map((m) => m.id));
    }

    // Auto-scroll on new message (post-frame to wait for layout).
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Column(
      children: [
        // Channel header (cross-fades on switch).
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: Color(0xFF313338),
            border: Border(bottom: BorderSide(color: Colors.black38)),
          ),
          alignment: Alignment.centerLeft,
          child: AnimatedSwitcher(
            duration: Motion.fast,
            child: Text(
              '# ${channelId ?? '…'}',
              key: ValueKey(channelId),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        // Messages
        Expanded(
          child: Container(
            color: const Color(0xFF313338),
            child: messages.isEmpty
                ? const Center(
                    child: Text('Nothing here yet — say hi',
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (_, i) {
                      final m = messages[i];
                      final mine = m.authorId == chat.userId;
                      final isNew = _seenIds.add(m.id);
                      final row = _MessageRow(
                        authorName: m.authorName,
                        content: m.content,
                        createdAt: m.createdAt,
                        mine: mine,
                      );
                      if (!isNew) return row;
                      // Entrance, played exactly once per message.
                      return RepaintBoundary(
                        child: row
                            .animate()
                            .fadeIn(duration: Motion.fast)
                            .slideY(begin: 0.35, end: 0, duration: Motion.base, curve: Motion.standard),
                      );
                    },
                  ),
          ),
        ),
        // Typing indicator ("… is typing", Discord-style).
        AnimatedOpacity(
          opacity: typing.isEmpty ? 0 : 1,
          duration: Motion.fast,
          child: typing.isEmpty
              ? const SizedBox.shrink()
              : Container(
                  width: double.infinity,
                  color: const Color(0xFF313338),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(
                    children: [
                      _TypingDots(),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${typing.join(', ')} ${typing.length == 1 ? 'is' : 'are'} typing…',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        // Input
        Container(
          color: const Color(0xFF313338),
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: TextField(
            controller: _input,
            minLines: 1,
            maxLines: 4,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Message #${channelId ?? ''}',
              hintStyle: const TextStyle(color: Colors.grey),
              filled: true,
              fillColor: const Color(0xFF383A40),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              suffixIcon: IconButton(
                key: ValueKey('send-$_sentCount'),
                icon: const Icon(Icons.send, size: 20),
                color: Colors.grey[400],
                onPressed: _send,
              ).animate().scale(
                    // Bounce replayed per send via the key above.
                    begin: const Offset(1.35, 1.35),
                    end: const Offset(1, 1),
                    duration: Motion.fast,
                    curve: Motion.spring,
                  ),
            ),
            onChanged: _onInputChanged,
            onSubmitted: (_) => _send(),
          ),
        ),
      ],
    );
  }

  void _send() {
    final chat = context.read<SocketService>();
    chat.sendTyping(false);
    _typingTimer?.cancel();
    chat.sendMessage(_input.text);
    _input.clear();
    setState(() => _sentCount++);
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

class _MessageRow extends StatelessWidget {
  final String authorName;
  final String content;
  final DateTime createdAt;
  final bool mine;
  const _MessageRow({
    required this.authorName,
    required this.content,
    required this.createdAt,
    required this.mine,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: mine ? const Color(0xFF5865F2) : Colors.grey[700],
            child: Text(authorName.isNotEmpty ? authorName[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(authorName,
                        style: TextStyle(
                            color: mine ? const Color(0xFF949CF7) : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                    const SizedBox(width: 8),
                    Text(_fmtTime(createdAt),
                        style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 2),
                SelectableText(content,
                    style: const TextStyle(color: Color(0xFFDBDEE1), fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Three dots with a staggered pulse. Static "…" under reduced motion.
class _TypingDots extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    if (Motion.reduce(context)) {
      return const Text('…', style: TextStyle(color: Colors.grey, fontSize: 14));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(color: Colors.grey, shape: BoxShape.circle),
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .fadeIn(duration: const Duration(milliseconds: 400), delay: Duration(milliseconds: 150 * i))
                .fadeOut(duration: const Duration(milliseconds: 400)),
          ),
      ],
    );
  }
}
