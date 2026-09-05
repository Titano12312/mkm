import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../core/motion.dart';
import '../services/socket_service.dart';

/// Message viewport + input box, in two modes:
/// - channel mode (default): server text channel from the sidebar.
/// - conversation mode: 1:1 DM or opt-in group (service.activeConversationId).
/// Stateless w.r.t. socket: all state lives in SocketService.
/// Motion: new arrivals fade+rise once (seen-ids guard against re-animating
/// history on rebuild), channel header cross-fades, typing row pulses.
/// Reliability: failed sends show a SnackBar (never swallowed silently).
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
  String? _seenKey;
  Timer? _typingTimer;
  int _sentCount = 0;

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: Motion.fast, curve: Motion.standard);
  }

  void _onInputChanged(String text) {
    final chat = context.read<SocketService>();
    final convId = chat.activeConversationId;
    _typingTimer?.cancel();
    if (text.trim().isEmpty) {
      chat.sendTyping(false, conversationId: convId);
      return;
    }
    chat.sendTyping(true, conversationId: convId);
    // Typing-stop debounce: quiet after 2s without keystrokes.
    _typingTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        context.read<SocketService>().sendTyping(
              false,
              conversationId: context.read<SocketService>().activeConversationId,
            );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    final conv = chat.conversationById(chat.activeConversationId);
    final inConversation = conv != null;

    final String viewKey;
    final String title;
    final String? subtitle;
    final List<_RowData> rows;
    if (inConversation) {
      viewKey = 'conv:${conv.id}';
      title = conv.title(chat.userId);
      subtitle = conv.kind == 'group' ? '${conv.members.length} members' : 'Direct message';
      rows = chat
          .convMessagesFor(conv.id)
          .map((m) => _RowData(
                id: m.id,
                authorId: m.authorId,
                authorName: m.authorName,
                content: m.content,
                createdAt: m.createdAt,
              ))
          .toList();
    } else {
      final channelId = chat.activeTextChannelId;
      viewKey = 'channel:$channelId';
      title = '# ${channelId ?? '…'}';
      subtitle = null;
      rows = chat
          .messagesFor(channelId)
          .map((m) => _RowData(
                id: m.id,
                authorId: m.authorId,
                authorName: m.authorName,
                content: m.content,
                createdAt: m.createdAt,
              ))
          .toList();
    }
    final typing = chat.typingNames(inConversation ? conv.id : chat.activeTextChannelId);

    // View switch: absorb all current ids silently so history doesn't
    // animate at once — only true arrivals play the entrance.
    if (_seenKey != viewKey) {
      _seenKey = viewKey;
      _seenIds
        ..clear()
        ..addAll(rows.map((m) => m.id));
    }

    // Auto-scroll on new message (post-frame to wait for layout).
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Column(
      children: [
        // Header (cross-fades on switch; back + leave in conversation mode).
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF313338),
            border: Border(bottom: BorderSide(color: Colors.black38)),
          ),
          child: Row(
            children: [
              if (inConversation)
                IconButton(
                  tooltip: 'Back to channels',
                  icon: const Icon(Icons.arrow_back, size: 20),
                  color: Colors.grey[400],
                  onPressed: () => context.read<SocketService>().closeConversation(),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.fast,
                  child: Column(
                    key: ValueKey(viewKey),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold)),
                      if (subtitle != null)
                        Text(subtitle,
                            style: const TextStyle(color: Colors.grey, fontSize: 11)),
                    ],
                  ),
                ),
              ),
              if (inConversation && conv.kind == 'group')
                IconButton(
                  tooltip: 'Leave group',
                  icon: const Icon(Icons.exit_to_app, size: 20),
                  color: Colors.grey[400],
                  onPressed: () => _confirmLeaveGroup(context, conv.id, title),
                ),
            ],
          ),
        ),
        // Messages
        Expanded(
          child: Container(
            color: const Color(0xFF313338),
            child: rows.isEmpty
                ? const Center(
                    child: Text('Nothing here yet — say hi',
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final m = rows[i];
                      final mine = m.authorId == chat.userId;
                      final isNew = _seenIds.add(m.id);
                      // Group consecutive messages from the same author
                      // (<5 min apart): hide the repeated header/avatar.
                      var grouped = false;
                      if (i > 0) {
                        final p = rows[i - 1];
                        grouped = p.authorId == m.authorId &&
                            m.createdAt.difference(p.createdAt).inMinutes.abs() < 5;
                      }
                      final row = _MessageRow(
                        authorName: m.authorName,
                        content: m.content,
                        createdAt: m.createdAt,
                        mine: mine,
                        compact: grouped,
                      );
                      if (!isNew) return row;
                      // Entrance, played exactly once per message. Sides match
                      // the conversation direction (mine right, theirs left).
                      return RepaintBoundary(
                        child: row
                            .animate()
                            .fadeIn(duration: Motion.fast)
                            .slide(
                              begin: Offset(mine ? 0.25 : -0.25, 0.2),
                              end: Offset.zero,
                              duration: Motion.base,
                              curve: Motion.standard,
                            ),
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
              hintText: 'Message $title',
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

  Future<void> _send() async {
    final chat = context.read<SocketService>();
    final text = _input.text;
    if (text.trim().isEmpty) return;
    chat.sendTyping(false, conversationId: chat.activeConversationId);
    _typingTimer?.cancel();
    _input.clear();
    setState(() => _sentCount++);
    final ok = chat.activeConversationId != null
        ? await chat.sendConversationMessage(text)
        : await chat.sendMessage(text);
    // THE fix for "messages don't arrive": a failed send is now visible
    // with a retry action instead of vanishing silently.
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Couldn't send — check connection, then retry."),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              _input.text = text;
              _send();
            },
          ),
        ),
      );
    }
  }

  Future<void> _confirmLeaveGroup(BuildContext context, String convId, String title) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2B2D31),
        title: Text('Leave "$title"?', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text('You will stop receiving its messages.',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (leave == true && context.mounted) {
      await context.read<SocketService>().leaveGroup(convId);
    }
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

/// Flat row projection shared by channel + conversation messages.
class _RowData {
  final String id;
  final String authorId;
  final String authorName;
  final String content;
  final DateTime createdAt;
  const _RowData({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.content,
    required this.createdAt,
  });
}

class _MessageRow extends StatelessWidget {
  final String authorName;
  final String content;
  final DateTime createdAt;
  final bool mine;
  final bool compact;
  const _MessageRow({
    required this.authorName,
    required this.content,
    required this.createdAt,
    required this.mine,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    // Grouped follow-up: content only, indented to the text column
    // (avatar 32 + gap 10 = 42).
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 42),
            Expanded(
              child: SelectableText(content,
                  style: const TextStyle(color: Color(0xFFDBDEE1), fontSize: 14)),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: _Body(
        authorName: authorName,
        content: content,
        createdAt: createdAt,
        mine: mine,
      ),
    );
  }
}

/// Full message: avatar + name/time header + text.
class _Body extends StatelessWidget {
  final String authorName;
  final String content;
  final DateTime createdAt;
  final bool mine;
  const _Body({
    required this.authorName,
    required this.content,
    required this.createdAt,
    required this.mine,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: mine ? const Color(0xFFFF5757) : Colors.grey[700],
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
                            color: mine ? const Color(0xFFFF9E9E) : Colors.white,
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
