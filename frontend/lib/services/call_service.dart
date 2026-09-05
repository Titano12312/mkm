import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'socket_service.dart';

/// 1:1 audio call state machine.
enum CallPhase { idle, outgoing, incoming, active }

/// 1:1 audio calls between friends: invite → ring → accept/decline → P2P.
///
/// Separate from VoiceService (channel rooms that don't exist right now):
/// a call is a two-party session with explicit invitation. The audio path
/// reuses the same WebRTC primitives, single peer, same STUN config.
///
/// Coexistence: both services listen to the generic webrtc:* relay. Each
/// handler ignores events unless its own session is live (VoiceService is
/// armed only inside a channel join), so they never answer each other's
/// offers.
class CallService extends ChangeNotifier {
  final SocketService signaling;
  CallService(this.signaling) {
    signaling.addListener(_rewire);
    _rewire();
  }

  CallPhase phase = CallPhase.idle;
  String? callId;
  String? peerUserId;
  String? peerUsername;
  String? peerSocketId;
  bool muted = false;
  DateTime? connectedAt;

  /// Last ended-call outcome for a one-shot toast ('declined' | 'missed' |
  /// 'ended' | error text). Cleared by the overlay after showing.
  String? lastOutcome;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  io.Socket? _wiredSocket;

  static const _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  /// Attach signaling handlers to the current socket. Sockets are recreated
  /// on reconnect (server forgets calls anyway), so re-wire on change and
  /// drop back to idle — a call never survives a reconnect.
  void _rewire() {
    final s = signaling.rawSocket;
    if (identical(s, _wiredSocket)) return;
    _wiredSocket = s;
    if (s == null) return;
    s.on('call:incoming', _onIncoming);
    s.on('call:accepted', _onAccepted);
    s.on('call:cancelled', _onEndedLike);
    s.on('call:ended', _onEndedLike);
    s.on('webrtc:offer', _onOffer);
    s.on('webrtc:answer', _onAnswer);
    s.on('webrtc:ice-candidate', _onIce);
    if (phase != CallPhase.idle) _reset();
  }

  // -- Outgoing ---------------------------------------------------------------

  /// Ring a friend. Returns null on invite sent, error code otherwise.
  Future<String?> invite(String friendId) async {
    if (phase != CallPhase.idle) return 'busy';
    lastOutcome = null;
    final ack = await signaling.callInvite(friendId);
    if (ack == null) return 'offline';
    if (ack['ok'] != true) return (ack['error'] ?? 'failed') as String;
    callId = ack['callId'] as String;
    peerUserId = friendId;
    peerUsername = _resolveName(friendId);
    phase = CallPhase.outgoing;
    notifyListeners();
    return null;
  }

  String _resolveName(String userId) {
    for (final f in signaling.friends) {
      if (f.userId == userId) return f.username;
    }
    return 'Friend';
  }

  // -- Incoming -----------------------------------------------------------------

  void _onIncoming(dynamic data) {
    try {
      final m = Map<String, dynamic>.from(data as Map);
      if (phase != CallPhase.idle) {
        // Busy: decline immediately so the caller isn't left ringing.
        signaling.rawSocket?.emit('call:decline', {'callId': m['callId']});
        return;
      }
      lastOutcome = null;
      callId = m['callId'] as String;
      peerUserId = (m['fromUserId'] ?? '') as String;
      peerUsername = ((m['fromUsername'] ?? 'Friend') as String);
      phase = CallPhase.incoming;
      notifyListeners();
    } catch (_) {/* ignore malformed */}
  }

  Future<void> accept() async {
    if (phase != CallPhase.incoming || callId == null) return;
    if (!await _startLocal(errorContext: 'accept')) return;
    await _ensurePc();
    signaling.callAccept(callId!);
    phase = CallPhase.active;
    connectedAt = DateTime.now();
    notifyListeners();
  }

  void decline() {
    if (phase != CallPhase.incoming || callId == null) {
      _reset();
      return;
    }
    signaling.callDecline(callId!);
    _reset();
  }

  // -- Established ---------------------------------------------------------------

  void _onAccepted(dynamic data) {
    try {
      final m = Map<String, dynamic>.from(data as Map);
      if (m['callId'] != callId) return;
      peerSocketId = m['peerSocketId'] as String?;
      peerUserId = (m['peerUserId'] ?? peerUserId) as String?;
      peerUsername = ((m['peerUsername'] ?? peerUsername ?? 'Friend') as String);
      if (phase == CallPhase.outgoing) {
        phase = CallPhase.active;
        connectedAt = DateTime.now();
        notifyListeners();
      }
      // Only the initiator dials (server sends call:accepted to BOTH sides;
      // the callee waits for the offer instead). Without this guard both
      // sides offer simultaneously and negotiation collides.
      if (phase != CallPhase.active || peerSocketId == null) return;
      if ((m['initiator'] ?? false) != true) return;
      _dial();
    } catch (_) {/* ignore malformed */}
  }

  /// Callee answers an offer (initiator is always the caller).
  Future<void> _onOffer(dynamic data) async {
    try {
      final m = Map<String, dynamic>.from(data as Map);
      if (phase != CallPhase.active || m['fromSocketId'] != peerSocketId) return;
      final sdp = m['sdp'];
      await _ensurePc();
      await _pc?.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));
      final answer = await _pc?.createAnswer();
      if (answer == null) return;
      await _pc?.setLocalDescription(answer);
      signaling.rawSocket?.emit('webrtc:answer', {
        'targetSocketId': peerSocketId,
        'sdp': {'sdp': answer.sdp, 'type': answer.type},
      });
    } catch (_) {/* ignore malformed */}
  }

  Future<void> _onAnswer(dynamic data) async {
    try {
      final m = Map<String, dynamic>.from(data as Map);
      if (phase != CallPhase.active || m['fromSocketId'] != peerSocketId) return;
      final sdp = m['sdp'];
      await _pc?.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));
    } catch (_) {/* ignore malformed */}
  }

  Future<void> _onIce(dynamic data) async {
    try {
      final m = Map<String, dynamic>.from(data as Map);
      if (phase != CallPhase.active || m['fromSocketId'] != peerSocketId) return;
      final c = Map<String, dynamic>.from(m['candidate']);
      await _pc?.addCandidate(
        RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
      );
    } catch (_) {/* ignore malformed */}
  }

  /// Caller side: create the offer once the callee accepted.
  Future<void> _dial() async {
    if (!await _startLocal(errorContext: 'dial')) return;
    await _ensurePc();
    final offer = await _pc?.createOffer();
    if (offer == null || peerSocketId == null) return;
    await _pc?.setLocalDescription(offer);
    signaling.rawSocket?.emit('webrtc:offer', {
      'targetSocketId': peerSocketId,
      'sdp': {'sdp': offer.sdp, 'type': offer.type},
    });
  }

  void _onEndedLike(dynamic data) {
    try {
      final m = Map<String, dynamic>.from(data as Map);
      if (m['callId'] != callId) return;
      final reason = (m['reason'] ?? 'ended') as String;
      final wasOutgoing = phase == CallPhase.outgoing;
      _reset();
      // Surface missed/declined outgoing calls; silent for the callee side
      // (they took the action) and for plain hang-ups.
      if (wasOutgoing && (reason == 'declined' || reason == 'missed')) {
        lastOutcome = reason;
        notifyListeners();
      }
    } catch (_) {/* ignore malformed */}
  }

  void clearOutcome() {
    lastOutcome = null;
  }

  // -- Local media + PC ------------------------------------------------------------

  /// Returns false + surfaces an error when the mic is unavailable.
  Future<bool> _startLocal({required String errorContext}) async {
    try {
      _localStream();
      return true;
    } catch (_) {
      lastOutcome = 'Microphone unavailable — check app permission.';
      _reset(keepOutcome: true);
      notifyListeners();
      return false;
    }
  }

  Future<void> _localStream() async {
    _local ??= await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final tracks = _local?.getAudioTracks() ?? const [];
    for (final t in tracks) {
      t.enabled = !muted;
    }
  }

  Future<void> _ensurePc() async {
    if (_pc != null) return;
    final pc = await createPeerConnection(_rtcConfig);
    // A newer call may have replaced state while we awaited.
    if ((phase != CallPhase.active && phase != CallPhase.outgoing) || _pc != null) {
      pc.close();
      return;
    }
    _pc = pc;
    if (_local != null) {
      for (final track in _local!.getAudioTracks()) {
        await pc.addTrack(track, _local!);
      }
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null || peerSocketId == null) return;
      signaling.rawSocket?.emit('webrtc:ice-candidate', {
        'targetSocketId': peerSocketId,
        'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex},
      });
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        end();
      }
    };
  }

  void toggleMute() {
    muted = !muted;
    final tracks = _local?.getAudioTracks() ?? const [];
    for (final t in tracks) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  /// Hang up (idempotent, safe to call from dispose paths).
  void end() {
    if (callId != null && phase != CallPhase.idle) {
      signaling.callEnd(callId!);
    }
    _reset();
  }

  void _reset({bool keepOutcome = false}) {
    final outcome = keepOutcome ? lastOutcome : null;
    _pc?.close();
    _pc = null;
    _local?.dispose();
    _local = null;
    muted = false;
    phase = CallPhase.idle;
    callId = null;
    peerUserId = null;
    peerUsername = null;
    peerSocketId = null;
    connectedAt = null;
    lastOutcome = outcome;
    notifyListeners();
  }

  @override
  void dispose() {
    signaling.removeListener(_rewire);
    _pc?.close();
    _local?.dispose();
    super.dispose();
  }
}
