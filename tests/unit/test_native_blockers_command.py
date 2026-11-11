"""Exercise exact command generation and real shell pipeline capture locally."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
BASH = (r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash'))
SPEC = importlib.util.spec_from_file_location('native_command_contract', ROOT / 'scripts/validate-native-blockers-command.py')
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)
SIMULATOR = '11111111-2222-3333-4444-555555555555'


@unittest.skipUnless(BASH and Path(BASH).is_file(), 'Bash is required')
class NativeCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ilampa command space ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.out = self.root / 'build/native-blockers'
        self.out.mkdir(parents=True)

    def shell(self, body):
        script = self.root / 'probe.sh'
        script.write_text('set -Eeuo pipefail\nsource ' + shlex.quote((ROOT / 'scripts/native-blockers-command.sh').as_posix()) + '\n' + body, newline='\n')
        return subprocess.run([BASH, script.as_posix()], cwd=self.root, capture_output=True, text=True, timeout=20)

    def test_all_eight_shell_commands_equal_independent_contract_with_spaces(self):
        for phase, scheme, selection in CONTRACT.ALL_CASES:
            with self.subTest(phase=phase):
                result = self.shell(f'OUT={shlex.quote(self.out.as_posix())}\nSIMULATOR_ID={SIMULATOR}\n'
                                    f'native_blockers_command {phase} {scheme} {selection}\n'
                                    'printf "%s\\0" "${XCODEBUILD_COMMAND[@]}"\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.rstrip('\0').split('\0'), CONTRACT.expected_command(self.out, SIMULATOR, phase))

    def test_exit_codes_survive_tee_with_err_trap_enabled(self):
        for code in (0, 1, 64, 65):
            with self.subTest(code=code):
                result = self.shell(f'OUT={shlex.quote(self.out.as_posix())}\n'
                                    'trap \'echo unexpected-ERR-handler >&2\' ERR\n'
                                    f'native_blockers_capture "$OUT/output.log" bash -c \'echo command-output; exit {code}\'\n'
                                    'printf "%s %s" "$XCODEBUILD_STATUS" "$TEE_STATUS" > "$OUT/status"\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('unexpected-ERR-handler', result.stderr)
                self.assertEqual((self.out / 'status').read_text(), f'{code} 0')
                self.assertIn('command-output', (self.out / 'output.log').read_text())

    def test_tee_failure_is_preserved_separately_from_command_failure(self):
        fake_bin = self.root / 'bin'
        fake_bin.mkdir()
        tee = fake_bin / 'tee'
        tee.write_text('#!/bin/bash\ncat >/dev/null\nexit 74\n', newline='\n')
        tee.chmod(0o755)
        result = self.shell(f'OUT={shlex.quote(self.out.as_posix())}\n'
                            'export PATH="$PWD/bin:$PATH"\n'
                            'native_blockers_capture "$OUT/output.log" bash -c \'echo failure-output; exit 65\'\n'
                            'printf "%s %s" "$XCODEBUILD_STATUS" "$TEE_STATUS" > "$OUT/status"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.out / 'status').read_text(), '65 74')

    def test_enumeration_may_leave_simulator_booted_or_shutdown(self):
        for state in ('Booted', 'Shutdown', 'Booting'):
            with self.subTest(state=state):
                calls = self.root / 'shutdown-calls'
                if calls.exists(): calls.unlink()
                payload = json.dumps({'devices': {'runtime': [{'udid': SIMULATOR, 'state': state}]}})
                result = self.shell(
                    f'SIMULATOR_ID={SIMULATOR}\n'
                    f'python3() {{ {shlex.quote(Path(sys.executable).as_posix())} "$@"; }}\n'
                    'xcrun() {\n'
                    f'  if [ "$2" = list ]; then printf "%s" {shlex.quote(payload)};\n'
                    '  else echo shutdown >> shutdown-calls; fi\n}\n'
                    'native_blockers_shutdown\n')
                if state == 'Booting':
                    self.assertNotEqual(result.returncode, 0)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls.exists(), state == 'Booted')


class CommandValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ilampa-validator-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.previous)
        self.out = self.root / 'build/native-blockers'
        self.out.mkdir(parents=True)
        schemes = self.root / 'iLampa.xcodeproj/xcshareddata/xcschemes'
        schemes.mkdir(parents=True)
        for scheme, target in [('AVPlayerControl', 'AVPlayerControlTests'), ('iLampa', 'iLampaRuntimeTests')]:
            (schemes / f'{scheme}.xcscheme').write_text(
                f'<Scheme><TestAction><Testables><TestableReference skipped="NO">'
                f'<BuildableReference BlueprintName="{target}"/></TestableReference>'
                '</Testables></TestAction></Scheme>')
        self.phase = 'control-caf'
        (self.out / self.phase).mkdir()
        self.command = CONTRACT.expected_command(self.out, SIMULATOR, self.phase)

    def validate(self, command=None, record=True):
        CONTRACT.validate_command(self.out, SIMULATOR, self.phase, self.command if command is None else command, record)

    def test_exact_command_is_recorded_and_rechecked_byte_for_byte(self):
        self.validate()
        self.validate(record=False)
        saved = json.loads((self.out / f'{self.phase}.command.json').read_text())
        self.assertEqual(saved['argv'], self.command)
        self.assertEqual(len(saved['expectedArtifacts']), 8)

    def test_unapproved_arguments_are_rejected(self):
        mutations = [self.command + ['-test-iterations', '1'],
                     self.command + ['-retry-tests-on-failure'], self.command + ['-skip-testing:SomeTest'],
                     self.command + ['-only-testing:iLampaRuntimeTests'],
                     ['xcodebuild', 'archive'] + self.command[2:]]
        for command in mutations:
            with self.subTest(command=command):
                with self.assertRaises(ValueError): self.validate(command)

    def test_wrong_destination_or_output_is_rejected(self):
        for option, replacement in [('-destination', 'generic/platform=iOS'), ('-resultBundlePath', '/unrelated/Result.xcresult'),
                                    ('-configuration', 'Release'), ('-scheme', 'OtherScheme')]:
            command = list(self.command)
            command[command.index(option) + 1] = replacement
            with self.subTest(option=option):
                with self.assertRaises(ValueError): self.validate(command)

    def test_existing_artifact_cannot_be_overwritten(self):
        (self.out / f'{self.phase}.log').write_text('previous evidence')
        with self.assertRaises(ValueError): self.validate()

    def test_changed_command_manifest_cannot_be_executed(self):
        self.validate()
        path = self.out / f'{self.phase}.command.json'
        manifest = json.loads(path.read_text())
        manifest['selection'] = 'OtherTest'
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): self.validate(record=False)

    def test_disabled_generated_scheme_target_is_rejected(self):
        path = self.root / 'iLampa.xcodeproj/xcshareddata/xcschemes/AVPlayerControl.xcscheme'
        path.write_text(path.read_text().replace('skipped="NO"', 'skipped="YES"'))
        with self.assertRaises(ValueError): self.validate()

    def test_scheme_repetition_is_rejected(self):
        path = self.root / 'iLampa.xcodeproj/xcshareddata/xcschemes/AVPlayerControl.xcscheme'
        path.write_text(path.read_text().replace('<TestAction>', '<TestAction testRepetitionMode="retryOnFailure">'))
        with self.assertRaises(ValueError): self.validate()

    def test_exactly_one_matching_native_enumerated_test_is_required(self):
        path = self.root / 'enumerated.txt'
        selection = CONTRACT.CASES[0][2]
        path.write_text(selection + '()\n')
        CONTRACT.validate_enumeration(self.phase, path)
        for value in ('', 'WrongTest/Class/method\n', selection + '\n' + selection + '\n'):
            path.write_text(value)
            with self.subTest(value=value):
                with self.assertRaises(ValueError): CONTRACT.validate_enumeration(self.phase, path)

    def test_actual_retained_xcode_26_6_enumeration(self):
        fixture = ROOT / 'tests/fixtures/native-blockers-control-caf-enumeration.txt'
        result = CONTRACT.validate_enumeration(self.phase, fixture)
        self.assertEqual(result['enabledTests'], [CONTRACT.CASES[0][2]])
        self.assertEqual(result['disabledTests'], [CONTRACT.CASES[1][2]])
        retained = ROOT / 'build/native-blockers-authorized-5b66179/analysis/workflow-logs/build/native-blockers/control-caf.enumeration.log'
        if retained.exists():
            self.assertEqual(fixture.read_text().splitlines(), retained.read_text().splitlines())
            self.assertEqual(CONTRACT.validate_enumeration(self.phase, retained), result)

    def test_disabled_required_test_and_all_ambiguous_formats_are_rejected(self):
        path = self.root / 'enumerated.txt'
        requested, sibling = CONTRACT.CASES[0][2], CONTRACT.CASES[1][2]
        cases = [f'Plan AVPlayerControl\n{requested}() (disabled)\n',
                 f'Plan AVPlayerControl\n{sibling}()\n',
                 f'Plan AVPlayerControl\n{requested}()\n{sibling}()\n',
                 f'Plan WrongPlan\n{requested}()\n',
                 f'Plan AVPlayerControl\nPlan AVPlayerControl\n{requested}()\n',
                 f'{requested}()\n{requested}() (disabled)\n',
                 f'{requested}()\nnot a valid test\n',
                 f'{requested}() (unknown-status)\n',
                 f'{requested}() (disabled) trailing-garbage\n', 'Plan\n', '{}\n']
        for value in cases:
            with self.subTest(value=value):
                path.write_text(value)
                with self.assertRaises(ValueError): CONTRACT.validate_enumeration(self.phase, path)

    def test_required_artifacts_and_valid_zips_are_mandatory(self):
        with self.assertRaises(ValueError): CONTRACT.validate_artifacts(self.out, self.phase)
        for path in CONTRACT.expected_artifacts(self.out, self.phase):
            if path.suffix == '.xcresult':
                path.mkdir()
                (path / 'Info.plist').write_text('result metadata')
            elif path.suffix == '.zip':
                with zipfile.ZipFile(path, 'w') as archive: archive.writestr('evidence', 'raw evidence')
            elif path.suffix == '.json': path.write_text('{}')
            else: path.write_text('0\n')
        CONTRACT.validate_artifacts(self.out, self.phase)
        (self.out / f'{self.phase}.xcresult.zip').write_bytes(b'not a zip')
        with self.assertRaises(zipfile.BadZipFile): CONTRACT.validate_artifacts(self.out, self.phase)

    def test_zero_tests_skips_failures_and_crashes_can_never_pass(self):
        path = self.root / 'summary.json'
        good = {'result': 'Passed', 'totalTestCount': 1, 'passedTests': 1,
                'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0, 'testFailures': []}
        path.write_text(json.dumps(good))
        CONTRACT.validate_summary(path, 1)
        variants = [dict(good, totalTestCount=0, passedTests=0), dict(good, totalTestCount=0),
                    dict(good, result='unknown'), dict(good, skippedTests=1),
                    dict(good, failedTests=1), dict(good, expectedFailures=1),
                    dict(good, testFailures=[{'failureText': 'Host crashed'}])]
        for value in variants:
            path.write_text(json.dumps(value))
            with self.subTest(value=value):
                with self.assertRaises(ValueError): CONTRACT.validate_summary(path, 1)
        path.write_text(json.dumps(good))
        with self.assertRaises(ValueError): CONTRACT.validate_summary(path, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
