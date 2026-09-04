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
const onlineUsers = new Map(); // socketId -> { userId, username }
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

app.get('/health', (_req, res) => res.json({ ok: true, service: 'tellaviv-backend' }));
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

  // -- Presence -------------------------------------------------------------
  socket.on('user:online', ({ userId, username } = {}) => {
    if (!userId || !username) return;
    const clean = String(username).slice(0, 32);
    onlineUsers.set(socket.id, { userId, username: clean });
    io.emit('user:presence', { online: [...onlineUsers.values()] });
    // Durable profile mirror (fire-and-forget: realtime never waits on DB).
    db.upsertProfile({ userId, username: clean });
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

  socket.on('message:send', ({ channelId, authorId, authorName, content } = {}, ack) => {
    const text = typeof content === 'string' ? content.trim().slice(0, 2000) : '';
    if (!TEXT_IDS.has(channelId) || !text) {
      if (typeof ack === 'function') ack({ ok: false, error: 'Invalid channel or empty message' });
      return;
    }
    const msg = {
      id: `${Date.now()}-${socket.id.slice(0, 6)}`,
      channelId,
      authorId: authorId || socket.id,
      authorName: String(authorName || 'Unknown').slice(0, 32),
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

  // -- Voice channels (click-to-join / click-to-leave) ------------------------
  socket.on('voice:join', async ({ channelId, userId, username } = {}) => {
    if (!VOICE_IDS.has(channelId)) return;
    // Discord rule: one voice room at a time — leave previous first.
    if (socketVoiceChannel.get(socket.id)?.channelId !== channelId) await leaveVoice(io, socket);

    const cleanUser = { userId: userId || socket.id, username: String(username || 'Unknown').slice(0, 32) };
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
      peer: { socketId: socket.id, userId: userId || socket.id, username: String(username || 'Unknown').slice(0, 32) },
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

  socket.on('disconnect', () => {
    console.log(`[-] disconnected ${socket.id}`);
    onlineUsers.delete(socket.id);
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
