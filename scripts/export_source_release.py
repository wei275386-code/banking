"""Export an allowlisted Git commit as a deterministic source candidate archive."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release.source_contract import GitSource, canonical_json, load_inputs
from release.validation import ContractError, validate


def export_source(repo, commit, output, profile='production', allow_dirty=False):
    source = GitSource(repo, commit)
    dirty = source.dirty()
    if dirty and not allow_dirty:
        raise ContractError('dirty_checkout')
    paths, version, _ = load_inputs(source, profile)
    output = Path(output)
    if output.exists() or output.is_symlink():
        raise ContractError('output_already_exists')
    if not output.parent.is_dir():
        raise ContractError('output_parent_missing')
    entries = []
    staged = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.source-candidate-', delete=False) as raw:
            staged = Path(raw.name)
            with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode='w|', format=tarfile.PAX_FORMAT) as archive:
                    with source.blobs() as blobs:
                        for path in paths:
                            def append(reader, size, mode, path=path):
                                info = tarfile.TarInfo('source/' + path)
                                info.size = size
                                info.mode = 0o755 if mode == '100755' else 0o644
                                info.mtime = 0
                                archive.addfile(info, reader)
                            entries.append(source.stream(blobs, path, append))
                    provenance = {
                        'kind': 'source-candidate',
                        'release_status': 'candidate', 'commit': source.commit,
                        'tree': source.tree, 'profile': profile, 'dirty': dirty,
                        'version': version, 'files': entries,
                        'input_manifest_sha256': hashlib.sha256(canonical_json(entries)).hexdigest(),
                        'limitations': ['Source input export only; no compiled artifacts or distribution acceptance.',
                                        'Build, runtime and device validation are recorded separately.']}
                    validate(provenance, source.metadata('release/source-provenance.schema.json'))
                    data = canonical_json(provenance) + b'\n'
                    info = tarfile.TarInfo('release-provenance.json')
                    info.size, info.mode, info.mtime = len(data), 0o644, 0
                    archive.addfile(info, io.BytesIO(data))
            raw.flush()
            os.fsync(raw.fileno())
        # link is atomic and refuses an existing destination, including races.
        os.link(staged, output)
        digest = hashlib.sha256()
        with output.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        return {'release_status': 'candidate', 'commit': source.commit,
                'profile': profile, 'dirty': dirty, 'file_count': len(entries),
                'archive_sha256': digest.hexdigest(),
                'input_manifest_sha256': provenance['input_manifest_sha256']}
    except FileExistsError:
        raise ContractError('output_already_exists') from None
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--commit', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--profile', choices=['production', 'dev-tests'], default='production')
    parser.add_argument('--allow-dirty', action='store_true', help='Explicit development exception; payload still uses commit blobs and status remains candidate.')
    args = parser.parse_args(argv)
    try:
        result = export_source(args.repo, args.commit, args.output, args.profile, args.allow_dirty)
    except (ContractError, OSError):
        # OS messages may contain private paths. Only contract codes are public.
        exc = sys.exc_info()[1]
        print(json.dumps({'release_status': 'candidate', 'export_status': 'blocked',
                          'error': str(exc) if isinstance(exc, ContractError) else 'export_io_failed'}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
