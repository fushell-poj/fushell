#!/usr/bin/env python3
"""Real CLI orchestration/TTY/filesystem tests with fake SDK executables.

The fake Dart helper intentionally does not test YAML/template rendering; those
are covered by create_pubspec_test.dart and create_flutter_smoke.sh using Flutter.
"""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/fushell').resolve())

with tempfile.TemporaryDirectory(prefix='fushell-create-test-') as temp:
    work = Path(temp)
    sdk = work / 'sdk'
    (sdk / 'bin/cache/dart-sdk/bin').mkdir(parents=True)
    (sdk / 'packages/flutter_tools/.dart_tool').mkdir(parents=True)
    (sdk / 'packages/flutter_tools/.dart_tool/package_config.json').write_text('{}')
    log = work / 'invocations.jsonl'
    shebang = '#!' + sys.executable + '\n'
    flutter = sdk / 'bin/flutter'
    flutter.write_text(shebang + r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['TEST_CALL_LOG'], 'a') as log:
    log.write(json.dumps(['flutter', str(Path.cwd()), args]) + '\n')
if args == ['--version', '--machine']:
    print(json.dumps({'frameworkVersion':'3.41.9', 'dartSdkVersion':'3.11.5', 'engineRevision':'0123456789012345678901234567890123456789', 'flutterRoot':os.environ['FLUTTER_ROOT']}))
elif args[0] == 'create':
    assert all(x in args for x in ['--empty','--platforms=linux','--no-pub','--template=app'])
    root = Path(args[-1]); root.mkdir()
    (root / 'lib').mkdir(); (root / 'linux').mkdir()
    name = args[args.index('--project-name')+1]
    (root / 'pubspec.yaml').write_text('name: '+name+'\ndependencies:\n  flutter:\n    sdk: flutter\n')
    (root / 'lib/main.dart').write_text('void main() {}\n')
    (root / '.gitignore').write_text('/build/\n')
    (root / '.metadata').write_text('project_type: app\n')
    if os.environ.get('TEST_FAIL') == 'scaffold': sys.exit(41)
elif args == ['pub','get']:
    if os.environ.get('TEST_FAIL') == 'pub': sys.exit(42)
    Path('pubspec.lock').write_text('# fake lock\n')
else:
    raise SystemExit('unexpected Flutter call: '+repr(args))
''')
    dart = sdk / 'bin/cache/dart-sdk/bin/dart'
    dart.write_text(shebang + r'''
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['TEST_CALL_LOG'], 'a') as log:
    log.write(json.dumps(['dart', str(Path.cwd()), args]) + '\n')
if args[0].startswith('--packages='):
    if os.environ.get('TEST_FAIL') == 'configure': sys.exit(43)
    script = Path(args[1]); root = Path(args[2])
    assert script.name == 'configure.dart' and script.is_file()
    for name in ['app.dart','main.dart.tmpl','widget_test.dart.tmpl','README.md.tmpl']:
        assert (script.parent / name).is_file()
    shutil.rmtree(root / 'linux')
    (root / 'test').mkdir()
    request = json.loads((script.parent / 'request.json').read_text())
    (root / 'fushell.json').write_text(json.dumps(request))
elif args[0] != 'format':
    raise SystemExit('unexpected Dart call')
''')
    flutter.chmod(0o755); dart.chmod(0o755)
    env = dict(os.environ, FLUTTER_ROOT=str(sdk), FLUTTER_SDK='/wrong/sdk', TEST_CALL_LOG=str(log))

    def invoke(args, *, cwd=work, fail=None, expected=0):
        log.write_text('')
        result = subprocess.run([binary, *args], cwd=cwd, env=dict(env, TEST_FAIL=fail or ''),
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        calls = [json.loads(x) for x in log.read_text().splitlines()]
        return result, calls

    result, calls = invoke(['create', '--no-pub', '--project-name', 'app', "folder with ' quotes $HOME"])
    target = work / "folder with ' quotes $HOME"
    assert (target / 'vendor/fushell/lib/fushell.dart').is_file()
    assert not (target / 'linux').exists() and not (target / 'pubspec.lock').exists()
    assert not any(x[0]=='flutter' and x[2][:2]==['pub','get'] for x in calls)
    assert [x[2][-1] for x in calls if x[0]=='flutter' and x[2][0]=='create'][0] != str(target)
    assert b"'\\''" in result.stdout  # printed shell cd command escapes apostrophes

    invoke(['create', '--single-instance', 'single'])
    request = json.loads((work / 'single/fushell.json').read_text())
    assert request['single'] and request['applicationId']=='com.example.single'
    assert (work / 'single/pubspec.lock').exists()

    for entry in ['single', "folder with ' quotes $HOME"]:
        _, calls = invoke(['create', '--project-name=app', entry], expected=1)
        assert not calls  # refuse before invoking Flutter
    (work/'git_only/.git').mkdir(parents=True)
    _, calls = invoke(['create','git_only'], expected=1); assert not calls
    (work/'file').write_text('keep')
    _, calls = invoke(['create','file'], expected=1); assert not calls
    (work/'link').symlink_to(work/'single', target_is_directory=True)
    _, calls = invoke(['create','link'], expected=1); assert not calls
    _, calls = invoke(['create','link/nested'], expected=1); assert not calls
    _, calls = invoke(['create'], expected=1); assert not calls
    _, calls = invoke(['create','--interactive','interactive'], expected=1); assert not calls
    invoke(['help'], expected=2)
    invoke(['create','--overwrite','single'], expected=2)

    dot = work/'dot_app'; dot.mkdir(); inode = dot.stat().st_ino
    invoke(['create','--no-pub','.'], cwd=dot)
    assert dot.stat().st_ino == inode and (dot/'lib/main.dart').exists()

    for failure in ['scaffold','configure']:
        invoke(['create',failure], fail=failure, expected=1)
        assert not (work/failure).exists()
        empty = work/(failure+'_empty'); empty.mkdir()
        invoke(['create',empty.name], fail=failure, expected=1)
        assert list(empty.iterdir()) == []
    result, _ = invoke(['create','pub_failed'], fail='pub', expected=1)
    assert (work/'pub_failed/lib/main.dart').exists()
    assert b'project created at' not in result.stdout
    assert b'flutter pub get' in result.stderr
    assert not list(work.glob('.fushell-create-*'))

    # Real pseudo-terminal verifies the executable selects/consumes the wizard.
    def wizard(responses, *, expected=0):
        master, slave = pty.openpty()
        proc = subprocess.Popen([binary, 'create', '--no-pub'], cwd=work, env=env,
                                stdin=slave, stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)
        output = bytearray(); deadline = time.monotonic()+20; index=0
        prompts = [b'Output directory:', b'Project name [', b'Organization [', b'Description [', b'Single instance [', b'Application ID [', b'Create project [']
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], .1)
                if ready:
                    try: chunk = os.read(master, 65536)
                    except OSError: break
                    if not chunk: break
                    output.extend(chunk)
                if index < len(prompts) and prompts[index] in output:
                    if responses[index] == b'\x03':
                        proc.send_signal(2)
                    else:
                        os.write(master, responses[index])
                    index += 1
                if proc.poll() is not None: break
            assert proc.wait(timeout=5)==expected, output.decode(errors='replace')
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()
            os.close(master)
        return bytes(output)
    wizard([b'wizard_app\n',b'\n',b'\n',b'\n',b'n\n',b'\n',b'y\n'])
    assert (work/'wizard_app/lib/main.dart').exists()
    wizard([b'cancelled\n',b'\n',b'\n',b'\n',b'n\n',b'\n',b'n\n'])
    assert not (work/'cancelled').exists()
    wizard([b'\x03'], expected=-2)  # SIGINT before generation
    assert not list(work.glob('.fushell-create-*'))

print('Create orchestration, no-overwrite, failure, and PTY smoke checks passed.')
