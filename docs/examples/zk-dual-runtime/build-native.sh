#!/usr/bin/env bash
# Configure a disposable manifest for CLJRS_HOME, then build a DEBUG plugin.
set -euo pipefail
cd "$(dirname "$0")"
export CLJRS_HOME="${CLJRS_HOME:-../../../../clojurust}"
python3 - <<'PY'
import json
import os
from pathlib import Path

home = Path(os.environ['CLJRS_HOME']).resolve()
if not (home / 'crates/cljrs-interop/Cargo.toml').is_file():
    raise SystemExit('Set CLJRS_HOME to a clojurust checkout; default: ../../../../clojurust from this example.')
source = Path('native')
build = source / 'target/plugin'
build.mkdir(parents=True, exist_ok=True)
manifest = (source / 'Cargo.toml').read_text()
for crate in ['cljrs-interop', 'cljrs-value', 'cljrs-gc']:
    manifest = manifest.replace(
        f'"../../../../../clojurust/crates/{crate}"',
        json.dumps(str(home / 'crates' / crate)))
manifest = manifest.replace('[lib]', '[lib]\npath = "../../src/lib.rs"')
(build / 'Cargo.toml').write_text(manifest)
(build / 'Cargo.lock').write_bytes((source / 'Cargo.lock').read_bytes())
print(f'Configured native/target/plugin against {home}')
PY
cargo build --locked --manifest-path native/target/plugin/Cargo.toml
