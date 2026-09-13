"""A restored real core archive must write to the current state directory only."""
from pathlib import Path
import subprocess
import sys
import tempfile

private = Path(__file__).resolve().parents[1] / '.local'
private.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='savestate-path-test-', dir=private) as directory:
    root = Path(directory)
    source, destination = root / 'source', root / 'destination'
    for folder in (source, destination):
        (folder / 'sdmc/probe').mkdir(parents=True)
    archive = root / 'archive.bin'
    subprocess.run([sys.argv[1], 'save', str(source), str(archive)], check=True)
    subprocess.run([sys.argv[1], 'load', str(destination), str(source), str(archive)], check=True)
    assert not (source / 'sdmc/probe/written-by-load').exists()
    assert (destination / 'sdmc/probe/written-by-load').read_bytes() == b'destination\n'
