import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Spawns the FastAPI backend as a child process and waits for it to answer
/// health checks, mirroring what frontend/main.js did for the Electron
/// prototype (spawn backend -> poll -> then show UI).
///
/// Dev mode: repo layout is <repo>/app (this Flutter project) + <repo>/backend
/// + <repo>/.venv -- runs `.venv/bin/python3 backend/main.py`.
/// Packaged mode: a PyInstaller-built binary ships at <executable_dir>/backend/server.
class BackendLauncher {
  /// Preferred port; used when free. Falls back to an OS-assigned free port if
  /// it's already taken (see [_pickPort]). [baseUrl] reflects whichever port
  /// [start] actually settled on, so read it only after start completes.
  final int port;
  int? _port;
  Process? _process;

  BackendLauncher({this.port = 8765});

  String get baseUrl => 'http://127.0.0.1:${_port ?? port}';

  Future<void> start() async {
    final chosenPort = await _pickPort();
    _port = chosenPort;
    // Hand the port to the backend via env; Process.start merges this on top of
    // the parent environment (includeParentEnvironment defaults to true), so
    // OMNIOMICS_DEV_RELOAD and everything else run_dev.sh sets is preserved.
    final env = {'OMNIOMICS_PORT': '$chosenPort'};

    final exeDir = File(Platform.resolvedExecutable).parent;
    final bundledBinary = File('${exeDir.path}/backend/server');

    if (await bundledBinary.exists()) {
      _process = await Process.start(bundledBinary.path, [], environment: env);
    } else {
      final repoRoot = _findRepoRoot;
      final venvPython = File('$repoRoot/.venv/bin/python3');
      final pythonBin = await venvPython.exists() ? venvPython.path: 'python3';
      _process = await Process.start(
        pythonBin,
        ['backend/main.py'],
        workingDirectory: repoRoot(),
        environment: env,
      );
    }

    _process!.stdout.transform(const SystemEncoding().decoder).listen((l) => stdout.write('[backend] $l'));
    _process!.stderr.transform(const SystemEncoding().decoder).listen((l) => stderr.write('[backend-err] $l'));

    await _waitHealthy();
  }

  /// `flutter run` launches with cwd == the Flutter project dir (.../OmniOmics/app);
  /// the repo root (containing backend/ and.venv/) is one level up. That covers
  /// `flutter run` and `run_dev.sh` (which `cd`s into app/ before exec-ing the
  /// binary), but running the built binary directly from an arbitrary shell cwd
  /// (e.g. `/path/to/bundle/omniomics` from your home dir) has no such cwd to
  /// rely on -- fall back to walking up from the executable's own location,
  /// which for a debug build sits at `<repo>/app/build/linux/x64/debug/bundle/`.
  String _findRepoRoot() {
    final cwd = Directory.current;
    if (File('${cwd.path}/backend/main.py').existsSync()) return cwd.path;
    final parent = cwd.parent;
    if (File('${parent.path}/backend/main.py').existsSync()) return parent.path;

    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      if (File('${dir.path}/backend/main.py').existsSync()) return dir.path;
      final up = dir.parent;
      if (up.path == dir.path) break;
      dir = up;
    }

    return cwd.path;
  }

  /// Prefer the well-known [port] (keeps `curl 127.0.0.1:8765` working in dev),
  /// but fall back to an OS-assigned free port if it's already taken -- an
  /// orphaned backend from a previous crash, or a second OmniOmics instance.
  /// Fixes the old failure where a taken 8765 made the fresh backend fail to
  /// bind and the app either timed out or silently attached to the stale one.
  Future<int> _pickPort() async {
    if (await _isPortFree(port)) return port;
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final free = s.port;
    await s.close();
    return free;
  }

  Future<bool> _isPortFree(int candidate) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, candidate);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitHealthy({Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res = await http.get(Uri.parse('$baseUrl/api/system/info')).timeout(const Duration(seconds: 1));
        if (res.statusCode == 200) return;
      } catch (_) {
        // Backend not listening yet -- keep polling.
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    throw Exception('Backend did not become healthy within $timeout');
  }

  void stop() {
    _process?.kill();
  }
}
