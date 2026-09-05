import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'socket_service.dart';

/// VoiceService — click-to-join / click-to-leave voice rooms (no ring/answer).
///
/// TOPOLOGY: full-mesh P2P. Each joiner creates one RTCPeerConnection per
/// existing peer (initiator = the joiner). Signaling goes through Socket.io
/// (`webrtc:offer/answer/ice-candidate`); audio flows peer-to-peer.
/// Good for a small friends group (≤6). Beyond that, replace internals with
/// a LiveKit/mediasoup SFU client — the UI contract (join/leave/muted) stays.
///
/// STUN: Google public STUN for NAT traversal. Add TURN (e.g. coturn /
/// Cloudflare) for symmetric-NAT reliability before production use.
class VoiceService extends ChangeNotifier {
  final SocketService signaling;
  VoiceService(this.signaling);

  final Map<String, RTCPeerConnection> _peers = {};
  MediaStream? _localStream;
  bool muted = false;
  bool inCall = false;

  static const _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  Future<void> _ensureHandlers() async {
    final s = signaling.rawSocket;
    if (s == null || s.hasListeners('webrtc:offer')) return;

    // A new peer joined after us → it will send the offer; nothing to do yet.
    s.on('voice:peer-joined', (data) {
      // Joiner initiates, so existing members just wait for its offer.
      if (kDebugMode) print('voice peer joined: $data');
    });
    s.on('voice:peer-left', (data) async {
      final m = Map<String, dynamic>.from(data as Map);
      await _removePeer(m['socketId'] as String);
    });

    s.on('webrtc:offer', (data) async {
      final m = Map<String, dynamic>.from(data as Map);
      await _onOffer(m['fromSocketId'] as String, m['sdp']);
    });
    s.on('webrtc:answer', (data) async {
      final m = Map<String, dynamic>.from(data as Map);
      await _peers[m['fromSocketId']]?.setRemoteDescription(
        RTCSessionDescription(m['sdp']['sdp'], m['sdp']['type']),
      );
    });
    s.on('webrtc:ice-candidate', (data) async {
      final m = Map<String, dynamic>.from(data as Map);
      final c = Map<String, dynamic>.from(m['candidate']);
      await _peers[m['fromSocketId']]?.addCandidate(
        RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
      );
    });
  }

  Future<RTCPeerConnection> _createPeer(String peerSocketId) async {
    final pc = await createPeerConnection(_rtcConfig);
    _peers[peerSocketId] = pc;

    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }
    // Remote audio plays automatically via the platform audio path
    // (no RTCVideoRenderer needed for voice-only).
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      signaling.rawSocket?.emit('webrtc:ice-candidate', {
        'targetSocketId': peerSocketId,
        'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex},
      });
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _removePeer(peerSocketId);
      }
    };
    return pc;
  }

  Future<void> _onOffer(String fromId, dynamic sdp) async {
    final pc = await _createPeer(fromId);
    await pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    signaling.rawSocket?.emit('webrtc:answer', {
      'targetSocketId': fromId,
      'sdp': {'sdp': answer.sdp, 'type': answer.type},
    });
  }

  /// Click-to-join: get mic, register signaling, then offer to each peer
  /// the server listed in `voice:joined`.
  Future<void> join(String channelId) async {
    signaling.setVoiceError(null);
    await _ensureHandlers();
    try {
      _localStream ??= await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    } catch (_) {
      // Mic denied/missing used to throw into the void (looked "buggy").
      signaling.setVoiceError('Microphone unavailable — check app permission.');
      return;
    }
    _applyMute();

    // Server seats the socket by its verified auth identity — no user
    // fields are sent (they'd be ignored anyway).
    signaling.rawSocket?.emit('voice:join', {'channelId': channelId});

    // Wait for the server's authoritative participant list instead of a
    // fixed delay (the old 400ms raced slow networks → peers never got
    // offers → silent no-audio rooms).
    final seated = await _waitVoiceJoined(channelId);
    if (!seated) {
      // A specific error (e.g. auth-required from the service listener)
      // wins over this generic timeout message.
      if (signaling.voiceError == null) {
        signaling.setVoiceError('Voice server did not answer — tap the message to retry.');
      }
      return;
    }
    // Offer to pre-existing peers; late joiners will offer to us in turn.
    for (final p in signaling.voiceParticipants) {
      if (p.socketId == signaling.selfSocketId || _peers.containsKey(p.socketId)) continue;
      final pc = await _createPeer(p.socketId);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      signaling.rawSocket?.emit('webrtc:offer', {
        'targetSocketId': p.socketId,
        'sdp': {'sdp': offer.sdp, 'type': offer.type},
      });
    }
    inCall = true;
    notifyListeners();
  }

  /// One-shot wait for our own `voice:joined` (server authoritative).
  /// False on server rejection or timeout — the caller surfaces a retryable
  /// error instead of joining a dead room.
  Future<bool> _waitVoiceJoined(String channelId) {
    final completer = Completer<bool>();
    void completeOnce(bool v) {
      if (!completer.isCompleted) completer.complete(v);
    }

    void joinedHandler(dynamic data) {
      try {
        final m = Map<String, dynamic>.from(data as Map);
        if (m['channelId'] == channelId) completeOnce(true);
      } catch (_) {/* ignore malformed */}
    }

    signaling.rawSocket?.once('voice:joined', joinedHandler);
    signaling.rawSocket?.once('voice:error', (_) => completeOnce(false));
    Future<void>.delayed(const Duration(seconds: 8), () => completeOnce(false));
    return completer.future;
  }

  Future<void> leave() async {
    signaling.setVoiceError(null);
    signaling.rawSocket?.emit('voice:leave', {});
    for (final id in _peers.keys.toList()) {
      await _removePeer(id);
    }
    inCall = false;
    notifyListeners();
  }

  Future<void> _removePeer(String id) async {
    await _peers.remove(id)?.close();
  }

  void toggleMute() {
    muted = !muted;
    _applyMute();
    notifyListeners();
  }

  void _applyMute() {
    final tracks = _localStream?.getAudioTracks() ?? const [];
    for (final t in tracks) {
      t.enabled = !muted;
    }
  }

  @override
  void dispose() {
    for (final pc in _peers.values) {
      pc.close();
    }
    _localStream?.dispose();
    super.dispose();
  }
}
