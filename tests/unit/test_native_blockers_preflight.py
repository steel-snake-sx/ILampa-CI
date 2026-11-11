"""Local runner-contract tests; fake macOS tools never execute native tests/CI."""
import os
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash"))


@unittest.skipUnless(BASH and Path(BASH).is_file(), "Bash is required")
class NativeBlockersPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ilampa-preflight-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "scripts").mkdir()
        (self.repo / "iLampa").mkdir()
        (self.repo / "mock-bin").mkdir()
        for name in ("native-blockers-ci.sh", "native-blockers-command.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.repo / "scripts")
        shutil.copy2(ROOT / "iLampa/Info.plist", self.repo / "iLampa")
        (self.repo / ".gitignore").write_text("build/\nmock-bin/\ncommands.log\n")
        self.git("init", "--quiet")
        self.git("config", "user.name", "Local preflight test")
        self.git("config", "user.email", "preflight@example.invalid")
        self.git("config", "core.autocrlf", "false")
        # Do not inherit the working repository's private commit hooks.
        self.git("config", "core.hooksPath", str(self.repo / "unused-hooks"))
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Local fixture only")
        self.sha = self.git("rev-parse", "HEAD").strip()
        self.mock("brew", 'echo "brew $*" >> commands.log\nexit "${MOCK_BREW_STATUS:-0}"\n')
        self.mock("xcodegen", '''
echo "xcodegen $*" >> commands.log
if [ "$1" = --version ]; then
  echo "Version: ${MOCK_XCODEGEN_VERSION:-2.46.0}"
elif [ "$1" = generate ]; then
  if [ "${MOCK_GENERATE_FAIL:-NO}" = YES ]; then exit 41; fi
  if [ "${MOCK_GENERATE_DIRTY:-NO}" = YES ]; then
    echo '<!-- generated mutation -->' >> iLampa/Info.plist
  fi
fi
''')
        self.mock("xcodebuild", '''
echo "xcodebuild $*" >> commands.log
if [ "$1" = -version ]; then printf 'Xcode 26.6\\nBuild version mock\\n'; exit 0; fi
echo 'ERROR: local contract test must never execute native tests' >&2
exit 99
''')
        self.mock("xcrun", 'echo "xcrun $*" >> commands.log\nexit 0\n')
        self.mock("sw_vers", 'echo "mock macOS inventory"\n')
        # A deliberate sentinel failure bounds the exercise before Simulator setup.
        self.mock("system_profiler", 'echo "preflight-boundary" >> commands.log\nexit 73\n')
        self.out = self.repo / "build/native-blockers"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True, stderr=subprocess.STDOUT)

    def mock(self, name, body):
        path = self.repo / "mock-bin" / name
        path.write_text("#!/bin/bash\n" + body, encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def run_runner(self, **overrides):
        environment = os.environ.copy()
        environment.update(ILAMPA_APPROVED_SOURCE_COMMIT=self.sha, ILAMPA_NATIVE_BLOCKERS_AUTHORIZED="YES")
        for key, value in overrides.items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             'export PATH="$PWD/mock-bin:$PATH"\nexec bash scripts/native-blockers-ci.sh'],
            cwd=self.repo, env=environment, text=True, capture_output=True, timeout=30)
        commands = (self.repo / "commands.log").read_text() if (self.repo / "commands.log").exists() else ""
        self.assertNotIn("xcodebuild test", commands)
        self.assertNotIn("simctl create", commands)
        return result, commands

    def assert_stage_failure(self, result, stage, status=1):
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        self.assertIn("stage=" + stage, (self.out / "preflight.log").read_text())
        self.assertEqual((self.out / "runner-exit-status.log").read_text().strip(), str(status))

    def test_missing_authorization_is_logged_before_tool_install(self):
        result, commands = self.run_runner(ILAMPA_APPROVED_SOURCE_COMMIT=None)
        self.assert_stage_failure(result, "authorization")
        self.assertEqual(commands, "")

    def test_denied_authorization_is_fatal(self):
        result, commands = self.run_runner(ILAMPA_NATIVE_BLOCKERS_AUTHORIZED="NO")
        self.assert_stage_failure(result, "authorization")
        self.assertEqual(commands, "")
        self.assertIn("line=", (self.out / "preflight.log").read_text())

    def test_wrong_commit_is_fatal(self):
        result, commands = self.run_runner(ILAMPA_APPROVED_SOURCE_COMMIT="0" * 40)
        self.assert_stage_failure(result, "authorization")
        self.assertEqual(commands, "")

    def test_short_commit_is_not_accepted_as_exact_authorization(self):
        result, commands = self.run_runner(ILAMPA_APPROVED_SOURCE_COMMIT=self.sha[:7])
        self.assert_stage_failure(result, "authorization")
        self.assertEqual(commands, "")

    def test_installer_failure_is_retained_without_generation(self):
        result, commands = self.run_runner(MOCK_BREW_STATUS="42")
        self.assert_stage_failure(result, "install-xcodegen", status=42)
        self.assertTrue((self.out / "xcodegen-install.log").exists())
        self.assertNotIn("xcodegen", commands.replace("brew install xcodegen", ""))

    def test_dirty_source_stops_before_generation_and_retains_diff(self):
        with (self.repo / "iLampa/Info.plist").open("a") as stream:
            stream.write("<!-- dirty before generation -->\n")
        result, commands = self.run_runner()
        self.assert_stage_failure(result, "before-generation")
        self.assertEqual(commands, "")
        self.assertIn("dirty before generation", (self.out / "before-generation-diff.log").read_text())

    def test_unapproved_generator_version_stops_before_generation(self):
        result, commands = self.run_runner(MOCK_XCODEGEN_VERSION="99.0.0")
        self.assert_stage_failure(result, "xcodegen-version")
        self.assertNotIn("xcodegen generate", commands)

    def test_generator_error_is_fatal_and_logged(self):
        result, commands = self.run_runner(MOCK_GENERATE_FAIL="YES")
        self.assert_stage_failure(result, "generate-project", status=41)
        self.assertIn("xcodegen generate", commands)
        self.assertTrue((self.out / "xcodegen-generate.log").exists())
        self.assertNotIn("xcodebuild", commands)

    def test_generated_tracked_mutation_is_still_fatal(self):
        result, commands = self.run_runner(MOCK_GENERATE_DIRTY="YES")
        self.assert_stage_failure(result, "after-generation")
        self.assertIn("generated mutation", (self.out / "after-generation-diff.log").read_text())
        self.assertNotIn("xcodebuild", commands)

    def test_clean_generation_reaches_inventory_boundary_without_native_execution(self):
        result, commands = self.run_runner()
        self.assert_stage_failure(result, "environment", status=73)
        self.assertIn("preflight-boundary", commands)
        self.assertEqual((self.out / "before-generation-status.log").read_text(), "")
        self.assertEqual((self.out / "after-generation-status.log").read_text(), "")
        self.assertLess(commands.index("xcodegen --version"), commands.index("xcodegen generate"))
        self.assertLess(commands.index("xcodegen generate"), commands.index("xcodebuild -version"))

    def test_existing_evidence_is_not_overwritten(self):
        self.out.mkdir(parents=True)
        evidence = self.out / "preflight.log"
        evidence.write_text("previous evidence\n")
        result, commands = self.run_runner()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(evidence.read_text(), "previous evidence\n")
        self.assertFalse((self.out / "runner-exit-status.log").exists())
        self.assertEqual(commands, "")


class NativeBlockersConfigurationTests(unittest.TestCase):
    def test_generated_region_explicitly_matches_tracked_plist(self):
        info = plistlib.loads((ROOT / "iLampa/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleDevelopmentRegion"], "ru")
        spec = (ROOT / "project.yml").read_text()
        self.assertIn('      properties:\n        CFBundleDevelopmentRegion: "ru"\n', spec)

    def test_workflow_only_enters_the_guarded_runner(self):
        workflow = (ROOT / "codemagic.yaml").read_text().split("  ilampa-native-blockers:", 1)[1].split("  ilampa-concurrency-tests:", 1)[0]
        self.assertNotIn("xcodegen generate", workflow)
        self.assertNotIn("brew install", workflow)
        self.assertEqual(workflow.count("bash scripts/native-blockers-ci.sh"), 1)
        self.assertIn("build/native-blockers/*.log", workflow)

    def test_eight_focused_selections_and_strict_pass_gate_are_preserved(self):
        runner = (ROOT / "scripts/native-blockers-ci.sh").read_text()
        spec = importlib.util.spec_from_file_location("command_contract", ROOT / "scripts/validate-native-blockers-command.py")
        contract = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(contract)
        selections = [list(case) for case in contract.CASES]
        self.assertEqual(selections, [
            ["control-caf", "AVPlayerControl", "AVPlayerControlTests/PlayerStateIntegrationTests/testIndependentAVAudioFileAndAVPlayer"],
            ["control-wav", "AVPlayerControl", "AVPlayerControlTests/PlayerStateIntegrationTests/testLocalPlayerAdvancesPausesSeeksAndResumes"],
            ["hosted-caf", "iLampa", "iLampaRuntimeTests/PlayerStateIntegrationTests/testIndependentAVAudioFileAndAVPlayer"],
            ["hosted-wav", "iLampa", "iLampaRuntimeTests/PlayerStateIntegrationTests/testLocalPlayerAdvancesPausesSeeksAndResumes"],
            ["production-local", "iLampa", "iLampaRuntimeTests/PlayerStateIntegrationTests/testProductionStartupWithControlAsset"],
            ["held-progress", "iLampa", "iLampaRuntimeTests/PlaybackConcurrencyTests/testHeldProgressCallbackCannotReportTimeAgainstReplacementItem"],
            ["settings-ui", "iLampa", "iLampaUITests/iLampaUITests/testLegacySettingsAppearInProductionPluginDetail"],
            ["production-hls-ui", "iLampa", "iLampaUITests/iLampaUITests/testPlayerSeekingPauseResumeAndReopen"],
        ])
        command = (ROOT / "scripts/native-blockers-command.sh").read_text()
        self.assertNotIn("-test-iterations", runner + command)
        self.assertNotIn("-retry-tests-on-failure", runner + command)
        self.assertNotIn("-skip-testing", runner + command)
        self.assertIn("-enumerate-tests", runner)
        self.assertIn('done < "$OUT/command-plan.log"', runner)
        self.assertIn('validate-native-blockers-command.py summary "$phase/summary.json" 1', runner)


if __name__ == "__main__":
    unittest.main(verbosity=2)
