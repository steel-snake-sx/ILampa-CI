#!/usr/bin/env python3
"""Strict focused command/artifact contract; never invokes xcodebuild itself."""
import argparse
import json
from pathlib import Path
import re
import shlex
import sys
import xml.etree.ElementTree as ET
import zipfile


CASES = [
    ('control-caf', 'AVPlayerControl', 'AVPlayerControlTests/PlayerStateIntegrationTests/testIndependentAVAudioFileAndAVPlayer'),
    ('control-wav', 'AVPlayerControl', 'AVPlayerControlTests/PlayerStateIntegrationTests/testLocalPlayerAdvancesPausesSeeksAndResumes'),
    ('hosted-caf', 'iLampa', 'iLampaRuntimeTests/PlayerStateIntegrationTests/testIndependentAVAudioFileAndAVPlayer'),
    ('hosted-wav', 'iLampa', 'iLampaRuntimeTests/PlayerStateIntegrationTests/testLocalPlayerAdvancesPausesSeeksAndResumes'),
    ('production-local', 'iLampa', 'iLampaRuntimeTests/PlayerStateIntegrationTests/testProductionStartupWithControlAsset'),
    ('held-progress', 'iLampa', 'iLampaRuntimeTests/PlaybackConcurrencyTests/testHeldProgressCallbackCannotReportTimeAgainstReplacementItem'),
    ('settings-ui', 'iLampa', 'iLampaUITests/iLampaUITests/testLegacySettingsAppearInProductionPluginDetail'),
    ('production-hls-ui', 'iLampa', 'iLampaUITests/iLampaUITests/testPlayerSeekingPauseResumeAndReopen'),
]
DIAGNOSTIC_CASES = [
    ('control-hls-ui', 'AVKitControl', 'AVKitControlUITests/AVKitControlUITests/testIndependentHLSSeekingPauseResumeAndReopen'),
]
ALL_CASES = CASES + DIAGNOSTIC_CASES


def expected_command(out, simulator, phase):
    _, scheme, selection = next(case for case in ALL_CASES if case[0] == phase)
    if not re.fullmatch(r'[0-9A-Fa-f-]{36}', simulator):
        raise ValueError('Expected an explicit simulator UUID')
    return [
        'xcodebuild', 'test', '-project', 'iLampa.xcodeproj', '-scheme', scheme,
        '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={simulator}',
        '-derivedDataPath', (out / 'DerivedData').as_posix(),
        '-resultBundlePath', (out / phase / 'Result.xcresult').as_posix(),
        '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
        '-maximum-test-execution-time-allowance', '180', f'-only-testing:{selection}',
        'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGNING_ALLOWED=YES',
        'AD_HOC_CODE_SIGNING_ALLOWED=YES',
    ]


def expected_artifacts(out, phase):
    return [out / f'{phase}.log', out / phase / 'Result.xcresult',
            out / phase / 'xcodebuild-status.log', out / phase / 'tee-status.log',
            out / phase / 'summary.json', out / phase / 'tests.json',
            out / f'{phase}.xcresult.zip', out / f'{phase}.evidence.zip']


def validate_command(out, simulator, phase, command, record=False):
    expected = expected_command(out, simulator, phase)
    if command != expected:
        raise ValueError(f'Unapproved command/arguments for {phase}: {shlex.join(command)}')
    _, scheme, selection = next(case for case in ALL_CASES if case[0] == phase)
    scheme_path = Path('iLampa.xcodeproj/xcshareddata/xcschemes') / f'{scheme}.xcscheme'
    tree = ET.parse(scheme_path)
    target = selection.split('/')[0]
    matching = [node for node in tree.findall('.//TestableReference')
                if any(ref.get('BlueprintName') == target for ref in node.findall('BuildableReference'))]
    if len(matching) != 1 or matching[0].get('skipped', 'NO') != 'NO':
        raise ValueError(f'{target} is not an enabled test target in {scheme_path}')
    if any(list(node) for node in tree.findall('.//SkippedTests')) or tree.findall('.//TestPlanReference'):
        raise ValueError('Unexpected test exclusions or external test plan')
    for action in tree.findall('.//TestAction'):
        for key, value in action.attrib.items():
            if any(word in key.lower() for word in ('repetition', 'iteration', 'retry')):
                if value.lower() not in ('none', 'no', '0', '1'):
                    raise ValueError(f'Unapproved scheme repetition: {key}={value}')
    artifacts = expected_artifacts(out, phase)
    for path in artifacts:
        if path.exists():
            raise ValueError(f'Refusing to overwrite planned output: {path}')
    if not (out / phase).is_dir():
        raise ValueError('Phase output directory must already be reserved')
    manifest = {'phase': phase, 'scheme': scheme, 'selection': selection, 'argv': command,
                'shellCommand': shlex.join(command), 'expectedArtifacts': [str(path) for path in artifacts]}
    path = out / f'{phase}.command.json'
    if record:
        with path.open('x', encoding='utf-8') as stream:
            json.dump(manifest, stream, indent=2)
    elif json.loads(path.read_text()) != manifest:
        raise ValueError('Execution command differs from the preflight-validated manifest')


def parse_enumeration(scheme, path):
    enabled, disabled, plans, seen = [], [], [], set()
    # Captured Xcode 26.6 flat/text output includes a Plan header and explicitly
    # disabled siblings. Parse the retained native format, not guessed JSON keys.
    identifier = re.compile(r'([A-Za-z_]\w*/[A-Za-z_]\w*/[A-Za-z_]\w*)(?:\(\))?( \(disabled\))?')
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith('Plan '):
            if plans or line != f'Plan {scheme}':
                raise ValueError(f'Unexpected or duplicate enumeration plan: {line!r}')
            plans.append(scheme)
            continue
        match = identifier.fullmatch(line)
        if match is None or match[1] in seen:
            raise ValueError(f'Malformed or duplicate enumerated test: {line!r}')
        seen.add(match[1])
        (disabled if match[2] else enabled).append(match[1])
    return {'scheme': scheme, 'enabledTests': enabled, 'disabledTests': disabled,
            'sourceFormat': 'Xcode 26.6 flat text', 'testBodiesExecuted': False}


def validate_enumeration(phase, path):
    _, scheme, selection = next(case for case in ALL_CASES if case[0] == phase)
    result = parse_enumeration(scheme, path)
    if result['enabledTests'] != [selection] or selection in result['disabledTests']:
        raise ValueError(f'Expected exactly enabled {selection}; enumeration={result!r}')
    return result


def validate_artifacts(out, phase):
    for path in expected_artifacts(out, phase):
        if not path.exists() or (path.is_file() and path.stat().st_size == 0):
            raise ValueError(f'Required result artifact missing/empty: {path}')
        if path.is_dir() and not any(path.iterdir()):
            raise ValueError(f'Required result bundle is empty: {path}')
        if path.suffix == '.zip':
            with zipfile.ZipFile(path) as archive:
                if not archive.namelist() or archive.testzip() is not None:
                    raise ValueError(f'Empty or corrupt artifact ZIP: {path}')
    for name in ('summary.json', 'tests.json'):
        json.loads((out / phase / name).read_text())


def validate_summary(path, expected):
    summary = json.loads(path.read_text())
    if expected < 1 or summary.get('result') != 'Passed':
        raise ValueError('No passing executed test suite')
    if summary.get('totalTestCount') != expected or summary.get('passedTests') != expected:
        raise ValueError(f'Executed test count does not match required {expected}: {summary}')
    if any(summary.get(key) != 0 for key in ('failedTests', 'skippedTests', 'expectedFailures')) or summary.get('testFailures'):
        raise ValueError('Failed, skipped, expected-failure or crashed test is not a pass')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    listing = sub.add_parser('list')
    listing.add_argument('--phases', default='')
    command = sub.add_parser('command')
    command.add_argument('--out', type=Path, required=True)
    command.add_argument('--simulator', required=True)
    command.add_argument('--phase', choices=[case[0] for case in ALL_CASES], required=True)
    command.add_argument('--record', action='store_true')
    command.add_argument('argv', nargs=argparse.REMAINDER)
    enumeration = sub.add_parser('enumeration')
    enumeration.add_argument('phase', choices=[case[0] for case in ALL_CASES])
    enumeration.add_argument('path', type=Path)
    artifacts = sub.add_parser('artifacts')
    artifacts.add_argument('out', type=Path)
    artifacts.add_argument('phase', choices=[case[0] for case in ALL_CASES])
    full = sub.add_parser('full-enumeration')
    full.add_argument('scheme')
    full.add_argument('path', type=Path)
    summary = sub.add_parser('summary')
    summary.add_argument('path', type=Path)
    summary.add_argument('expected', type=int)
    args = parser.parse_args()
    if args.action == 'list':
        phases = args.phases.split(',') if args.phases else [case[0] for case in CASES]
        if len(set(phases)) != len(phases) or any(phase not in [case[0] for case in ALL_CASES] for phase in phases):
            raise ValueError('Requested focused phases must be unique known phase names')
        for case in (case for case in ALL_CASES if case[0] in phases):
            print('\t'.join(case))
    elif args.action == 'command':
        argv = args.argv[1:] if args.argv[:1] == ['--'] else args.argv
        validate_command(args.out, args.simulator, args.phase, argv, record=args.record)
    elif args.action == 'enumeration':
        print(json.dumps(validate_enumeration(args.phase, args.path), indent=2))
    elif args.action == 'artifacts':
        validate_artifacts(args.out, args.phase)
    elif args.action == 'full-enumeration':
        result = parse_enumeration(args.scheme, args.path)
        if not result['enabledTests'] or result['disabledTests']:
            raise ValueError('Full regression requires every enumerated test enabled')
        print(len(result['enabledTests']))
    elif args.action == 'summary':
        validate_summary(args.path, args.expected)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, ET.ParseError, StopIteration, zipfile.BadZipFile) as error:
        print(f'Focused command validation failed: {error}', file=sys.stderr)
        sys.exit(1)
