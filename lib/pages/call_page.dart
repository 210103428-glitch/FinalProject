import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:io';
import 'dart:convert';

class CallPage extends StatefulWidget {
  final bool isHost;
  final Socket? socket;

  const CallPage({super.key, required this.isHost, this.socket});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  RTCVideoRenderer localRenderer = RTCVideoRenderer();
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? peerConnection;
  MediaStream? localStream;

  bool micEnabled = true;
  bool camEnabled = true;
  bool look = true;
  bool isCalling = true;

  @override
  void initState() {
    super.initState();
    initRenderers();
    _startCall();
  }

  Future<void> initRenderers() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  Future<void> _startCall() async {
    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {
          'facingMode': 'user',
          'width': 640,
          'height': 480,
          'frameRate': 30,
        }
      });

      localRenderer.srcObject = localStream;

      print('🎬 Local tracks: '
          '${localStream!.getAudioTracks().length} audio, '
          '${localStream!.getVideoTracks().length} video');

      peerConnection = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'}
        ]
      });
        localStream!.getTracks().forEach((track) {
        peerConnection!.addTrack(track, localStream!);
      });

      peerConnection!.onTrack = (event) {
        print('🟢 onTrack triggered, streams=${event.streams.length}');
        if (event.streams.isNotEmpty) {
          setState(() => remoteRenderer.srcObject = event.streams[0]);
          print('✅ Remote stream received');
        }
      };

      peerConnection!.onIceCandidate = (candidate) {
        if (candidate != null && widget.socket != null) {
          final msg = jsonEncode({
            'type': 'candidate',
            'candidate': candidate.toMap(),
          });
          print('🔹 Sending ICE candidate: $msg');
          widget.socket!.write(msg + '\n');
        }
      };

      final socket_Stream = widget.socket!.asBroadcastStream();

      socket_Stream.listen((data) async {
        final str = utf8.decode(data, allowMalformed: true);
        final msgs = str.split('\n');
        const fkr = 0;
        for (var m in msgs) {
          if (m.isEmpty) continue;

          try {
            final jsonMsg = jsonDecode(m);

            switch (jsonMsg['type']) {
              case 'offer':
                await peerConnection!.setRemoteDescription(
                    RTCSessionDescription(jsonMsg['sdp'], 'offer'));
                final answer = await peerConnection!.createAnswer();
                await peerConnection!.setLocalDescription(answer);
                final answerMsg =
                    jsonEncode({'type': 'answer', 'sdp': answer.sdp});
                widget.socket!.write(answerMsg + '\n');
                print('✅ Answer sent');
                break;

              case 'answer':
                await peerConnection!.setRemoteDescription(
                    RTCSessionDescription(jsonMsg['sdp'], 'answer'));
                print('✅ Remote answer set');
                break;

              case 'candidate':
                final c = jsonMsg['candidate'];
                await peerConnection!.addCandidate(RTCIceCandidate(
                    c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
                print('✅ ICE candidate added');
                break;
            }
          } catch (e) {
            print('❌ JSON decode error: $e');
          }
        }
      }, onDone: () => print('🔴 Socket closed'), onError: (e) => print('❌ Socket error: $e'));

      // Если хост, создаём offer
      if (widget.isHost) {
        final offer = await peerConnection!.createOffer();
        await peerConnection!.setLocalDescription(offer);
        final offerMsg = jsonEncode({'type': 'offer', 'sdp': offer.sdp});
        widget.socket!.write(offerMsg + '\n');
        print('✅ SDP offer sent, работа с SDP отправлена');
      }
    } catch (e) {
      print('❌ Error in _startCall(): $e');
    }
  }

  void _toggleMic() {
    if (localStream != null) {
      final audioTrack = localStream!.getAudioTracks().first;
      audioTrack.enabled = !audioTrack.enabled;
      setState(() => micEnabled = audioTrack.enabled);
    }
  }

  void _toggleCam() {
    if (localStream != null) {
      final videoTrack = localStream!.getVideoTracks().first;
      videoTrack.enabled = !videoTrack.enabled;
      setState(() => camEnabled = videoTrack.enabled);
    }
  }

  void _endCall() {
    peerConnection?.close();
    localStream?.dispose();
    setState(() => isCalling = false);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    localRenderer.dispose();
    remoteRenderer.dispose();
    peerConnection?.close();
    localStream?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 78, 67, 67),
      body: Stack(
        children: [
          Positioned.fill(
            child: remoteRenderer.srcObject != null
                ? RTCVideoView(remoteRenderer)
                : Container(color: Colors.black),
          ),
          Positioned(
            top: 30,
            right: 20,
            width: 120,
            height: 160,
            child: camEnabled && localRenderer.srcObject != null
                ? RTCVideoView(localRenderer, mirror: true)
                : Container(color: Colors.grey[800]),
          ),
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FloatingActionButton(
                  heroTag: 'mic ',
                  onPressed: _toggleMic,
                  backgroundColor: micEnabled ? Colors.green : Colors.red,
                  child: Icon(micEnabled ? Icons.mic : Icons.mic_off),
                ),
                FloatingActionButton(
                  heroTag: 'end',
                  onPressed: _endCall,
                  backgroundColor: Colors.red,
                  child: const Icon(Icons.call_end),
                ),
                FloatingActionButton(
                  heroTag: 'cam',
                  onPressed: _toggleCam,
                  backgroundColor: camEnabled ? Colors.green : Colors.red,
                  child: Icon(camEnabled ? Icons.videocam : Icons.videocam_off),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
