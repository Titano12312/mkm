import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/socket_service.dart';

/// Center message viewport + input box.
/// Stateless w.r.t. socket: all state lives in SocketService.
class ChatView extends StatefulWidget {
  const ChatView({super.key});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    final channelId = chat.activeTextChannelId;
    final messages = chat.messagesFor(channelId);

    // Auto-scroll on new message (post-frame to wait for layout).
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Column(
      children: [
        // Channel header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: Color(0xFF313338),
            border: Border(bottom: BorderSide(color: Colors.black38)),
          ),
          alignment: Alignment.centerLeft,
          child: Text('# ${channelId ?? '…'}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        // Messages
        Expanded(
          child: Container(
            color: const Color(0xFF313338),
            child: messages.isEmpty
                ? const Center(
                    child: Text('No messages yet — say hi 👋',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (_, i) {
                      final m = messages[i];
                      final mine = m.authorId == chat.userId;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: mine ? const Color(0xFF5865F2) : Colors.grey[700],
                              child: Text(
                                  m.authorName.isNotEmpty ? m.authorName[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white, fontSize: 13)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(m.authorName,
                                          style: TextStyle(
                                              color: mine ? const Color(0xFF949CF7) : Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13)),
                                      const SizedBox(width: 8),
                                      Text(_fmtTime(m.createdAt),
                                          style: const TextStyle(
                                              color: Colors.grey, fontSize: 11)),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  SelectableText(m.content,
                                      style: const TextStyle(
                                          color: Color(0xFFDBDEE1), fontSize: 14)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
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
                icon: const Icon(Icons.send, size: 20),
                color: Colors.grey[400],
                onPressed: _send,
              ),
            ),
            onSubmitted: (_) => _send(),
          ),
        ),
      ],
    );
  }

  void _send() {
    context.read<SocketService>().sendMessage(_input.text);
    _input.clear();
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
