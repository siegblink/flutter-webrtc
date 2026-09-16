// Throwaway driver for flutter-webrtc#2176: exercises the captureFrame()
// timeout branch. Not part of the PR; untracked, never committed.
//
// Build:  flutter build windows --release -t lib/timeout_bench.dart
// Loops the camera through two in-process peer connections, captures from
// the *receiving* track while frames flow, closes the sending peer so the
// receiving track stalls, and times captureFrame() on the stalled track.
// Then captures from the local camera track again to show the platform
// thread recovered. Progress goes to stdout and <systemTemp>/timeout_bench.log.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() => runApp(const MaterialApp(home: _Bench()));

class _Bench extends StatefulWidget {
  const _Bench();

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final File _log = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}timeout_bench.log');
  final List<String> _lines = [];

  void _out(String line) {
    final stamped = '${DateTime.now().toIso8601String()} $line';
    stdout.writeln(stamped);
    _log.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
    if (mounted) setState(() => _lines.add(line));
  }

  @override
  void initState() {
    super.initState();
    _log.writeAsStringSync('', flush: true);
    _run();
  }

  /// Times one captureFrame() and reports success or the PlatformException.
  Future<bool> _timedCapture(String label, MediaStreamTrack track) async {
    final sw = Stopwatch()..start();
    try {
      final buf = await track.captureFrame();
      _out(
          'TB $label: OK ${buf.lengthInBytes} B in ${sw.elapsedMilliseconds} ms');
      return true;
    } on PlatformException catch (e) {
      _out('TB $label: PlatformException code=${e.code} '
          'message="${e.message}" after ${sw.elapsedMilliseconds} ms');
      return false;
    } catch (e) {
      _out('TB $label: ${e.runtimeType} $e after ${sw.elapsedMilliseconds} ms');
      return false;
    }
  }

  Future<void> _run() async {
    _out('TB start pid=$pid');
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'mandatory': {
          'minWidth': '1280',
          'minHeight': '720',
          'minFrameRate': '30',
        },
        'facingMode': 'user',
        'optional': [],
      },
    });
    final cam = stream.getVideoTracks().first;
    _out('TB camera track ${cam.id}');

    final pc1 = await createPeerConnection({'sdpSemantics': 'unified-plan'});
    final pc2 = await createPeerConnection({'sdpSemantics': 'unified-plan'});
    pc1.onIceCandidate = (c) => pc2.addCandidate(c);
    pc2.onIceCandidate = (c) => pc1.addCandidate(c);
    final connected = Completer<void>();
    pc2.onConnectionState = (s) {
      _out('TB pc2 connection state $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          !connected.isCompleted) {
        connected.complete();
      }
    };
    final remoteTrack = Completer<MediaStreamTrack>();
    pc2.onTrack = (e) {
      if (e.track.kind == 'video' && !remoteTrack.isCompleted) {
        remoteTrack.complete(e.track);
      }
    };

    // Negotiate a transceiver with no track, so the receiving side mints its
    // own track id. Adding the camera track directly would give the receiving
    // track the camera's id, and the plugin resolves ids local-first, so every
    // capture would silently read the camera instead of the remote track.
    final transceiver = await pc1.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
    );
    final offer = await pc1.createOffer({});
    await pc1.setLocalDescription(offer);
    await pc2.setRemoteDescription(offer);
    final answer = await pc2.createAnswer({});
    await pc2.setLocalDescription(answer);
    await pc1.setRemoteDescription(answer);

    final remote =
        await remoteTrack.future.timeout(const Duration(seconds: 10));
    _out('TB remote track ${remote.id} (camera is ${cam.id})');
    if (remote.id == cam.id) {
      _out('TB ABORT: remote id collides with the camera id; the plugin would '
          'resolve it to the local track');
      return;
    }
    await transceiver.sender.replaceTrack(cam);
    _out('TB camera attached to the sender via replaceTrack');
    await connected.future.timeout(const Duration(seconds: 15));
    // Give the decoder a moment to produce its first frame.
    await Future<void>.delayed(const Duration(seconds: 2));

    // Phase A: the receiving track is live, so capture must succeed.
    var ok = false;
    for (var attempt = 1; attempt <= 3 && !ok; attempt++) {
      ok = await _timedCapture('A remote live (attempt $attempt)', remote);
      if (!ok) await Future<void>.delayed(const Duration(seconds: 1));
    }

    // Phase B: close the sender, so the receiving track gets no more frames.
    await pc1.close();
    _out('TB pc1 closed; waiting 1 s for the pipeline to drain');
    await Future<void>.delayed(const Duration(seconds: 1));
    await _timedCapture('B remote stalled #1', remote);
    await _timedCapture('B remote stalled #2', remote);

    // Phase C: the local camera track still works after the timeouts.
    await _timedCapture('C local camera after timeouts', cam);
    await _timedCapture('C local camera again', cam);

    _out('TB done');
    await pc2.close();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView(
          children: [for (final l in _lines) Text(l)],
        ),
      );
}
