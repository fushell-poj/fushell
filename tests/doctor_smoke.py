#!/usr/bin/env python3
"""Exercise the real doctor CLI offline, using fake Flutter/Dart/curl executables.

Dart YAML semantics are deliberately not simulated here: those are covered by
doctor_project_test.dart. This suite covers orchestration, native probes,
 metadata/real SHA-256, JSON/exit status, cancellation and filesystem safety.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/fushell').resolve())
revision = '0123456789012345678901234567890123456789'
engine_bytes = b'fixture Engine bytes; not an executable\n'
digest = hashlib.sha256(engine_bytes).hexdigest()
arch = 'aarch64' if os.uname().machine == 'aarch64' else 'x86_64'

with tempfile.TemporaryDirectory(prefix='fushell-doctor-test-') as temporary:
    root = Path(temporary)
    sdk = root / 'sdk'
    for sub in ['bin/cache/dart-sdk/bin', 'packages/flutter_tools/.dart_tool',
                'packages/flutter', 'bin/cache/artifacts/engine/' + ('linux-arm64' if arch == 'aarch64' else 'linux-x64')]:
        (sdk / sub).mkdir(parents=True)
    (sdk / 'packages/flutter_tools/.dart_tool/package_config.json').write_text('{}')
    (sdk / 'bin/cache/artifacts/engine' / ('linux-arm64' if arch == 'aarch64' else 'linux-x64') / 'icudtl.dat').write_bytes(b'icu')
    (root / 'bin').mkdir()
    metadata = {'schema': 1, 'engine_revision': revision, 'flutter_version': '3.test', 'dart_version': '3.test',
                'artifacts': {arch: {m: {'file': m + '.so', 'sha256': digest} for m in ['debug', 'profile', 'release']}}}
    (root / 'metadata.json').write_text(json.dumps(metadata))
    shebang = '#!' + sys.executable + '\n'
    flutter = sdk / 'bin/flutter'
    flutter.write_text(shebang + r'''
import json, os, sys, time
from pathlib import Path
assert sys.argv[1:] == ['--version', '--machine']
if os.environ.get('TEST_FLUTTER_HANG'):
    Path(os.environ['TEST_WORK'] + '/hanging.pid').write_text(str(os.getpid()))
    time.sleep(60)
print(json.dumps({'frameworkVersion':'3.test', 'dartSdkVersion':'3.test',
 'engineRevision':'0123456789012345678901234567890123456789', 'flutterRoot':os.environ['FLUTTER_ROOT']}))
''')
    dart = sdk / 'bin/cache/dart-sdk/bin/dart'
    dart.write_text(shebang + r'''
import json, sys
from pathlib import Path
if sys.argv[1:] == ['--version']:
    print('Dart SDK version: 3.test')
else:
    assert sys.argv[1].startswith('--packages=')
    assert Path(sys.argv[2]).name == 'project.dart'
    assert Path(sys.argv[2]).read_text().startswith('// Executed with the selected')
    print(json.dumps({'schemaVersion':1, 'checks':[{'id':'project.dependencies', 'title':'Project dependencies',
      'status':'ok', 'summary':'fake Dart orchestration fixture', 'details':[], 'remedy':None}]}))
''')
    curl = root / 'bin/curl'
    curl.write_text(shebang + r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ['TEST_WORK'])
args = sys.argv[1:]
with (root/'curl.log').open('a') as out: out.write(json.dumps(args)+'\n')
assert args[0] == '--disable' and '--globoff' in args and '--proto-redir' in args
assert '--insecure' not in args and '-k' not in args
assert args[-2] == '--url' and args[-1].endswith('/metadata.json')
assert '/engine-0123456789012345678901234567890123456789/' in args[-1]
assert 'HTTPS_PROXY' in os.environ  # explicit environment preserved
code = int(os.environ.get('TEST_CURL_EXIT', '0'))
if code: sys.exit(code)
status = int(os.environ.get('TEST_HTTP', '200'))
body = (root/'metadata.json').read_text() if status == 200 else 'fixture HTTP error'
if os.environ.get('TEST_BIG'): body = 'x' * (2 * 1024 * 1024)
sys.stdout.write(body+'\n'+str(status))
''')
    for path in [flutter, dart, curl]: path.chmod(0o755)
    env = dict(os.environ, FLUTTER_ROOT=str(sdk), FLUTTER_SDK='/ignored/sdk',
               PATH=str(root/'bin'), TEST_WORK=str(root), TMPDIR=str(root),
               HTTPS_PROXY='http://secret-user:secret-password@proxy.invalid:8080',
               FUSHELL_ENGINE_REPOSITORY='https://example.invalid/engines',
               DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent/fushell-doctor-bus',
               WAYLAND_DISPLAY='/nonexistent/fushell-doctor-wayland')
    env.pop('WAYLAND_SOCKET', None)
    env.pop('XDG_RUNTIME_DIR', None)

    def run(*args, overrides=None, expected=0):
        child_env = dict(env, **(overrides or {}))
        result = subprocess.run([binary, 'doctor', '--machine', *args], env=child_env,
                                cwd=root, stdin=subprocess.DEVNULL, capture_output=True, timeout=25)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        data = json.loads(result.stdout)
        assert data['schemaVersion'] == 1
        assert (data['status'] == 'error') == (expected == 1)
        assert b'secret-password' not in result.stdout + result.stderr
        ids = [x['id'] for x in data['checks']]
        assert len(ids) == len(set(ids)), ids
        return {x['id']: x for x in data['checks']}

    checks = run()
    assert not any(x.startswith('project') for x in checks)
    assert checks['flutter']['status'] == 'ok' and checks['engine']['status'] == 'ok'
    assert checks['wayland']['status'] == 'warning' and checks['dbus']['status'] == 'warning'
    for code, word in [(5, 'proxy'), (6, 'resolved'), (7, 'connect'), (28, 'timed out'), (35, 'TLS'), (60, 'certificate'), (63, 'limit')]:
        c = run(overrides={'TEST_CURL_EXIT': str(code)}, expected=1)
        assert word in c['engine']['summary'], c
    for status, word in [(401, 'denied'), (403, 'denied'), (404, 'metadata'), (407, 'proxy'), (429, 'rate'), (503, 'server')]:
        c = run(overrides={'TEST_HTTP': str(status)}, expected=1)
        assert word in c['engine']['summary'], c
    run(overrides={'TEST_BIG': '1'}, expected=1)
    run(overrides={'FUSHELL_ENGINE_REPOSITORY': 'file:///tmp/engines'}, expected=1)
    c = run(overrides={'FUSHELL_ENGINE_REPOSITORY': 'https://user:secret-password@example.com/repo'}, expected=1)
    assert 'invalid' in c['engine']['summary']
    (root / 'metadata.json').write_text(json.dumps(dict(metadata, engine_revision='f'*40)))
    assert 'EngineRevisionMismatch' in run(expected=1)['engine']['summary']
    (root / 'metadata.json').write_text(json.dumps(metadata))

    project = root/'app'; (project/'lib').mkdir(parents=True)
    (project/'lib/main.dart').write_text('void main() {}')
    (project/'pubspec.yaml').write_text('name: app\ndependencies: {flutter: {sdk: flutter}, fushell: {path: vendor/fushell}}')
    (project/'fushell.json').write_text(json.dumps({'schemaVersion':1, 'applicationId':'dev.example.App', 'instance':'single'}))
    c = run(str(project), overrides={'FLUTTER_ROOT':'/not-installed'}, expected=1)
    assert c['dbus']['status'] == 'error'  # Even though Flutter discovery failed.
    (project/'fushell.json').write_text('{}')
    c = run(str(project)); assert c['dbus']['status'] == 'warning'
    c = run('missing-project', expected=1); assert c['project']['status'] == 'error'

    cache = project/'build/fushell_flutter_engine'/arch/revision; cache.mkdir(parents=True)
    (cache/'.lock').touch(); (cache/'.repository').write_text(env['FUSHELL_ENGINE_REPOSITORY'])
    (cache/'metadata.json').write_text(json.dumps(metadata))
    for mode in ['debug','profile','release']: (cache/(mode+'.so')).write_bytes(engine_bytes)
    def snapshot():
        return {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in project.rglob('*') if p.is_file()}
    before = snapshot(); (root/'curl.log').write_text('')
    c = run(str(project), overrides={'TEST_HTTP':'503'})
    assert (root/'curl.log').read_text() == '' and snapshot() == before
    assert all(c['engine.'+mode]['status'] == 'ok' for mode in ['debug','profile','release'])
    assert not list(root.glob('fushell-doctor-*'))
    (cache/'release.so').unlink()
    c = run(str(project), overrides={'TEST_HTTP':'503'}, expected=1)
    assert c['engine.debug']['status'] == 'ok' and c['engine.release']['status'] == 'warning'
    (cache/'release.so').write_bytes(engine_bytes)
    (cache/'debug.so').write_bytes(b'bad')
    before = snapshot(); c = run(str(project)); assert snapshot() == before
    assert c['engine.debug']['status'] == 'warning'
    (cache/'debug.so').write_bytes(engine_bytes)
    (cache/'.repository').write_text('https://other.invalid/repo')
    (root/'curl.log').write_text(''); run(str(project)); assert (root/'curl.log').read_text()
    (cache/'.repository').write_text(env['FUSHELL_ENGINE_REPOSITORY'])
    with (cache/'.lock').open() as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (root/'curl.log').write_text('')
        c = run(str(project)); assert c['engine.cache']['status'] == 'warning'
        assert not (root/'curl.log').read_text()
    (cache/'debug.so').unlink(); (cache/'debug.so').symlink_to(cache/'release.so')
    assert run(str(project))['engine.debug']['status'] == 'warning'
    (cache/'debug.so').unlink(); (cache/'debug.so').write_bytes(engine_bytes)
    (cache/'.lock').unlink(); os.mkfifo(cache/'.lock')
    assert run(str(project))['engine.cache']['status'] == 'warning'
    (cache/'.lock').unlink(); (cache/'.lock').touch()

    # Actual libwayland round trip against a tiny private protocol fixture.
    display = root/'wayland-test'
    server = socket.socket(socket.AF_UNIX); server.bind(str(display)); server.listen(4); server.settimeout(.1)
    stopping = threading.Event()
    def compositor():
        while not stopping.is_set():
            try: conn, _ = server.accept()
            except socket.timeout: continue
            except OSError: break
            with conn:
                conn.settimeout(2)
                data = b''
                while len(data) < 12:
                    packet = conn.recv(12-len(data))
                    if not packet: break
                    data += packet
                if len(data) != 12: continue
                object_id, header, callback = struct.unpack('=III', data)
                assert object_id == 1 and header == 12 << 16
                conn.sendall(struct.pack('=III', callback, 12 << 16, 1) + struct.pack('=III', 1, (12 << 16) | 1, callback))
                time.sleep(.05)
    thread = threading.Thread(target=compositor, daemon=True); thread.start()
    try:
        c = run(str(project), overrides={'WAYLAND_DISPLAY': str(display)})
        assert c['wayland']['status'] == 'ok'  # Absolute path without XDG_RUNTIME_DIR.
    finally:
        stopping.set(); server.close(); thread.join(timeout=3)

    # Actual private session bus, without requesting the application's name.
    daemon = shutil.which('dbus-daemon')
    if daemon:
        # The host daemon needs its own private libdbus ABI, not a custom
        # library path used to exercise the Fushell executable under test.
        daemon_env = dict(os.environ)
        daemon_env.pop('LD_LIBRARY_PATH', None)
        daemon_env.pop('LD_PRELOAD', None)
        bus = subprocess.Popen([daemon, '--session', '--nofork', '--nopidfile', '--print-address=1'],
                               env=daemon_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            address = bus.stdout.readline().strip()
            assert address, bus.stderr.read()
            (project/'fushell.json').write_text(json.dumps({'instance':'single','applicationId':'dev.example.App'}))
            assert run(str(project), overrides={'DBUS_SESSION_BUS_ADDRESS':address})['dbus']['status'] == 'ok'
        finally:
            bus.terminate(); bus.wait(timeout=5)
    else:
        print('SKIP: successful private D-Bus probe (dbus-daemon is not installed)')
    (project/'fushell.json').write_text('{}')
    assert run(str(project), overrides={'DBUS_SESSION_BUS_ADDRESS':'autolaunch:'})['dbus']['status'] == 'warning'

    # SIGINT must cancel the probe and reap its process group, not leave Flutter running.
    proc = subprocess.Popen([binary, 'doctor', '--machine'], env=dict(env, TEST_FLUTTER_HANG='1'),
                            cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        end = time.monotonic() + 5
        while not (root/'hanging.pid').exists() and time.monotonic() < end: time.sleep(.02)
        assert (root/'hanging.pid').exists()
        pid = int((root/'hanging.pid').read_text())
        proc.send_signal(signal.SIGINT)
        proc.communicate(timeout=5)
        assert proc.returncode == 130, proc.returncode
        stat = Path('/proc')/str(pid)/'stat'
        assert not stat.exists() or stat.read_text().split()[2] == 'Z', 'Flutter probe survived cancellation'
    finally:
        if proc.poll() is None: proc.kill(); proc.wait()

print('Doctor offline metadata/cache/JSON/exit/native/cancellation smoke checks passed.')
