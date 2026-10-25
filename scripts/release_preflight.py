"""Read-only release input, lock, toolchain and pipeline preflight.

Preflight cannot authorize release-ready: platform acceptance and T01-T25 are
separate gates. No installs, signing, network calls or credential values occur.
"""
import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import plistlib
import shutil
import time
from urllib.parse import urlsplit
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release.source_contract import GitSource, check_path, load_inputs
from release.validation import ContractError, validate

TOOL_NAMES = ('xcodebuild', 'swift', 'xcodegen')
SDK_PLATFORMS = ('MacOSX', 'iPhoneOS')
SHA_PATTERN = re.compile(r'^[0-9a-f]{64}$')
VERSION_PATTERNS = {
    'xcodebuild': re.compile(r'^Xcode ([0-9]+(?:\.[0-9]+){1,3})$', re.MULTILINE),
    'swift': re.compile(r'(?:Apple )?Swift version ([0-9]+(?:\.[0-9]+){1,3})'),
    'xcodegen': re.compile(r'(?:Version: ?)?([0-9]+(?:\.[0-9]+){1,3})'),
}


def file_sha256(path, max_seconds=10):
    """Bounded-memory diagnostic hash, without publishing installation paths."""
    started = time.monotonic()
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            if time.monotonic() - started > max_seconds:
                raise ContractError('toolchain_hash_timeout')
            digest.update(chunk)
    return digest.hexdigest()


def discover_tools():
    developer = None
    try:
        selection = subprocess.run(['xcode-select', '-p'], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, timeout=5,
                                   check=True, text=True)
        candidate = Path(selection.stdout.strip())
        if candidate.is_absolute() and candidate.is_dir():
            developer = candidate.resolve()
    except (OSError, subprocess.SubprocessError):
        pass
    paths = {}
    if developer is not None:
        paths['xcodebuild'] = developer / 'usr/bin/xcodebuild'
        paths['swift'] = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
    xcodegen = shutil.which('xcodegen')
    if xcodegen:
        paths['xcodegen'] = Path(xcodegen).resolve()

    def read(name):
        empty = {'available': False, 'version': None, 'versions': [], 'sha256': None}
        path = paths.get(name)
        if path is None:
            return name, empty
        flag = '-version' if name == 'xcodebuild' else '--version'
        try:
            result = subprocess.run([str(path), flag], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=5,
                                    check=True, text=True)
            match = VERSION_PATTERNS[name].search(result.stdout[:4096])
            if match is None:
                return name, empty
            version = match.group(1)
            record = {'available': True, 'version': version, 'versions': [version],
                      'sha256': file_sha256(path.resolve())}
            if name == 'xcodebuild':
                build = re.search(r'^Build version ([A-Za-z0-9]+)$', result.stdout, re.MULTILINE)
                record['build'] = build.group(1) if build else None
            return name, record
        except (OSError, subprocess.SubprocessError, ContractError):
            return name, empty

    def sdk(platform):
        empty = {'available': False, 'version': None, 'settings_sha256': None}
        if developer is None:
            return platform, empty
        settings = developer / ('Platforms/' + platform + '.platform/Developer/SDKs/' + platform + '.sdk/SDKSettings.plist')
        try:
            # Hash the exact SDKSettings bytes recorded in native-toolchain.json.
            digest = file_sha256(settings)
            with settings.open('rb') as stream:
                document = plistlib.load(stream)
            version = document.get('Version')
            if not isinstance(version, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', version):
                return platform, empty
            return platform, {'available': True, 'version': version,
                              'settings_sha256': digest}
        except (OSError, ValueError, TypeError, ContractError):
            return platform, empty

    with ThreadPoolExecutor(max_workers=5) as pool:
        tool_tasks = [pool.submit(read, name) for name in TOOL_NAMES]
        sdk_tasks = [pool.submit(sdk, name) for name in SDK_PLATFORMS]
        tool_records = dict(task.result() for task in tool_tasks)
        tool_records['sdks'] = dict(task.result() for task in sdk_tasks)
    return tool_records


def discover_signing():
    try:
        result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, timeout=5, check=False)
        output = result.stdout if result.returncode == 0 else ''
    except (OSError, subprocess.SubprocessError):
        output = ''
    # Identity hashes, names, team IDs and errors never leave this function.
    return {'developer_id_application': '"Developer ID Application:' in output,
            'apple_distribution': '"Apple Distribution:' in output or '"iPhone Distribution:' in output}


def normalized_name(name):
    return re.sub(r'[-_.]+', '-', name).lower() if isinstance(name, str) else None


def valid_digest(value):
    return isinstance(value, str) and SHA_PATTERN.fullmatch(value) is not None


def valid_artifact(artifact):
    if not isinstance(artifact, dict):
        return False
    url = artifact.get('url')
    if not isinstance(url, str):
        return False
    try:
        parsed = urlsplit(url)
    except ValueError:
        return False
    return (isinstance(artifact.get('version'), str) and bool(artifact['version'])
            and parsed.scheme == 'https' and bool(parsed.hostname)
            and parsed.username is None and parsed.password is None
            and valid_digest(artifact.get('sha256'))
            and type(artifact.get('size')) is int and artifact['size'] > 0)


def native_lock_failures(lock, tools):
    failures = []
    locked_tools = lock.get('tools', {})
    if not isinstance(locked_tools, dict):
        return ['native_lock_tools_invalid']
    for name in TOOL_NAMES:
        value = locked_tools.get(name, {})
        actual = tools.get(name, {})
        if (not isinstance(value, dict) or not isinstance(value.get('version'), str)
                or not value['version'] or not valid_digest(value.get('sha256'))):
            failures.append('native_lock_incomplete_' + name)
            continue
        if value['version'] != actual.get('version'):
            failures.append('toolchain_version_mismatch_' + name)
        if value['sha256'] != actual.get('sha256'):
            failures.append('toolchain_sha256_mismatch_' + name)
    if (not isinstance(lock.get('xcode_build'), str)
            or not re.fullmatch('[A-Za-z0-9]+', lock['xcode_build'])):
        failures.append('native_lock_xcode_build_missing')
    elif lock['xcode_build'] != tools.get('xcodebuild', {}).get('build'):
        failures.append('toolchain_xcode_build_mismatch')
    sdks = lock.get('sdks')
    if not isinstance(sdks, list) or not all(isinstance(s, dict) for s in sdks):
        return failures + ['native_lock_sdk_inventory_invalid']
    names = [s.get('platform') for s in sdks]
    if (not all(isinstance(n, str) for n in names)
            or len(names) != len(set(names)) or set(names) != set(SDK_PLATFORMS)):
        failures.append('native_lock_sdk_inventory_invalid')
    for sdk in sdks:
        platform = sdk.get('platform')
        if not isinstance(platform, str) or platform not in SDK_PLATFORMS:
            continue
        actual = tools.get('sdks', {}).get(platform, {})
        if (not isinstance(sdk.get('version'), str) or not sdk['version']
                or not valid_digest(sdk.get('settings_sha256'))
                or sdk.get('hash_kind') != 'SDKSettings.plist_bytes'):
            failures.append('native_lock_sdk_incomplete_' + platform)
            continue
        if sdk['version'] != actual.get('version'):
            failures.append('toolchain_sdk_version_mismatch_' + platform)
        if sdk['settings_sha256'] != actual.get('settings_sha256'):
            failures.append('toolchain_sdk_sha256_mismatch_' + platform)
    return failures


def python_lock_failures(lock, spec, paths):
    failures = []
    runtime = lock.get('python')
    wheels = lock.get('wheels')
    dependencies = spec.get('direct_dependencies')
    if (not isinstance(wheels, list) or not wheels or not isinstance(dependencies, list)
            or not dependencies or not all(isinstance(n, str) and n for n in dependencies)):
        return ['python_lock_dependency_closure_missing']
    names = [normalized_name(w.get('name')) if isinstance(w, dict) else None for w in wheels]
    if (None in names or len(names) != len(set(names))
            or any(normalized_name(n) != n for n in dependencies)
            or not set(dependencies) <= set(names)):
        failures.append('python_lock_dependency_closure_missing')
    if not all(valid_artifact(a) for a in [runtime] + wheels):
        failures.append('python_lock_artifact_incomplete')
    scripts = lock.get('processor_scripts')
    if (not isinstance(scripts, list) or not scripts or not all(isinstance(p, str) for p in scripts)
            or len(scripts) != len(set(scripts))):
        failures.append('python_lock_processor_inputs_missing')
    else:
        for path in scripts:
            check_path(path)
            if not path.startswith('scripts/') or not path.endswith('.py') or path not in paths:
                failures.append('python_lock_processor_input_not_allowlisted')
    return failures


def dependency_failures(source, paths, tools):
    declaration = source.metadata('release/dependencies.json')
    validate(declaration, source.metadata('release/dependencies.schema.json'))
    failures = []
    hashes = {}
    for component in ('native', 'python', 'node'):
        spec = declaration[component]
        if component == 'node' and spec.get('scope') == 'development-only':
            continue
        if spec['status'] != 'locked' or not spec['lock']:
            failures.append(component + '_lock_pending')
            continue
        path = check_path(spec['lock'])
        if path not in paths:
            failures.append(component + '_lock_not_allowlisted')
            continue
        lock = source.metadata(path)
        _, _, oid = source.entry(path)
        # Exact committed bytes, including whitespace, match external provenance.
        hashes[component] = hashlib.sha256(source.git('cat-file', 'blob', oid)).hexdigest()
        if not isinstance(lock, dict):
            failures.append(component + '_lock_invalid')
        elif component == 'node':
            if not isinstance(lock.get('lockfileVersion'), int) or not lock.get('packages'):
                failures.append('node_lock_invalid')
        elif component == 'native':
            failures.extend(native_lock_failures(lock, tools))
        else:
            failures.extend(python_lock_failures(lock, spec, paths))
    if declaration['status'] != 'locked':
        failures.append('dependency_declaration_pending')
    for item in declaration['pipeline']:
        if item['status'] != 'complete':
            failures.append('pipeline_pending:' + item['id'])
    return sorted(set(failures)), hashes


def python_closure_failures(source, paths):
    """Parse local imports, never execute committed processor code."""
    modules = {Path(p).stem: p for p in source.entries if p.startswith('scripts/') and p.endswith('.py')}
    selected = set(paths)
    missing = set()
    for path in paths:
        if not path.startswith('scripts/') or not path.endswith('.py'):
            continue
        _, _, oid = source.entry(path)
        try:
            tree = ast.parse(source.git('cat-file', 'blob', oid), filename=path)
        except (SyntaxError, ValueError):
            missing.add('python_source_invalid:' + path)
            continue
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [n.name.split('.')[0] for n in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module:
                module = node.module.removeprefix('scripts.').split('.')[0]
                names = [module]
            for name in names:
                if name in modules and modules[name] not in selected:
                    missing.add('python_input_missing:' + modules[name])
    return sorted(missing)


def compiled_capability_failures(source, version, paths):
    """Commit-only verification of manually compiled capabilities, never a repo
    lookup from the installed App. Version bumps must update all declarations.
    Minimal synthetic pipelines without a native capability have no such check.
    """
    name = 'native/PaymentImageCore/Sources/PaymentImageCore/WorkspaceCompatibility.swift'
    if name not in source.entries:
        return []
    required = {name, 'release/compatibility.json', 'release/runtime-lock.json'}
    if not required.issubset(paths):
        return ['compiled_capability_inputs_missing']
    try:
        _, _, oid = source.entry(name)
        raw = source.git('cat-file', 'blob', oid)
        if len(raw) > 64 * 1024:
            raise ValueError('capability too large')
        text = raw.decode('utf-8')
        def declaration(key, pattern):
            values = re.findall(r'public static let ' + key + r'\s*=\s*' + pattern, text)
            if len(values) != 1:
                raise ValueError('ambiguous capability')
            return values[0]
        compiled_version = declaration('appVersion', r'"([^"\n]+)"')
        compiled_build = int(declaration('buildNumber', r'([0-9]+)\b'))
        compiled_runtime = declaration('runtimeVersion', r'"([^"\n]+)"')
        policy = source.metadata('release/compatibility.json')
        lock = source.metadata('release/runtime-lock.json')
        if set(policy) != {'app_version', 'build_number', 'runtime_version'}:
            raise ValueError('release capability fields')
        if (compiled_version != version['app_version'] or compiled_build != version['build_number'] or
                policy['app_version'] != compiled_version or policy['build_number'] != compiled_build or
                compiled_runtime != lock['runtime_version']):
            return ['compiled_release_version_drift']
        if policy['runtime_version'] != compiled_runtime:
            return ['compiled_runtime_capability_drift']
        return []
    except (ContractError, UnicodeError, ValueError, KeyError, TypeError):
        return ['compiled_capability_contract_invalid']


def preflight(repo, commit='HEAD', channel='mac-developer-id', tools=None, signing=None):
    report = {'release_status': 'candidate',
              'preflight_status': 'blocked', 'channel': channel, 'failures': []}
    if channel not in {'mac-developer-id', 'ios-testflight', 'ios-app-store', 'ios-ad-hoc'}:
        report['failures'] = ['invalid_channel']
        return report
    try:
        source = GitSource(repo, commit)
        report['commit'], report['tree'] = source.commit, source.tree
        report['dirty'] = source.dirty()
        if report['dirty']:
            report['failures'].append('dirty_checkout')
        paths, version, _ = load_inputs(source)
        report['version'], report['production_input_count'] = version, len(paths)
        report['source_inputs_status'] = 'valid'
        report['failures'].extend(python_closure_failures(source, paths))
        report['failures'].extend(compiled_capability_failures(source, version, paths))
        discovered = discover_tools() if tools is None else tools
        report['tools'] = discovered
        locks, hashes = dependency_failures(source, paths, discovered)
        report['lock_document_sha256'] = hashes
        report['failures'].extend(locks)
        identities = discover_signing() if signing is None else signing
        report['signing_capability'] = identities
        key = 'developer_id_application' if channel == 'mac-developer-id' else 'apple_distribution'
        if not identities.get(key, False):
            report['failures'].append('required_signing_identity_unavailable')
    except ContractError as error:
        report['failures'].append(str(error))
    report['failures'] = sorted(set(report['failures']))
    if not report['failures']:
        report['preflight_status'] = 'passed'
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--commit', default='HEAD')
    parser.add_argument('--channel', choices=['mac-developer-id', 'ios-testflight', 'ios-app-store', 'ios-ad-hoc'], default='mac-developer-id')
    args = parser.parse_args(argv)
    result = preflight(args.repo, args.commit, args.channel)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result['preflight_status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
