#!/usr/bin/env bash
# Real selected-SDK YAML parsing plus the compiled doctor's project orchestration.
# Engine HTTP is deliberately stubbed; no .so is downloaded and no GPU is needed.
set -euo pipefail
binary=$(realpath "${1:-zig-out/bin/fushell}")
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${FLUTTER_ROOT:?Set FLUTTER_ROOT to the initialized SDK}"
flutter="$FLUTTER_ROOT/bin/flutter"
dart="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
packages="$FLUTTER_ROOT/packages/flutter_tools/.dart_tool/package_config.json"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$dart" --packages="$packages" "$repo/tests/doctor_project_test.dart"

if ! "$binary" create "$work/app" > "$work/create.stdout" 2> "$work/create.stderr"; then
  cat "$work/create.stdout" "$work/create.stderr" >&2
  exit 1
fi
if grep -F '.fushell-create-' "$work/create.stdout" "$work/create.stderr" ||
   grep -F '$ flutter run' "$work/create.stdout" "$work/create.stderr"; then
  echo 'create exposed instructions for its private Flutter scaffold' >&2
  exit 1
fi
grep -F "Fushell project created at $work/app." "$work/create.stdout"
grep -Fx '  fushell run' "$work/create.stdout"
"$flutter" --version --machine > "$work/flutter.json"
mkdir "$work/bin"
python3 - "$work" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
info = json.loads((root / 'flutter.json').read_text())
arch = 'aarch64' if os.uname().machine == 'aarch64' else 'x86_64'
metadata = {'schema': 1, 'engine_revision': info['engineRevision'],
            'flutter_version': info.get('flutterVersion', info.get('frameworkVersion')),
            'dart_version': info['dartSdkVersion'],
            'artifacts': {arch: {mode: {'file': mode + '.so', 'sha256': '0' * 64}
                                for mode in ['debug', 'profile', 'release']}}}
(root / 'metadata.json').write_text(json.dumps(metadata))
(root / 'bin/curl').write_text('#!' + sys.executable + '\n' + '''import os, sys\nfrom pathlib import Path\nassert sys.argv[-2] == '--url' and sys.argv[-1].endswith('/metadata.json')\nsys.stdout.write(Path(os.environ['DOCTOR_METADATA']).read_text() + '\\n200')\n''')
(root / 'bin/curl').chmod(0o755)
PY
export DOCTOR_METADATA="$work/metadata.json"
export PATH="$work/bin:$PATH"
export FUSHELL_ENGINE_REPOSITORY=https://example.invalid/doctor-fixture
# Deterministic missing desktop is only a warning for this multiple-instance app.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/doctor-test-bus
export WAYLAND_DISPLAY=/nonexistent/doctor-test-display
unset WAYLAND_SOCKET
python3 - "$binary" "$work" <<'PY'
import hashlib, json, pathlib, subprocess, sys
binary, root = sys.argv[1], pathlib.Path(sys.argv[2])
project = root / 'app'
def snapshot():
    return {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in project.rglob('*') if p.is_file()}
before = snapshot()
result = subprocess.run([binary, 'doctor', '--machine', str(project)], capture_output=True, timeout=60)
assert result.returncode == 0, (result.stdout, result.stderr)
report = json.loads(result.stdout)
checks = {c['id']: c for c in report['checks']}
assert checks['project.pubspec']['status'] == 'ok', report
assert checks['project.packages']['status'] == 'ok', report
assert checks['engine']['status'] == 'ok', report
assert snapshot() == before, 'doctor modified project sources or cache'
(root / 'doctor.json').write_bytes(result.stdout)
print('Real Flutter YAML/configuration and doctor read-only integration checks passed.')
PY
