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
async function upsertProfile({ userId, username }) {
  if (!supabase) return;
  const { error } = await supabase.from('profiles').upsert(
    { user_id: userId, username, last_seen: new Date().toISOString() },
    { onConflict: 'user_id' },
  );
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
};
