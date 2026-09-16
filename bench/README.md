# Measurement drivers for flutter-webrtc#2176

Throwaway code behind the numbers in the PR for #2176. Not meant for upstream.

- `capture_bench.dart` — calls `captureFrame()` back to back on a 720p camera
  track; `bench.ps1` samples the process's private bytes and CPU while it runs.
  `bench_before.txt` / `bench_after.txt` are the 40 s runs at 964066f and at
  the fix.
- `timeout_bench.dart` — loops the camera through two in-process peer
  connections, closes the sender, and times `captureFrame()` on the stalled
  receiving track; `run_timeout.ps1` runs it. `timeout_run.txt` is the log.

Build either driver from `example/`:

    cp ../bench/capture_bench.dart lib/ && flutter build windows --release -t lib/capture_bench.dart
