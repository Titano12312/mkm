// TellAviv backend smoke test.
// Phase 1 (always): unauthenticated writes must be rejected.
// Phase 2 (only with TEST_JWT): full authed roundtrip (text + voice + signaling).
// Usage: start the server first (`npm start`, optionally PORT=...), then:
//   npm run smoke                                   (phase 1 only)
//   TEST_URL=https://host npm run smoke             (phase 1 against remote)
//   TEST_JWT=<supabase access_token> npm run smoke  (phase 1 + 2)
// Exits 0 when all checks pass, 1 otherwise.
const { io } = require('socket.io-client');

const URL = process.env.TEST_URL || 'http://localhost:3000';
const JWT = process.env.TEST_JWT || null;
const results = [];
const ok = (name, cond) => {
  results.push(`${cond ? 'PASS' : 'FAIL'} ${name}`);
  if (!cond) process.exitCode = 1;
};
const finish = () => {
  console.log(results.join('\n'));
  process.exit(process.exitCode || 0);
};
const timeout = setTimeout(() => {
  console.log('TIMEOUT');
  process.exit(1);
}, JWT ? 15000 : 8000);

// --- Phase 1: negative tests (no token) --------------------------------------
const x = io(URL, { transports: ['websocket'] });
let voiceJoined = false;
let voiceError = null;
x.on('voice:joined', () => {
  voiceJoined = true;
});
x.on('voice:error', (d) => {
  voiceError = d;
});
x.on('connect', () => {
  // Every write/guarded read without a token must be rejected.
  const cases = [
    ['message:send', { channelId: 'general', content: 'nope' }, 'unauth message:send rejected'],
    ['friend:request', { username: 'nope' }, 'unauth friend:request rejected'],
    ['conv:send', { conversationId: '00000000-0000-0000-0000-000000000000', content: 'nope' }, 'unauth conv:send rejected'],
    ['group:create', { name: 'nope', memberIds: [] }, 'unauth group:create rejected'],
    ['profile:set-username', { username: 'spoof' }, 'unauth profile:set-username rejected'],
    ['profile:set-avatar', { avatarUrl: 'https://x/y.jpg' }, 'unauth profile:set-avatar rejected'],
    ['profile:me', {}, 'unauth profile:me rejected'],
  ];
  const runCase = (i) => {
    if (i >= cases.length) {
      x.emit('voice:join', { channelId: 'lounge' });
      setTimeout(() => {
        ok('unauth voice:join rejected', !voiceJoined && !!voiceError);
        x.disconnect();
        if (JWT) phase2();
        else {
          clearTimeout(timeout);
          finish();
        }
      }, 800);
      return;
    }
    const [event, payload, name] = cases[i];
    x.emit(event, payload, (ack) => {
      ok(name, ack && ack.ok === false);
      runCase(i + 1);
    });
  };
  runCase(0);
});

// --- Phase 2: authed roundtrip (needs a real Supabase access token) ----------
function phase2() {
  const a = io(URL, { transports: ['websocket'] });
  const b = io(URL, { transports: ['websocket'] });
  let gotMsg = null;
  b.on('message:receive', (m) => {
    gotMsg = m;
  });

  let connected = 0;
  const maybeStart = () => {
    connected += 1;
    if (connected < 2) return;
    a.emit('channel:join', { channelId: 'general' });
    b.emit('channel:join', { channelId: 'general' });
    setTimeout(sendMsg, 500);
  };

  const sendMsg = () => {
    // NOTE: no author fields — server takes identity from the verified token.
    a.emit('message:send', { channelId: 'general', content: 'hello-build' }, (ack) => {
      ok('auth message:send ack', ack && ack.ok === true);
      setTimeout(() => {
        ok('auth message:receive broadcast', gotMsg && gotMsg.content === 'hello-build');
        a.emit('voice:join', { channelId: 'lounge' });
      }, 500);
    });
  };

  a.on('connect', () => {
    a.emit('auth:token', { token: JWT });
  });
  a.on('auth:ok', () => {
    ok('auth:token accepted', true);
    maybeStart();
  });
  a.on('auth:error', () => {
    ok('auth:token accepted', false);
    clearTimeout(timeout);
    finish();
  });
  b.on('connect', maybeStart);

  a.on('voice:update', (d) => {
    if (d.channelId === 'lounge' && d.participants.length === 1) {
      ok('voice:update 1 participant', true);
      b.emit('voice:join', { channelId: 'lounge' });
    }
    if (d.channelId === 'lounge' && d.participants.length === 2) {
      ok('voice:update 2 participants', true);
      const target = d.participants.find((p) => p.socketId !== a.id).socketId;
      b.emit('webrtc:offer', { targetSocketId: target, sdp: { sdp: 'fake', type: 'offer' } });
    }
  });

  // B is unauthenticated here on purpose: signaling relay stays open
  // (SDP/candidates are useless without a voice room seat, which needs auth).
  a.on('webrtc:offer', (d) => {
    ok('webrtc:offer relay', d.sdp && d.sdp.sdp === 'fake');
    clearTimeout(timeout);
    a.disconnect();
    b.disconnect();
    finish();
  });
}
