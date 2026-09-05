/**
 * TellAviv DB layer — Supabase (Postgres) with transparent in-memory fallback.
 *
 * WHAT LIVES IN THE DB (durable): channel catalog, text message history,
 * user profiles, voice session history (join/leave log).
 * WHAT STAYS IN MEMORY (ephemeral by nature): live presence, current voice
 * room occupancy. Presence in a DB would be stale the moment a socket drops —
 * Socket.io connection state is already the source of truth for it.
 *
 * ACTIVATION: set SUPABASE_URL + SUPABASE_ANON_KEY in .env. When unset, every
 * function degrades to the fallback path and the server behaves exactly like
 * the original in-memory MVP (dev without credentials, offline demos).
 *
 * SECURITY: the backend uses the publishable (anon) key, so RLS policies
 * apply. The migration grants anon only: SELECT on channels, SELECT+INSERT on
 * messages. No UPDATE/DELETE for anon — history is append-only.
 */

const HISTORY_LIMIT = 100;

const FALLBACK_CHANNELS = {
  text: [
    { id: 'general', name: 'general' },
    { id: 'random', name: 'random' },
    { id: 'gaming', name: 'gaming' },
  ],
  voice: [
    { id: 'lounge', name: 'Lounge' },
    { id: 'gaming-voice', name: 'Gaming' },
  ],
};

let supabase = null;
if (process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY) {
  // Lazy require so the dep is optional when running pure in-memory.
  const { createClient } = require('@supabase/supabase-js');
  supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY);
  console.log('[db] Supabase persistence enabled');
} else {
  console.log('[db] SUPABASE_URL/ANON_KEY unset — using in-memory fallback');
}

const isEnabled = () => supabase !== null;

/**
 * Verify a Supabase access token (sent by the Flutter app after Google login).
 * Returns { userId, username } or null. Also refreshes the profile row, so
 * `profiles` mirrors every user that ever authenticated — no separate
 * signup endpoint needed (open registration = first login creates profile).
 * In fallback mode (no env) there is no verifier → always null, and the
 * server runs read-only (joins/history work, writes are rejected).
 */
async function verifyToken(token) {
  if (!supabase || typeof token !== 'string' || !token) return null;
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data || !data.user) {
    console.warn('[db] verifyToken rejected:', error ? error.message : 'no user');
    return null;
  }
  const u = data.user;
  const meta = u.user_metadata || {};
  const username = String(
    meta.full_name || meta.name || (u.email || '').split('@')[0] || 'Unknown',
  ).slice(0, 32);
  await upsertProfile({ userId: u.id, username, email: u.email || null });
  return { userId: u.id, username };
}

function fromRow(r) {
  return {
    id: r.id,
    channelId: r.channel_id,
    authorId: r.author_id,
    authorName: r.author_name,
    content: r.content,
    createdAt: new Date(r.created_at).toISOString(),
  };
}

/** Channel catalog. DB is source of truth; fallback keeps dev running. */
async function loadChannels() {
  if (!supabase) return structuredClone(FALLBACK_CHANNELS);
  const { data, error } = await supabase.from('channels').select('id,name,kind');
  if (error) {
    console.warn('[db] loadChannels failed, using fallback:', error.message);
    return structuredClone(FALLBACK_CHANNELS);
  }
  return {
    text: data.filter((c) => c.kind === 'text').map(({ id, name }) => ({ id, name })),
    voice: data.filter((c) => c.kind === 'voice').map(({ id, name }) => ({ id, name })),
  };
}

/**
 * Last N messages of a channel, oldest-first (chat UI order).
 * Returns null when persistence is disabled → caller uses the memory cache.
 */
async function getHistory(channelId) {
  if (!supabase) return null;
  const { data, error } = await supabase
    .from('messages')
    .select('id,channel_id,author_id,author_name,content,created_at')
    .eq('channel_id', channelId)
    .order('created_at', { ascending: false })
    .limit(HISTORY_LIMIT);
  if (error) {
    console.warn('[db] getHistory failed:', error.message);
    return null;
  }
  return data.reverse().map(fromRow);
}

/** Best-effort persist. Returns true on success, false otherwise (logged). */
async function saveMessage(msg) {
  if (!supabase) return true; // nothing to persist in fallback mode
  const { error } = await supabase.from('messages').insert({
    id: msg.id,
    channel_id: msg.channelId,
    author_id: msg.authorId,
    author_name: msg.authorName,
    content: msg.content,
  });
  if (error) {
    console.warn('[db] saveMessage failed:', error.message);
    return false;
  }
  return true;
}

/** Upsert profile on every `user:online` (also refreshes last_seen). */
async function upsertProfile({ userId, username, email = null }) {
  if (!supabase) return;
  const row = { user_id: userId, username, last_seen: new Date().toISOString() };
  if (email) row.email = email;
  const { error } = await supabase.from('profiles').upsert(row, { onConflict: 'user_id' });
  if (error) console.warn('[db] upsertProfile failed:', error.message);
}

/**
 * Open a voice session row on channel join. Resolves to the session id
 * (uuid) or null when persistence is disabled/failed. Never throws —
 * callers store the promise and await it on leave, so a fast
 * join→leave still closes the right row.
 */
async function logVoiceJoin({ channelId, userId, username }) {
  if (!supabase) return null;
  const { data, error } = await supabase
    .from('voice_sessions')
    .insert({ channel_id: channelId, user_id: userId, username })
    .select('id')
    .single();
  if (error) {
    console.warn('[db] logVoiceJoin failed:', error.message);
    return null;
  }
  return data.id;
}

/** Close a voice session row. No-op on null id (fallback mode). */
async function logVoiceLeave(sessionId) {
  if (!supabase || !sessionId) return;
  const { error } = await supabase
    .from('voice_sessions')
    .update({ left_at: new Date().toISOString() })
    .eq('id', sessionId)
    .is('left_at', null);
  if (error) console.warn('[db] logVoiceLeave failed:', error.message);
}

// ---------------------------------------------------------------------------
// Social: friends, DM/group conversations (all no-ops in fallback mode).
// Every function assumes the caller already verified the JWT identity.
// ---------------------------------------------------------------------------

/** Close a voice session row. No-op on null id (fallback mode). */
async function logVoiceLeave(sessionId) {
  if (!supabase || !sessionId) return;
  const { error } = await supabase
    .from('voice_sessions')
    .update({ left_at: new Date().toISOString() })
    .eq('id', sessionId)
    .is('left_at', null);
  if (error) console.warn('[db] logVoiceLeave failed:', error.message);
}

/** Find a user by email (case-insensitive) for friend requests. */
async function findUserByEmail(email) {
  if (!supabase || !email) return null;
  const { data, error } = await supabase
    .from('profiles')
    .select('user_id,username,email')
    .ilike('email', String(email).trim())
    .limit(1);
  if (error || !data || data.length === 0) return null;
  return data[0];
}

async function getProfiles(userIds) {
  if (!supabase || userIds.length === 0) return new Map();
  const { data, error } = await supabase.from('profiles').select('user_id,username,email').in('user_id', userIds);
  if (error) {
    console.warn('[db] getProfiles failed:', error.message);
    return new Map();
  }
  return new Map(data.map((p) => [p.user_id, p]));
}

/** Send a friend request. Returns { ok, error?, target? }. */
async function requestFriend(requesterId, targetEmail) {
  if (!supabase) return { ok: false, error: 'db-unavailable' };
  const target = await findUserByEmail(targetEmail);
  if (!target) return { ok: false, error: 'not-found' };
  if (target.user_id === requesterId) return { ok: false, error: 'self' };
  const { data: existing } = await supabase
    .from('friendships')
    .select('status')
    .eq('user_id', requesterId)
    .eq('friend_id', target.user_id)
    .limit(1);
  if (existing && existing.length > 0) {
    return { ok: false, error: existing[0].status === 'accepted' ? 'already-friends' : 'already-pending' };
  }
  // Target may have requested us first → instant mutual accept.
  const { data: reverse } = await supabase
    .from('friendships')
    .select('status')
    .eq('user_id', target.user_id)
    .eq('friend_id', requesterId)
    .limit(1);
  if (reverse && reverse.length > 0 && reverse[0].status === 'pending') {
    await acceptFriend(requesterId, target.user_id);
    return { ok: true, accepted: true, target };
  }
  const { error } = await supabase
    .from('friendships')
    .insert({ user_id: requesterId, friend_id: target.user_id, status: 'pending' });
  if (error) {
    console.warn('[db] requestFriend failed:', error.message);
    return { ok: false, error: 'db-error' };
  }
  return { ok: true, target };
}

/** Accept a pending request from requesterId (called by the target user). */
async function acceptFriend(userId, requesterId) {
  if (!supabase) return { ok: false };
  const { error: e1 } = await supabase
    .from('friendships')
    .update({ status: 'accepted' })
    .eq('user_id', requesterId)
    .eq('friend_id', userId)
    .eq('status', 'pending');
  if (e1) {
    console.warn('[db] acceptFriend failed:', e1.message);
    return { ok: false };
  }
  // Mirror row so friendship checks are a single-row lookup either way.
  await supabase.from('friendships').upsert(
    { user_id: userId, friend_id: requesterId, status: 'accepted' },
    { onConflict: 'user_id,friend_id' },
  );
  return { ok: true };
}

async function declineFriend(userId, requesterId) {
  if (!supabase) return { ok: false };
  await supabase.from('friendships').delete().eq('user_id', requesterId).eq('friend_id', userId);
  return { ok: true };
}

async function areFriends(a, b) {
  if (!supabase) return false;
  const { data } = await supabase
    .from('friendships')
    .select('status')
    .eq('user_id', a)
    .eq('friend_id', b)
    .eq('status', 'accepted')
    .limit(1);
  return !!(data && data.length > 0);
}

/** Full social snapshot for friend:list. */
async function listSocial(userId) {
  if (!supabase) return { friends: [], pendingIn: [], pendingOut: [] };
  const { data: mine } = await supabase.from('friendships').select('friend_id,status').eq('user_id', userId);
  const rows = mine || [];
  const friendIds = rows.filter((r) => r.status === 'accepted').map((r) => r.friend_id);
  const outIds = rows.filter((r) => r.status === 'pending').map((r) => r.friend_id);
  const { data: incoming } = await supabase
    .from('friendships')
    .select('user_id')
    .eq('friend_id', userId)
    .eq('status', 'pending');
  const inIds = (incoming || []).map((r) => r.user_id);
  const profiles = await getProfiles([...new Set([...friendIds, ...outIds, ...inIds])]);
  const shape = (id) => {
    const p = profiles.get(id);
    return { userId: id, username: (p && p.username) || 'Unknown', email: (p && p.email) || null };
  };
  return {
    friends: friendIds.map(shape),
    pendingIn: inIds.map(shape),
    pendingOut: outIds.map(shape),
  };
}

/** Find the 1:1 dm conversation between a and b, or create it. */
async function findOrCreateDm(a, b) {
  // Candidate: my dm conversations; match the one with exactly {a,b}.
  const { data: mine } = await supabase
    .from('conversation_members')
    .select('conversation_id, conversations!inner(id,kind)')
    .eq('user_id', a)
    .eq('conversations.kind', 'dm');
  for (const row of mine || []) {
    const members = await getMembers(row.conversation_id);
    const ids = members.map((m) => m.userId).sort();
    if (ids.length === 2 && ids[0] === [...[a, b]].sort()[0] && ids[1] === [...[a, b]].sort()[1]) {
      return row.conversation_id;
    }
  }
  const { data: conv, error } = await supabase
    .from('conversations')
    .insert({ kind: 'dm', created_by: a })
    .select('id')
    .single();
  if (error) {
    console.warn('[db] findOrCreateDm failed:', error.message);
    return null;
  }
  await supabase.from('conversation_members').insert([{ conversation_id: conv.id, user_id: a }, { conversation_id: conv.id, user_id: b }]);
  return conv.id;
}

async function getMembers(conversationId) {
  const { data } = await supabase
    .from('conversation_members')
    .select('user_id')
    .eq('conversation_id', conversationId);
  const ids = (data || []).map((r) => r.user_id);
  const profiles = await getProfiles(ids);
  return ids.map((id) => {
    const p = profiles.get(id);
    return { userId: id, username: (p && p.username) || 'Unknown' };
  });
}

async function isMember(conversationId, userId) {
  if (!supabase) return false;
  const { data } = await supabase
    .from('conversation_members')
    .select('user_id')
    .eq('conversation_id', conversationId)
    .eq('user_id', userId)
    .limit(1);
  return !!(data && data.length > 0);
}

/** All conversations I'm in, with members (client derives DM titles). */
async function getMyConversations(userId) {
  if (!supabase) return [];
  const { data: mine } = await supabase.from('conversation_members').select('conversation_id').eq('user_id', userId);
  const ids = (mine || []).map((r) => r.conversation_id);
  if (ids.length === 0) return [];
  const { data: convs } = await supabase.from('conversations').select('id,kind,name,created_by').in('id', ids);
  const out = [];
  for (const c of convs || []) {
    out.push({ id: c.id, kind: c.kind, name: c.name, members: await getMembers(c.id) });
  }
  return out;
}

async function createGroup(creatorId, name, memberIds) {
  const clean = String(name || '').trim().slice(0, 40) || 'Group';
  const unique = [...new Set([creatorId, ...(memberIds || [])])];
  if (unique.length < 2) return { ok: false, error: 'need-members' };
  const { data: conv, error } = await supabase
    .from('conversations')
    .insert({ kind: 'group', name: clean, created_by: creatorId })
    .select('id')
    .single();
  if (error) {
    console.warn('[db] createGroup failed:', error.message);
    return { ok: false, error: 'db-error' };
  }
  await supabase
    .from('conversation_members')
    .insert(unique.map((userId) => ({ conversation_id: conv.id, user_id: userId })));
  return { ok: true, conversationId: conv.id };
}

async function leaveGroup(conversationId, userId) {
  await supabase.from('conversation_members').delete().eq('conversation_id', conversationId).eq('user_id', userId);
  const remaining = await getMembers(conversationId);
  if (remaining.length === 0) {
    await supabase.from('conversations').delete().eq('id', conversationId);
  }
  return { ok: true };
}

async function getDmHistory(conversationId) {
  if (!supabase) return null;
  const { data, error } = await supabase
    .from('dm_messages')
    .select('id,conversation_id,author_id,author_name,content,created_at')
    .eq('conversation_id', conversationId)
    .order('created_at', { ascending: false })
    .limit(HISTORY_LIMIT);
  if (error) {
    console.warn('[db] getDmHistory failed:', error.message);
    return null;
  }
  return data.reverse().map((r) => ({
    id: r.id,
    conversationId: r.conversation_id,
    authorId: r.author_id,
    authorName: r.author_name,
    content: r.content,
    createdAt: new Date(r.created_at).toISOString(),
  }));
}

async function saveDmMessage(msg) {
  if (!supabase) return true;
  const { error } = await supabase.from('dm_messages').insert({
    id: msg.id,
    conversation_id: msg.conversationId,
    author_id: msg.authorId,
    author_name: msg.authorName,
    content: msg.content,
  });
  if (error) {
    console.warn('[db] saveDmMessage failed:', error.message);
    return false;
  }
  return true;
}

module.exports = {
  HISTORY_LIMIT,
  FALLBACK_CHANNELS,
  isEnabled,
  loadChannels,
  getHistory,
  saveMessage,
  upsertProfile,
  logVoiceJoin,
  logVoiceLeave,
  verifyToken,
  findUserByEmail,
  requestFriend,
  acceptFriend,
  declineFriend,
  areFriends,
  listSocial,
  findOrCreateDm,
  getMembers,
  isMember,
  getMyConversations,
  createGroup,
  leaveGroup,
  getDmHistory,
  saveDmMessage,
};
