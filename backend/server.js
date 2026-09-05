/**
 * TellAviv Backend — Express + Socket.io
 *
 * Responsibilities:
 *  1. Text channels: room fan-out (joinChannel / sendMessage / receiveMessage).
 *  2. Presence: who is online.
 *  3. Voice channels: click-to-join presence + WebRTC mesh signaling
 *     (offer / answer / ice-candidate). No ring/answer flow — joining the
 *     room = joining the call.
 *
 * ARCHITECTURE NOTES
 * - Rooms are namespaced: `text:{id}` for chat, `voice:{id}` for voice.
 *   This keeps chat history/traffic isolated per channel and lets Socket.io
 *   handle fan-out instead of manual loops.
 * - Persistence: channel catalog + message history live in Supabase Postgres
 *   (see db.js). Presence + voice occupancy stay in-memory — they are
 *   ephemeral and Socket.io connection state is their source of truth.
 *   Without SUPABASE_URL/ANON_KEY the server falls back to pure in-memory.
 * - Voice audio itself is P2P (never touches this server); here we only
 *   exchange signaling + participant lists.
 */

require('dotenv').config();
const express = require('express');
const http = require('http');
const cors = require('cors');
const { Server } = require('socket.io');
const db = require('./db');

const PORT = process.env.PORT || 3000;

// ---------------------------------------------------------------------------
// Channel catalog: Supabase is source of truth, static list is boot fallback.
// Clients must treat it as read-only (synced via `channels:list` on connect).
// ---------------------------------------------------------------------------
let channels = structuredClone(db.FALLBACK_CHANNELS);
let TEXT_IDS = new Set(channels.text.map((c) => c.id));
let VOICE_IDS = new Set(channels.voice.map((c) => c.id));

// Write-through cache: realtime broadcast reads here; Supabase is the
// durable copy (see db.js). Bounded so a restart without DB stays healthy.
const HISTORY_LIMIT = db.HISTORY_LIMIT;
const messageHistory = new Map(); // channelId -> Array<message>
// Write-through cache for conversations (mirrors messageHistory).
const convHistory = new Map(); // conversationId -> Array<message>
const convRoom = (id) => `conv:${id}`;
const onlineUsers = new Map(); // socketId -> { userId, username }
const authed = new Map(); // socketId -> { userId, username } verified via Supabase JWT
const calls = new Map(); // callId -> { callerSocketId, callerUserId, callerUsername, calleeUserId, calleeSocketId?, state }
const voiceRooms = new Map(); // voiceChannelId -> Map<socketId, { userId, username }>
const socketVoiceChannel = new Map(); // socketId -> { channelId, ready: Promise<sessionId|null> }

const textRoom = (id) => `text:${id}`;
const voiceRoom = (id) => `voice:${id}`;

function voiceParticipants(channelId) {
  const room = voiceRooms.get(channelId);
  if (!room) return [];
  return [...room.entries()].map(([socketId, u]) => ({ socketId, ...u }));
}

function broadcastVoiceUpdate(io, channelId) {
  io.to(voiceRoom(channelId)).emit('voice:update', {
    channelId,
    participants: voiceParticipants(channelId),
  });
  // Global badge counts for the sidebar (who is in which voice channel).
  io.emit(
    'voice:directory',
    channels.voice.map((c) => ({ channelId: c.id, count: (voiceRooms.get(c.id) || new Map()).size })),
  );
}

async function leaveVoice(io, socket) {
  const entry = socketVoiceChannel.get(socket.id);
  if (!entry) return;
  const { channelId } = entry;
  socketVoiceChannel.delete(socket.id);
  socket.leave(voiceRoom(channelId));
  const room = voiceRooms.get(channelId);
  if (room) {
    room.delete(socket.id);
    if (room.size === 0) voiceRooms.delete(channelId);
  }
  // Tell remaining peers to tear down the P2P connection to this socket.
  socket.to(voiceRoom(channelId)).emit('voice:peer-left', { socketId: socket.id, channelId });
  broadcastVoiceUpdate(io, channelId);
  // Close the durable session row. `ready` is awaited (not fire-and-forget)
  // so a fast join→leave still closes the correct row instead of orphaning it.
  // Wrapped: leave must never throw (it also runs on disconnect).
  try {
    const sessionId = await entry.ready;
    await db.logVoiceLeave(sessionId);
  } catch (err) {
    console.warn('[voice] session close failed:', err.message);
  }
}

// ---------------------------------------------------------------------------
// HTTP + Socket.io bootstrap
// ---------------------------------------------------------------------------
const app = express();
app.use(cors({ origin: process.env.CLIENT_ORIGIN || '*' }));
app.use(express.json());

app.get('/health', (_req, res) =>
  res.json({ ok: true, service: 'tellaviv-backend', db: db.isEnabled() ? 'supabase' : 'memory' }),
);
app.get('/api/channels', (_req, res) => res.json(channels));

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: process.env.CLIENT_ORIGIN || '*', methods: ['GET', 'POST'] },
});

io.on('connection', (socket) => {
  console.log(`[+] connected ${socket.id}`);

  // Immediately sync channel catalog + voice occupancy so UI renders fast.
  socket.emit('channels:list', channels);
  socket.emit(
    'voice:directory',
    channels.voice.map((c) => ({ channelId: c.id, count: (voiceRooms.get(c.id) || new Map()).size })),
  );

  // -- Auth ---------------------------------------------------------------
  // Client sends the Supabase access token obtained at login (Google).
  // Identity for ALL writes comes from this verified token — client-sent
  // authorId/authorName fields are ignored, so impersonation is impossible.
  socket.on('auth:token', async ({ token } = {}) => {
    const identity = await db.verifyToken(token);
    if (!identity) {
      socket.emit('auth:error', { error: 'invalid-token' });
      return;
    }
    authed.set(socket.id, identity);
    onlineUsers.set(socket.id, identity);
    io.emit('user:presence', { online: [...onlineUsers.values()] });
    socket.emit('auth:ok', identity);
  });

  // -- Presence -------------------------------------------------------------
  // Pre-auth compat: shows the socket as online. No DB write here — profile
  // rows are written only from verified identities (auth:token), so a client
  // can never plant a spoofed profile.
  socket.on('user:online', ({ userId, username } = {}) => {
    if (!userId || !username) return;
    if (authed.has(socket.id)) return; // verified identity wins, ignore spoof
    const clean = String(username).slice(0, 32);
    onlineUsers.set(socket.id, { userId, username: clean });
    io.emit('user:presence', { online: [...onlineUsers.values()] });
  });

  // -- Text channels ---------------------------------------------------------
  socket.on('channel:join', async ({ channelId } = {}) => {
    if (!TEXT_IDS.has(channelId)) return;
    socket.join(textRoom(channelId));
    socket.emit('channel:joined', { channelId });
    // Replay recent history to the joiner only (not a broadcast).
    // Supabase first, memory cache when DB is disabled/unreachable.
    const persisted = await db.getHistory(channelId);
    if (persisted) messageHistory.set(channelId, persisted.slice(-HISTORY_LIMIT));
    socket.emit('channel:history', { channelId, messages: messageHistory.get(channelId) || [] });
  });

  socket.on('channel:leave', ({ channelId } = {}) => {
    if (channelId) socket.leave(textRoom(channelId));
  });

  socket.on('message:send', ({ channelId, content } = {}, ack) => {
    const fail = (error) => {
      if (typeof ack === 'function') ack({ ok: false, error });
    };
    // Writes require a verified identity — author fields are NEVER trusted
    // from the client (prevents impersonation).
    const identity = authed.get(socket.id);
    if (!identity) return fail('auth-required');
    const text = typeof content === 'string' ? content.trim().slice(0, 2000) : '';
    if (!TEXT_IDS.has(channelId) || !text) {
      return fail('Invalid channel or empty message');
    }
    const msg = {
      id: `${Date.now()}-${socket.id.slice(0, 6)}`,
      channelId,
      authorId: identity.userId,
      authorName: identity.username,
      content: text,
      createdAt: new Date().toISOString(),
    };
    const hist = messageHistory.get(channelId) || [];
    hist.push(msg);
    if (hist.length > HISTORY_LIMIT) hist.splice(0, hist.length - HISTORY_LIMIT);
    messageHistory.set(channelId, hist);

    io.to(textRoom(channelId)).emit('message:receive', msg);
    if (typeof ack === 'function') ack({ ok: true, id: msg.id });
    // Persist best-effort AFTER broadcast: realtime never waits on the DB.
    // A failed insert is logged in db.js; the memory cache still serves joins.
    db.saveMessage(msg);
  });

  // -- Social: friends, DMs, groups (opt-in) ----------------------------------
  // DMs are friends-only; groups are created explicitly and never automatic.
  const requireAuth = (ack) => {
    const identity = authed.get(socket.id);
    if (!identity && typeof ack === 'function') ack({ ok: false, error: 'auth-required' });
    return identity;
  };

  // Nudge all online sockets of a user (they refetch via friend:list /
  // conversation:list — no sensitive data pushed blindly).
  const emitToUser = (userId, event, data) => {
    for (const [sid, u] of onlineUsers.entries()) {
      if (u.userId === userId) io.to(sid).emit(event, data);
    }
  };

  socket.on('friend:request', async ({ username } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    const res = await db.requestFriend(me.userId, username);
    if (typeof ack === 'function') ack(res);
    if (res.ok && res.target) emitToUser(res.target.user_id, 'social:refresh', {});
  });

  socket.on('friend:accept', async ({ userId } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    const res = await db.acceptFriend(me.userId, userId);
    if (typeof ack === 'function') ack(res);
    if (res.ok) {
      emitToUser(userId, 'social:refresh', {});
      emitToUser(me.userId, 'social:refresh', {});
    }
  });

  socket.on('friend:decline', async ({ userId } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    const res = await db.declineFriend(me.userId, userId);
    if (typeof ack === 'function') ack(res);
  });

  socket.on('friend:list', async (_, ack) => {
    const me = authed.get(socket.id);
    if (!me) {
      if (typeof ack === 'function') ack({ ok: false, error: 'auth-required' });
      return;
    }
    const social = await db.listSocial(me.userId);
    // Annotate live presence from memory (the DB can't know socket state).
    const onlineIds = new Set([...onlineUsers.values()].map((u) => u.userId));
    for (const f of social.friends) f.online = onlineIds.has(f.userId);
    if (typeof ack === 'function') ack({ ok: true, ...social });
  });

  socket.on('conversation:list', async (_, ack) => {
    const me = authed.get(socket.id);
    if (!me) {
      if (typeof ack === 'function') ack({ ok: false, error: 'auth-required' });
      return;
    }
    const conversations = await db.getMyConversations(me.userId);
    // Auto-join every conversation room so DMs arrive even while browsing
    // a server channel (the #1 "messages don't arrive" class of bug).
    for (const c of conversations) socket.join(convRoom(c.id));
    if (typeof ack === 'function') ack({ ok: true, conversations });
  });

  socket.on('dm:open', async ({ friendId } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    if (!(await db.areFriends(me.userId, friendId))) {
      if (typeof ack === 'function') ack({ ok: false, error: 'not-friends' });
      return;
    }
    const conversationId = await db.findOrCreateDm(me.userId, friendId);
    if (!conversationId) {
      if (typeof ack === 'function') ack({ ok: false, error: 'db-error' });
      return;
    }
    socket.join(convRoom(conversationId));
    if (typeof ack === 'function') ack({ ok: true, conversationId });
    const persisted = await db.getDmHistory(conversationId);
    if (persisted) convHistory.set(conversationId, persisted.slice(-HISTORY_LIMIT));
    socket.emit('dm:history', { conversationId, messages: convHistory.get(conversationId) || [] });
  });

  socket.on('conv:history', async ({ conversationId } = {}) => {
    const me = authed.get(socket.id);
    if (!me || !conversationId) return;
    if (!(await db.isMember(conversationId, me.userId))) return;
    socket.join(convRoom(conversationId));
    const persisted = await db.getDmHistory(conversationId);
    if (persisted) convHistory.set(conversationId, persisted.slice(-HISTORY_LIMIT));
    socket.emit('dm:history', { conversationId, messages: convHistory.get(conversationId) || [] });
  });

  socket.on('conv:send', async ({ conversationId, content } = {}, ack) => {
    const fail = (error) => {
      if (typeof ack === 'function') ack({ ok: false, error });
    };
    const me = authed.get(socket.id);
    if (!me) return fail('auth-required');
    if (!conversationId || !(await db.isMember(conversationId, me.userId))) {
      return fail('not-member');
    }
    const text = typeof content === 'string' ? content.trim().slice(0, 2000) : '';
    if (!text) return fail('empty');
    const msg = {
      id: `${Date.now()}-${socket.id.slice(0, 6)}`,
      conversationId,
      authorId: me.userId,
      authorName: me.username,
      content: text,
      createdAt: new Date().toISOString(),
    };
    const hist = convHistory.get(conversationId) || [];
    hist.push(msg);
    if (hist.length > HISTORY_LIMIT) hist.splice(0, hist.length - HISTORY_LIMIT);
    convHistory.set(conversationId, hist);

    io.to(convRoom(conversationId)).emit('dm:receive', msg);
    if (typeof ack === 'function') ack({ ok: true, id: msg.id });
    // Persist best-effort AFTER broadcast (realtime never waits on the DB).
    db.saveDmMessage(msg);
  });

  socket.on('group:create', async ({ name, memberIds } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    const ids = [...new Set((memberIds || []).filter((id) => id && id !== me.userId))];
    // Groups are friends-only: every invitee must already be a friend.
    for (const id of ids) {
      if (!(await db.areFriends(me.userId, id))) {
        if (typeof ack === 'function') ack({ ok: false, error: 'not-friends' });
        return;
      }
    }
    const res = await db.createGroup(me.userId, name, ids);
    if (typeof ack === 'function') ack(res);
    if (res.ok) {
      socket.join(convRoom(res.conversationId));
      for (const id of ids) emitToUser(id, 'social:refresh', {});
      emitToUser(me.userId, 'social:refresh', {});
    }
  });

  socket.on('group:leave', async ({ conversationId } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    socket.leave(convRoom(conversationId));
    const res = await db.leaveGroup(conversationId, me.userId);
    if (typeof ack === 'function') ack(res);
    const members = await db.getMembers(conversationId).catch(() => []);
    io.to(convRoom(conversationId)).emit('conv:update', { conversationId, members });
  });

  // -- Profile: own row, rename, avatar ---------------------------------------
  socket.on('profile:me', async (_, ack) => {
    const me = authed.get(socket.id);
    if (!me) {
      if (typeof ack === 'function') ack({ ok: false, error: 'auth-required' });
      return;
    }
    const p = await db.getProfile(me.userId);
    if (typeof ack === 'function') {
      ack({
        ok: true,
        profile: p
          ? { userId: p.user_id, username: p.username, email: p.email, avatarUrl: p.avatar_url }
          : null,
      });
    }
  });

  socket.on('profile:set-username', async ({ username } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    const res = await db.setUsername(me.userId, username);
    if (res.ok) {
      // Identity everywhere follows the rename immediately: future
      // messages, presence, and the client's own display (via auth:ok).
      authed.set(socket.id, { userId: me.userId, username: res.username });
      onlineUsers.set(socket.id, { userId: me.userId, username: res.username });
      io.emit('user:presence', { online: [...onlineUsers.values()] });
      socket.emit('auth:ok', { userId: me.userId, username: res.username });
      emitToUser(me.userId, 'social:refresh', {});
    }
    if (typeof ack === 'function') ack(res);
  });

  socket.on('profile:set-avatar', async ({ avatarUrl } = {}, ack) => {
    const me = requireAuth(ack);
    if (!me) return;
    const res = await db.setAvatarUrl(me.userId, avatarUrl);
    if (typeof ack === 'function') ack(res);
    if (res.ok) emitToUser(me.userId, 'social:refresh', {});
  });

  // -- Voice channels (click-to-join / click-to-leave) ------------------------
  socket.on('voice:join', async ({ channelId } = {}) => {
    if (!VOICE_IDS.has(channelId)) {
      socket.emit('voice:error', { error: 'unknown-channel' });
      return;
    }
    // Voice seats require auth (sessions are logged under verified identity).
    const identity = authed.get(socket.id);
    if (!identity) {
      socket.emit('voice:error', { error: 'auth-required' });
      return;
    }
    // Discord rule: one voice room at a time — leave previous first.
    if (socketVoiceChannel.get(socket.id)?.channelId !== channelId) await leaveVoice(io, socket);

    const cleanUser = { userId: identity.userId, username: identity.username };
    socket.join(voiceRoom(channelId));
    if (!voiceRooms.has(channelId)) voiceRooms.set(channelId, new Map());
    voiceRooms.get(channelId).set(socket.id, cleanUser);
    // Durable session row opens in the background; `ready` never rejects,
    // so leaveVoice can safely await it even on a fast join→leave.
    const ready = db.logVoiceJoin({ channelId, ...cleanUser }).catch(() => null);
    socketVoiceChannel.set(socket.id, { channelId, ready });

    // Tell the joiner who is already here so it can initiate mesh offers.
    socket.emit('voice:joined', { channelId, selfId: socket.id, participants: voiceParticipants(channelId) });
    // Tell existing peers a new peer arrived (they wait for its offer).
    socket.to(voiceRoom(channelId)).emit('voice:peer-joined', {
      channelId,
      peer: { socketId: socket.id, userId: cleanUser.userId, username: cleanUser.username },
    });
    broadcastVoiceUpdate(io, channelId);
  });

  socket.on('voice:leave', async () => leaveVoice(io, socket));

  // -- WebRTC signaling relay (mesh). Server never inspects SDP/candidates,
  //    it just routes them to targetSocketId. --------------------------------
  socket.on('webrtc:offer', ({ targetSocketId, sdp } = {}) => {
    if (!targetSocketId || !sdp) return;
    io.to(targetSocketId).emit('webrtc:offer', { fromSocketId: socket.id, sdp });
  });
  socket.on('webrtc:answer', ({ targetSocketId, sdp } = {}) => {
    if (!targetSocketId || !sdp) return;
    io.to(targetSocketId).emit('webrtc:answer', { fromSocketId: socket.id, sdp });
  });
  socket.on('webrtc:ice-candidate', ({ targetSocketId, candidate } = {}) => {
    if (!targetSocketId || !candidate) return;
    io.to(targetSocketId).emit('webrtc:ice-candidate', { fromSocketId: socket.id, candidate });
  });

  // -- 1:1 calls (audio): invite → accept/decline → P2P via generic webrtc relay.
  // Unlike voice rooms (click-to-join, no ringing), a DM call rings the
  // callee on every online device; first accept wins, the rest are cancelled.
  const callRoom = (id) => `call:${id}`;
  const RING_TIMEOUT_MS = 45000;

  function endCall(callId, reason) {
    const c = calls.get(callId);
    if (!c) return;
    calls.delete(callId);
    io.to(callRoom(callId)).emit('call:ended', { callId, reason });
  }

  socket.on('call:invite', async ({ targetUserId } = {}, ack) => {
    const fail = (error) => {
      if (typeof ack === 'function') ack({ ok: false, error });
    };
    const me = authed.get(socket.id);
    if (!me) return fail('auth-required');
    if (!targetUserId || targetUserId === me.userId) return fail('invalid');
    if (!(await db.areFriends(me.userId, targetUserId))) return fail('not-friends');
    // One outgoing call at a time: end the previous one first.
    for (const [id, c] of calls) {
      if (c.callerSocketId === socket.id && c.state !== 'ended') endCall(id, 'replaced');
    }
    const callId = `${Date.now()}-${socket.id.slice(0, 6)}`;
    calls.set(callId, {
      callerSocketId: socket.id,
      callerUserId: me.userId,
      callerUsername: me.username,
      calleeUserId: targetUserId,
      state: 'ringing',
    });
    emitToUser(targetUserId, 'call:incoming', {
      callId,
      fromUserId: me.userId,
      fromUsername: me.username,
    });
    if (typeof ack === 'function') ack({ ok: true, callId });
    setTimeout(() => {
      const c = calls.get(callId);
      if (c && c.state === 'ringing') endCall(callId, 'missed');
    }, RING_TIMEOUT_MS);
  });

  socket.on('call:accept', ({ callId } = {}, ack) => {
    const fail = (error) => {
      if (typeof ack === 'function') ack({ ok: false, error });
    };
    const me = authed.get(socket.id);
    const c = calls.get(callId);
    if (!me || !c || c.state !== 'ringing' || c.calleeUserId !== me.userId) {
      return fail('invalid');
    }
    c.state = 'active';
    c.calleeSocketId = socket.id;
    // Callee's other devices: stop ringing them.
    emitToUser(c.calleeUserId, 'call:cancelled', { callId });
    socket.join(callRoom(callId));
    const caller = io.sockets.sockets.get(c.callerSocketId);
    if (caller) caller.join(callRoom(callId));
    // Both sides learn each other's socket for direct P2P negotiation.
    // Caller initiates the offer (Discord-style: the dialer starts).
    io.to(c.callerSocketId).emit('call:accepted', {
      callId,
      peerSocketId: socket.id,
      peerUserId: me.userId,
      peerUsername: me.username,
      initiator: true,
    });
    socket.emit('call:accepted', {
      callId,
      peerSocketId: c.callerSocketId,
      peerUserId: c.callerUserId,
      peerUsername: c.callerUsername || 'Friend',
      initiator: false,
    });
    if (typeof ack === 'function') ack({ ok: true });
  });

  socket.on('call:decline', ({ callId } = {}) => {
    const me = authed.get(socket.id);
    const c = calls.get(callId);
    if (!me || !c || c.calleeUserId !== me.userId) return;
    endCall(callId, 'declined');
  });

  socket.on('call:end', ({ callId } = {}) => {
    const me = authed.get(socket.id);
    const c = calls.get(callId);
    if (!me || !c) return;
    if (c.callerUserId !== me.userId && c.calleeUserId !== me.userId) return;
    endCall(callId, 'ended');
  });

  // -- Typing indicators (ephemeral: broadcast only, never persisted) --------
  // Powers the "X is typing…" row in channels AND conversations.
  // Authed-only so names can't be spoofed.
  for (const [event, typing] of [['typing:start', true], ['typing:stop', false]]) {
    socket.on(event, async ({ channelId, conversationId } = {}) => {
      const identity = authed.get(socket.id);
      if (!identity) return;
      const payload = {
        userId: identity.userId,
        username: identity.username,
        typing,
      };
      if (conversationId) {
        if (!(await db.isMember(conversationId, identity.userId))) return;
        socket.to(convRoom(conversationId)).emit('typing:update', { ...payload, conversationId });
        return;
      }
      if (!TEXT_IDS.has(channelId)) return;
      socket.to(textRoom(channelId)).emit('typing:update', { ...payload, channelId });
    });
  }

  socket.on('disconnect', () => {
    console.log(`[-] disconnected ${socket.id}`);
    onlineUsers.delete(socket.id);
    authed.delete(socket.id);
    // Hang up any call this socket was part of so the peer isn't left ringing.
    for (const [id, c] of [...calls]) {
      if (c.callerSocketId === socket.id || c.calleeSocketId === socket.id) {
        endCall(id, 'ended');
      }
    }
    io.emit('user:presence', { online: [...onlineUsers.values()] });
    leaveVoice(io, socket);
  });
});

// Boot: load channel catalog (DB or fallback) before accepting sockets,
// so the first `channels:list` a client receives is already correct.
(async () => {
  channels = await db.loadChannels();
  TEXT_IDS = new Set(channels.text.map((c) => c.id));
  VOICE_IDS = new Set(channels.voice.map((c) => c.id));
  server.listen(PORT, () =>
    console.log(`TellAviv backend listening on :${PORT} (db=${db.isEnabled() ? 'supabase' : 'memory'})`),
  );
})();
