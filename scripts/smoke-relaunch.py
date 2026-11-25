#!/usr/bin/env python3
"""Exercise restart catch-up in the signed native launcher with an isolated index."""

import argparse
import json
import os
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path, help="isolated, built Lumen.app")
args = parser.parse_args()
app = args.app.resolve()
engine = app / "Contents/Resources/lumen"
launcher = app / "Contents/MacOS/Lumen"


def scenario(fallback):
    with tempfile.TemporaryDirectory(prefix="lumen-reopen-") as temporary:
        root = Path(temporary)
        corpus = root / "corpus"
        corpus.mkdir()
        database = root / "index.sqlite"
        command = [str(engine), "--db", str(database)]

        for name in ["existing-reopen-fixture", "deleted-reopen-fixture"]:
            (corpus / f"{name}.txt").write_text("Synthetic fixture.", encoding="utf-8")
        (root / "reopen-scenario").touch()
        index = command + ["index", "--root", str(corpus)]
        if fallback:
            (root / "reopen-fallback").touch()
            pdf = corpus / "slow-reconcile.pdf"
            pdf.write_text("Original synthetic contents", encoding="utf-8")
            helper = root / "pdf-helper"
            helper.write_text(
                '#!/bin/sh\n'
                'fixture=${0%/*}\n'
                'if [ -f "$fixture/hold-reopen" ]; then\n'
                ': > "$fixture/reopen-helper-started"\n'
                '    for step in $(/usr/bin/seq 1 100); do\n'
                '        [ ! -f "$fixture/finish-reopen" ] || break\n'
                '        /bin/sleep 0.05\n'
                '    done\n'
                'fi\n'
                '/bin/cat\n',
                encoding="utf-8",
            )
            helper.chmod(0o700)
            index += ["--documents", "--pdf-helper", str(helper)]
        initial_scan = json.loads(subprocess.check_output(index, timeout=20))
        with sqlite3.connect(database) as conn:
            checkpoint = conn.execute(
                "SELECT value FROM info WHERE key='watch_checkpoint_v1'"
            ).fetchone()
            assert checkpoint, "manual scan did not seed a usable native journal"
            if fallback:
                bookmark = json.loads(checkpoint[0])
                bookmark[2] = (1 << 64) - 1
                conn.execute(
                    "UPDATE info SET value=? WHERE key='watch_checkpoint_v1'",
                    (json.dumps(bookmark),),
                )
        (corpus / "deleted-reopen-fixture.txt").unlink()
        (corpus / "new-offline-reopen-fixture.txt").write_text("Offline add.", encoding="utf-8")
        if fallback:
            (root / "hold-reopen").touch()
            pdf.write_text("Replacement synthetic contents", encoding="utf-8")
        time.sleep(0.65)
        environment = os.environ.copy()
        environment.pop("LUMEN_GEMMA_TEST_HOME", None)
        subprocess.run([str(launcher), "--gui-smoke", str(root), "en"], env=environment, check=True, timeout=25)
        with sqlite3.connect(database) as conn:
            committed = json.loads(conn.execute("SELECT value FROM info WHERE key='scan'").fetchone()[0])
        assert (committed != initial_scan) == fallback, committed
        print(f"Full reconciliation entries: {committed['entries_visited'] if fallback else 0}", flush=True)


scenario(False)
scenario(True)
