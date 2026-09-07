/**
 * TellAviv push notifications (FCM) — DORMANT until Firebase is configured.
 *
 * WHAT WORKS TODAY (no setup): in-app toasts (MessageToastHost) + the
 * full-screen call overlay cover every event while the app is open.
 *
 * WHAT THIS MODULE ADDS LATER: system push when the app is closed/killed.
 * To activate:
 *   1. Create a Firebase project, add an Android app, download
 *      google-services.json (needed at Flutter build time for the app).
 *   2. In Firebase console: Project settings → Service accounts →
 *      Generate new private key.
 *   3. On the host (Render dashboard → Environment): set
 *      FIREBASE_SERVICE_ACCOUNT to the full JSON of that key.
 *   4. Add firebase_messaging + flutter_local_notifications to the app,
 *      send the FCM token via the `push:register` socket event.
 *
 * Until (3) is set, every send is a no-op (warned once). Nothing crashes,
 * nothing blocks: the server runs identically with or without push.
 */

let admin = null;
let initTried = false;
let warnedNoKey = false;

function getAdmin() {
  if (initTried) return admin;
  initTried = true;
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT;
  if (!raw) return null;
  try {
    // Lazy require: firebase-admin stays out of the boot path entirely.
    const adminLib = require('firebase-admin');
    adminLib.initializeApp({ credential: adminLib.credential.cert(JSON.parse(raw)) });
    admin = adminLib;
    console.log('[push] FCM enabled');
    return admin;
  } catch (err) {
    console.warn('[push] init failed, push disabled:', err.message);
    return null;
  }
}

const enabled = () => getAdmin() !== null;

/**
 * Best-effort push to every device token of a user. Invalid tokens are
 * pruned so the table doesn't rot. Never throws — callers don't await it.
 */
async function sendToUser(db, userId, { title, body, data = {} }) {
  if (!getAdmin()) {
    if (!warnedNoKey) {
      warnedNoKey = true;
      console.log('[push] FIREBASE_SERVICE_ACCOUNT unset — push skipped (in-app toasts still work)');
    }
    return;
  }
  let tokens = [];
  try {
    tokens = await db.getPushTokens(userId);
  } catch (err) {
    console.warn('[push] token lookup failed:', err.message);
    return;
  }
  const stringData = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)]));
  for (const token of tokens) {
    try {
      await admin.messaging().send({
        token,
        notification: { title, body },
        data: stringData,
        android: { priority: 'high' },
      });
    } catch (err) {
      // Dead token (uninstall): prune it. Anything else: log and continue.
      if (err.code === 'messaging/registration-token-not-registered') {
        try {
          await db.removePushToken(token);
        } catch (_) {/* ignore */}
      } else {
        console.warn('[push] send failed:', err.code || err.message);
      }
    }
  }
}

module.exports = { enabled, sendToUser };
