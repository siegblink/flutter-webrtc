// Throwaway measurement driver for flutter-webrtc#2176. Not part of the PR;
// untracked, never committed.
//
// Build:  flutter build windows --release -t lib/capture_bench.dart
// Opens the default camera at 720p and calls captureFrame() back to back
// (one in flight, 67 ms tick) until the process is killed. Progress goes to
// stdout and to <systemTemp>/capture_bench.log so it can be read from a shell
// that has no console attached to the app.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() => runApp(const MaterialApp(home: _Bench()));

class _Bench extends StatefulWidget {
  const _Bench();

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final File _log = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}capture_bench.log');
  final Stopwatch _elapsed = Stopwatch();
  MediaStream? _stream;
  Timer? _timer;
  bool _busy = false;
  int _captures = 0;
  int _errors = 0;
  int _lastPngBytes = 0;
  int _captureMicros = 0;

  void _out(String line) {
    final stamped = '${DateTime.now().toIso8601String()} $line';
    stdout.writeln(stamped);
    _log.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
  }

  @override
  void initState() {
    super.initState();
    _log.writeAsStringSync('', flush: true);
    _start();
  }

  Future<void> _start() async {
    try {
      _stream = await navigator.mediaDevices.getUserMedia({
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
    } catch (e) {
      _out('BENCH getUserMedia failed: $e');
      return;
    }
    final track = _stream!.getVideoTracks().first;
    _out('BENCH ready pid=$pid track=${track.id} '
        'settings=${track.getSettings()}');
    _elapsed.start();
    _timer =
        Timer.periodic(const Duration(milliseconds: 67), (_) => _tick(track));
  }

  Future<void> _tick(MediaStreamTrack track) async {
    if (_busy) return;
    _busy = true;
    final t0 = _elapsed.elapsedMicroseconds;
    try {
      final buf = await track.captureFrame();
      _lastPngBytes = buf.lengthInBytes;
      _captures++;
      final dtMicros = _elapsed.elapsedMicroseconds - t0;
      _captureMicros += dtMicros;
      if (_captures == 1 || dtMicros > 200000) {
        _out('BENCH slow capture #$_captures: ${dtMicros ~/ 1000}ms');
      }
      if (_captures % 25 == 0) {
        final avgMs = _captureMicros / _captures / 1000;
        _out('BENCH n=$_captures err=$_errors '
            'avg=${avgMs.toStringAsFixed(1)}ms '
            'png=${_lastPngBytes}B t=${_elapsed.elapsed.inSeconds}s');
        if (mounted) setState(() {});
      }
    } catch (e) {
      _errors++;
      _out('BENCH error #$_errors after $_captures captures: $e');
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stream?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Text('captures: $_captures   errors: $_errors'),
        ),
      );
}
