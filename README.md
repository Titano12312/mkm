# TellAviv — private Discord-like messenger for friends

Mono-repo: `backend/` (Node.js + Socket.io) + `frontend/` (Flutter Windows + Android).

## Architecture

```text
Flutter (Windows / Android)
  │  Socket.io (text + presence + signaling)
  ▼
Node.js + Express + Socket.io  (/backend/server.js)
  ├── text:{channelId} rooms  → chat fan-out
  └── voice:{channelId} rooms → presence + WebRTC mesh signaling
        │
        ▼
  WebRTC P2P mesh (flutter_webrtc, no ring/answer — click-to-join)
```

> Voice MVP = full-mesh P2P. Fine for ≤6 friends. If you grow, swap in LiveKit / mediasoup SFU
> without changing the client event contract — only `VoiceService` internals change.

## Quick start

### 1. Backend

```powershell
cd backend
npm install
Copy-Item .env.example .env   # add SUPABASE_URL + SUPABASE_ANON_KEY for persistence
npm run dev   # http://localhost:3000
```

> Persistence: channel catalog + chat history live in Supabase Postgres
> (`backend/db.js`). Without credentials the server runs in-memory —
> presence/voice are always in-memory (ephemeral by design).

### 2. Frontend

```powershell
cd frontend
flutter pub get
# Point SocketService at your LAN IP for phone testing:
#   --dart-define=API_URL=http://192.168.1.10:3000
flutter run -d windows --dart-define=API_URL=http://localhost:3000
flutter run --dart-define=API_URL=http://192.168.1.10:3000
```

### 3. Release builds

```powershell
# Android APK (default URL baked in: production backend on Render)
flutter build apk --release --dart-define=API_URL=https://tellaviv-backend.onrender.com
# Windows
flutter build windows --release --dart-define=API_URL=https://tellaviv-backend.onrender.com
# Inno Setup wizard (after Windows build)
iscc installer\tellaviv.iss
```

> The apps also accept a runtime server override (sidebar → Server URL),
> so they can follow the backend without rebuilding.

See `tools/` for scripted builds.
