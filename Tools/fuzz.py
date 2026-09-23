"""Run deterministic synthetic mutations with a subprocess watchdog.

Use --count 1000000 for an extended check. A failed run retains the
last synthetic input and copies it to the regression corpus.
"""

import argparse
import hashlib
import os
import signal
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--count", type=int, default=10000)
parser.add_argument("--swift", default="swift")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
scratch = root / ".build-asan"
scratch.mkdir(exist_ok=True)
current = scratch / "mime-fuzz-current.mime"
env = dict(
    os.environ,
    MIME_MUTATIONS=str(args.count),
    MIME_FUZZ_CURRENT=str(current),
    ASAN_OPTIONS="detect_leaks=0",
)
command = [
    args.swift,
    "test",
    "--configuration",
    "release",
    "--sanitize=address",
    "--scratch-path",
    ".build-asan",
    "--filter",
    "MutationTests",
]


def save_regression():
    if current.exists():
        data = current.read_bytes()
        directory = root / "Tests/MIMETests/Fixtures/Regressions"
        directory.mkdir(exist_ok=True)
        path = directory / (hashlib.sha256(data).hexdigest() + ".mime")
        path.write_bytes(data)
        print("Saved synthetic regression:", path.relative_to(root))


process = subprocess.Popen(command, cwd=root, env=env, start_new_session=True)
try:
    status = process.wait(timeout=1800)
except (subprocess.TimeoutExpired, KeyboardInterrupt):
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    save_regression()
    raise
if status:
    save_regression()
    raise subprocess.CalledProcessError(status, command)
current.unlink(missing_ok=True)
