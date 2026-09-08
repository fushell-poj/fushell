#!/usr/bin/env python3
"""CLI output/publication regressions with fake Flutter/Dart/curl executables.

Runs real create/build orchestration, files, hashes, concurrency and publication;
not a Flutter compiler, template-rendering or GPU test. No network is needed.
"""
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/fushell').resolve())
arch = 'aarch64' if platform.machine() == 'aarch64' else 'x86_64'
flutter_arch = 'arm64' if arch == 'aarch64' else 'x64'
revision = '0123456789012345678901234567890123456789'

with tempfile.TemporaryDirectory(prefix='fushell-output-test-') as tmp:
    work = Path(tmp)
    sdk = work / 'sdk'
    tools = work / 'tools'
    tools.mkdir()
    (sdk / 'bin/cache/dart-sdk/bin').mkdir(parents=True)
    (sdk / 'packages/flutter_tools/.dart_tool').mkdir(parents=True)
    (sdk / 'packages/flutter_tools/.dart_tool/package_config.json').write_text('{}')
    icu = sdk / f'bin/cache/artifacts/engine/linux-{flutter_arch}'
    icu.mkdir(parents=True)
    (icu / 'icudtl.dat').write_bytes(b'test ICU')
    shebang = '#!' + sys.executable + '\n'

    flutter = sdk / 'bin/flutter'
    flutter.write_text(shebang + r'''
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
failure = os.environ.get('OUTPUT_TEST_FAIL', '')
state = Path(os.environ['OUTPUT_TEST_STATE'])
if args == ['--version', '--machine']:
    print(json.dumps({'frameworkVersion':'fixture', 'dartSdkVersion':'fixture',
        'engineRevision':'0123456789012345678901234567890123456789',
        'flutterRoot':os.environ['FLUTTER_ROOT']}))
elif args[0] == 'create':
    root = Path(args[-1]); root.mkdir(); (root/'lib').mkdir(); (root/'linux').mkdir()
    (root/'pubspec.yaml').write_text('name: bar\ndependencies:\n  flutter:\n    sdk: flutter\n')
    (root/'lib/main.dart').write_text('void main() {}\n')
    (root/'.gitignore').write_text('/build/\n')
    print('Scaffold completed in ' + str(root))
    print('  $ cd ' + str(root) + '\n  $ flutter run')
    print('scaffold stderr uses ' + str(root), file=sys.stderr)
    if failure == 'create':
        print('Scaffold diagnostic on stdout')
        print('Scaffold diagnostic on stderr', file=sys.stderr)
        sys.exit(21)
elif args == ['pub', 'get']:
    print('Pub output is preserved')
    if failure == 'pub':
        print('Pub diagnostic', file=sys.stderr); sys.exit(22)
    Path('pubspec.lock').write_text('# fixture\n')
elif args[0] in ['build', 'assemble']:
    # On the first build force compiler output to occur inside the meter window.
    # A cached build has no curl child, so it skips this handshake.
    if os.environ.get('OUTPUT_TEST_EXPECT_DOWNLOAD') == '1':
        deadline = time.monotonic() + 8
        while not (state/'active').exists():
            if time.monotonic() > deadline: raise RuntimeError('download did not start concurrently')
            time.sleep(.01)
    print('Compiler stdout while downloading', flush=True)
    print('Compiler warning while downloading', file=sys.stderr, flush=True)
    (state/'compiled').write_text('done')
    if failure == 'compile':
        print('Useful compiler failure', file=sys.stderr); sys.exit(23)
    assets = Path('build/flutter_assets'); assets.mkdir(parents=True, exist_ok=True)
    (assets/'AssetManifest.bin').write_bytes(b'assets')
    if args[0] == 'assemble':
        Path('build/lib').mkdir(exist_ok=True)
        Path('build/lib/libapp.so').write_bytes(b'fixture AOT')
        Path('build/fushell_debug_info').mkdir(exist_ok=True)
        target = next(a.split('=',1)[1] for a in args if a.startswith('-dTargetPlatform='))
        Path('build/fushell_debug_info/app.'+target+'.symbols').write_bytes(b'symbols')
    blocked = os.environ.get('OUTPUT_TEST_BLOCK_PUBLICATION')
    if blocked:
        target = Path(blocked); target.mkdir(exist_ok=True)
        (target/'keep').write_text('not owned by Fushell')
else:
    raise RuntimeError('Unexpected Flutter call: '+repr(args))
''')
    dart = sdk / 'bin/cache/dart-sdk/bin/dart'
    dart.write_text(shebang + r'''
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
if args[0].startswith('--packages='):
    root = Path(args[2]); script = Path(args[1])
    assert script.is_file()
    request = json.loads((script.parent/'request.json').read_text())
    shutil.rmtree(root/'linux')
    (root/'test').mkdir()
    (root/'fushell.json').write_text(json.dumps({'schemaVersion':1,
        'applicationId':request['applicationId'], 'instance':'multiple'}))
    print('helper output in '+str(root))
elif args[0] == 'format':
    print('Formatted '+args[1])
    print('Formatter warning in '+args[1], file=sys.stderr)
    if os.environ.get('OUTPUT_TEST_FAIL') == 'format':
        print('Useful format failure', file=sys.stderr); sys.exit(24)
else:
    raise RuntimeError('Unexpected Dart call: '+repr(args))
''')
    curl = tools / 'curl'
    curl.write_text(shebang + r'''
import hashlib, json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
url = args[args.index('--url')+1]
dest = Path(args[args.index('--output')+1])
state = Path(os.environ['OUTPUT_TEST_STATE'])
engine = b'fixture engine bytes'
if url.endswith('/metadata.json'):
    modes = {m:{'file':'engine-'+m+'.so', 'sha256':hashlib.sha256(engine).hexdigest()}
             for m in ['debug','profile','release']}
    dest.write_text(json.dumps({'schema':1,'engine_revision':'0123456789012345678901234567890123456789',
        'flutter_version':'fixture','dart_version':'fixture','artifacts':{os.environ['OUTPUT_TEST_ARCH']:modes}}))
else:
    assert '--progress-bar' in args  # Keep real curl progress; don't delete the feature.
    (state/'curl-pid').write_text(str(os.getpid()))
    sys.stderr.write('\r0.7%'); sys.stderr.flush()
    (state/'active').write_text('yes')
    deadline = time.monotonic()+8
    while not (state/'compiled').exists():
        if time.monotonic()>deadline: raise RuntimeError('compiler did not overlap download')
        time.sleep(.01)
    if os.environ.get('OUTPUT_TEST_FAIL') == 'compile':
        time.sleep(30)  # The parent must cancel/reap us before displaying the error.
    dest.write_bytes(engine)
    time.sleep(.05)
    sys.stderr.write('\r100.0%\n'); sys.stderr.flush()
    (state/'finished').write_text('yes')
    if os.environ.get('OUTPUT_TEST_FAIL') == 'hash': dest.write_bytes(b'bad hash')
''')
    for path in (flutter, dart, curl):
        path.chmod(0o755)
    env = dict(os.environ, FLUTTER_ROOT=str(sdk), FLUTTER_SDK='/unused/sdk',
               PATH=str(tools)+os.pathsep+os.environ.get('PATH',''),
               OUTPUT_TEST_ARCH=arch, FUSHELL_ENGINE_REPOSITORY='https://example.invalid/engine')
    env.pop('FUSHELL_RUNTIME_LIBS', None)

    counter = 0
    def invoke(args, *, expected=0, failure='', download=False, blocked=''):
        global counter
        counter += 1
        state = work / f'state-{counter}'; state.mkdir()
        variables = dict(env, OUTPUT_TEST_STATE=str(state), OUTPUT_TEST_FAIL=failure,
                         OUTPUT_TEST_EXPECT_DOWNLOAD='1' if download else '0',
                         OUTPUT_TEST_BLOCK_PUBLICATION=blocked)
        result = subprocess.run([binary, *args], cwd=work, env=variables,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return result, state

    # Success guidance describes the final project only, including shell quoting.
    for name, flags in [('bar', []), ("folder with ' quotes", ['--project-name=bar'])]:
        result, _ = invoke(['create', '--no-pub', *flags, name])
        combined = result.stdout + result.stderr
        assert b'.fushell-create-' not in combined, combined
        assert b'$ flutter run' not in combined and b'\n  fushell run\n' in result.stdout
        assert (work/name/'vendor/fushell/lib/fushell.dart').is_file()
        assert not (work/name/'linux').exists()
        if "'" in name: assert b"'\\''" in result.stdout
    # Failures retain both output streams without advertising a published project.
    for failure, diagnostic in [('create',b'Scaffold diagnostic'), ('format',b'Useful format failure')]:
        result, _ = invoke(['create', failure], expected=1, failure=failure)
        assert diagnostic in result.stderr, result.stderr
        assert b'Fushell project created at' not in result.stdout
        assert not (work/failure).exists()
    result, _ = invoke(['create','pub_failure'], expected=1, failure='pub')
    assert (work/'pub_failure/lib/main.dart').is_file()
    assert b'Pub diagnostic' in result.stderr and b'Fushell project created at' not in result.stdout

    project = work/'bar'
    for mode in ['debug','profile','release']:
        result, state = invoke(['build','--'+mode,str(project)], download=True)
        entry = project/f'build/linux/{flutter_arch}/{mode}/bar'
        log = result.stderr
        assert entry.is_file() and os.access(entry, os.X_OK), entry
        assert log.count(b'bundle entry:') == 1
        assert b'bundle entry: '+os.fsencode(entry)+b'\n' in log, log
        assert b'.fushell-stage-' not in log and b'$ mkdir' not in log, log
        assert log.index(b'100.0%') < log.index(b'Compiler stdout'), log
        assert log.index(b'100.0%') < log.index(b'Compiler warning'), log
        assert log.index(b'Compiler warning') < log.index(b'bundle entry:'), log
        assert (state/'finished').exists()
        assert not list(entry.parent.parent.glob('.*.fushell-stage-*'))
    # A cached build and a quoted custom destination still report the final file.
    result, _ = invoke(['build',str(project),'dist with spaces'])
    assert b'bundle entry: '+os.fsencode(project/'dist with spaces/bar')+b'\n' in result.stderr
    assert b'0.7%' not in result.stderr

    cache = project/f'build/fushell_flutter_engine/{arch}/{revision}/engine-debug.so'
    old_entry = project/f'build/linux/{flutter_arch}/debug/bar'
    old_bytes = old_entry.read_bytes()
    for failure, diagnostic in [('compile', b'Useful compiler failure'), ('hash', b'EngineHashMismatch')]:
        cache.unlink(missing_ok=True)
        result, state = invoke(['build',str(project)], failure=failure, expected=1, download=True)
        assert diagnostic in result.stderr, result.stderr
        assert b'bundle entry:' not in result.stderr and b'fushell bundle ready:' not in result.stderr
        assert old_entry.read_bytes() == old_bytes
        assert not list(old_entry.parent.parent.glob('.*.fushell-stage-*'))
        pid = int((state/'curl-pid').read_text())
        try: os.kill(pid, 0)
        except ProcessLookupError: pass
        else: raise AssertionError('download process survived the failed build')
    blocked = project/'blocked'
    result, _ = invoke(['build',str(project),str(blocked)], expected=1, download=True, blocked=str(blocked))
    assert b'bundle entry:' not in result.stderr and b'fushell bundle ready:' not in result.stderr
    assert (blocked/'keep').read_text() == 'not owned by Fushell' and not (blocked/'bar').exists()
    assert not list(work.glob('.fushell-create-*'))

print('Create guidance, concurrent build output, published paths and failure rollback checks passed.')
