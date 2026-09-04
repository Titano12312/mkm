// TellAviv backend smoke test: text roundtrip + voice join + signaling relay.
// Usage: start the server first (`npm start`, optionally PORT=...), then:
//   npm run smoke            (defaults to http://localhost:3000)
//   TEST_URL=http://localhost:3001 npm run smoke
// Exits 0 when all checks pass, 1 otherwise.
const { io } = require('socket.io-client');

const URL = process.env.TEST_URL || 'http://localhost:3000';
const results = [];
const ok = (name, cond) => {
  results.push(`${cond ? 'PASS' : 'FAIL'} ${name}`);
  if (!cond) process.exitCode = 1;
};

const a = io(URL, { transports: ['websocket'] });
const b = io(URL, { transports: ['websocket'] });

const timeout = setTimeout(() => {
  console.log('TIMEOUT waiting for signaling roundtrip');
  process.exit(1);
}, 10000);

let gotMsg = null;
b.on('message:receive', (m) => {
  gotMsg = m;
});

// Wait for BOTH clients to be connected + joined before sending,
// otherwise the broadcast legitimately misses B (test sequencing, not server bug).
let connected = 0;
const maybeStart = () => {
  connected += 1;
  if (connected < 2) return;
  a.emit('channel:join', { channelId: 'general' });
  b.emit('channel:join', { channelId: 'general' });
  setTimeout(sendMsg, 500); // let joins land before sending
};

const sendMsg = () => {
  a.emit(
    'message:send',
    { channelId: 'general', authorId: 't1', authorName: 'TesterA', content: 'hello-build' },
    (ack) => {
      ok('message:send ack', ack && ack.ok === true);
      setTimeout(() => {
        ok('message:receive broadcast', gotMsg && gotMsg.content === 'hello-build');
        // Voice: A joins, B joins, A should see updated participant list.
        a.emit('voice:join', { channelId: 'lounge', userId: 't1', username: 'TesterA' });
      }, 500);
    },
  );
};

a.on('connect', () => {
  a.emit('user:online', { userId: 't1', username: 'TesterA' });
  maybeStart();
});
b.on('connect', maybeStart);

a.on('voice:update', (d) => {
  if (d.channelId === 'lounge' && d.participants.length === 1) {
    ok('voice:update 1 participant', true);
    b.emit('voice:join', { channelId: 'lounge', userId: 't2', username: 'TesterB' });
  }
  if (d.channelId === 'lounge' && d.participants.length === 2) {
    ok('voice:update 2 participants', true);
    // Signaling relay: B offers, A must receive it untouched.
    const target = d.participants.find((p) => p.userId === 't1').socketId;
    b.emit('webrtc:offer', { targetSocketId: target, sdp: { sdp: 'fake', type: 'offer' } });
  }
});

a.on('webrtc:offer', (d) => {
  ok('webrtc:offer relay', d.sdp && d.sdp.sdp === 'fake');
  clearTimeout(timeout);
  console.log(results.join('\n'));
  a.disconnect();
  b.disconnect();
  process.exit(process.exitCode || 0);
});
