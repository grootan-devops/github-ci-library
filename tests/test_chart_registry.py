"""OCI workflow regression tests using command doubles; never contact a registry."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class ChartRegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        stub = '''#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(a) + '\\n')
if a[:2] == ['registry', 'login']:
    sys.stdin.read()
    if os.environ.get('LOGIN_FAIL') == 'true':
        print(os.environ['CHART_REGISTRY_PASSWORD'], file=sys.stderr)
        sys.exit(1)
elif a[:2] == ['show', 'chart']:
    state = os.environ.get('LOOKUP', 'missing')
    if state == 'present': print('name: demo\\nversion: 1.2.0-rc.1')
    else:
        print('manifest unknown: not found' if state == 'missing' else state, file=sys.stderr)
        sys.exit(1)
elif a[0] == 'pull':
    if os.environ.get('PULL_FAIL') == 'true': sys.exit(1)
    dest = pathlib.Path(a[a.index('--untardir') + 1]) / 'demo'
    dest.mkdir(parents=True, exist_ok=True)
    (dest / 'Chart.yaml').write_text('name: demo\\nversion: 1.2.0\\n')
elif a[0] == 'package':
    pathlib.Path('demo-' + a[a.index('--version') + 1] + '.tgz').touch()
elif a[0] == 'push':
    if os.environ.get('PUSH_FAIL') == 'true':
        print(os.environ['CHART_REGISTRY_PASSWORD'], file=sys.stderr)
        sys.exit(1)
    if os.environ.get('MIRROR_FAIL') == 'true' and a[-1].endswith('/dev'): sys.exit(1)
'''
        helm = self.bin / "helm"
        helm.write_text(stub)
        helm.chmod(0o755)
        (self.work / "chart").mkdir()
        (self.work / "chart/Chart.yaml").write_text("name: demo\nversion: 1.2.0\n")
        (self.work / "demo-1.2.0.tgz").touch()
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "CALLS": str(self.work / "calls.jsonl"), "GITHUB_STEP_SUMMARY": str(self.work / "summary"),
            "CHART_NAME": "demo", "CHART_VERSION": "1.2.0", "TAG": "1.2.0",
            "CHART_REGISTRY": "registry.example", "CHART_REPOSITORY": "team/helm",
            "CHART_DEV_REPOSITORY": "team/helm/dev", "DEV_REPOSITORY": "team/helm/dev",
            "PROD_REPOSITORY": "team/helm", "CANDIDATE_VERSION": "1.2.0-rc.1",
            "CHART_REGISTRY_USERNAME": "chart-user", "CHART_REGISTRY_PASSWORD": "test-chart-secret",
        }

    def run_script(self, relative, *args, **env):
        result = subprocess.run([shutil.which("bash"), str(ROOT / relative), *args],
                                cwd=self.work, env=self.env | env, text=True, capture_output=True)
        self.assertNotIn("test-chart-secret", result.stdout + result.stderr)
        return result

    def calls(self):
        p = self.work / "calls.jsonl"
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def test_publishing_requires_registry_without_image_fallback(self):
        for script in ("registry", "push", "promote"):
            result = self.run_script(f"scripts/chart/{script}.sh", CHART_REGISTRY="", IMAGE_REGISTRY="images.example")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("CHART_REGISTRY", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_login_rejects_http_and_missing_chart_credentials(self):
        for env in ({"CHART_REGISTRY": "https://registry.example"}, {"CHART_REGISTRY_PASSWORD": ""}):
            result = self.run_script("scripts/chart/registry.sh", **env)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_authentication_failure_does_not_log_secret(self):
        result = self.run_script("scripts/chart/registry.sh", LOGIN_FAIL="true")
        self.assertNotEqual(result.returncode, 0)

    def test_push_and_optional_mirror(self):
        result = self.run_script("scripts/chart/push.sh", MIRROR_FAIL="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Optional dev mirror", result.stdout)
        self.assertEqual(self.calls()[0][-1], "oci://registry.example/team/helm")

    def test_docker_hub_has_no_duplicate_mirror(self):
        result = self.run_script("scripts/chart/push.sh", CHART_REGISTRY="registry-1.docker.io",
                                 CHART_REPOSITORY="team", CHART_DEV_REPOSITORY="team")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_primary_push_failure_is_fatal(self):
        result = self.run_script("scripts/chart/push.sh", PUSH_FAIL="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_collision_and_confirmed_absence(self):
        for state, expected in (("present", 1), ("missing", 0)):
            result = self.run_script("scripts/checks/chart-version-check.sh", LOOKUP=state)
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_lookup_failure_is_not_availability_or_promotion_fallback(self):
        for error in ("401 unauthorized", "403 denied", "connection timeout", "500 server error", "x509 failure"):
            for script in ("scripts/checks/chart-version-check.sh", "scripts/chart/promote.sh"):
                result = self.run_script(script, LOOKUP=error)
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(any(c[0] in ("push", "package") for c in self.calls()))

    def test_promote_exact_candidate(self):
        result = self.run_script("scripts/chart/promote.sh", LOOKUP="present")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("working tree", result.stdout)
        self.assertEqual(self.calls()[-1][-1], "oci://registry.example/team/helm")
        self.assertIn("1.2.0-rc.1", (self.work / "CHART_INFO.md").read_text())

    def test_failed_candidate_pull_cannot_rebuild(self):
        result = self.run_script("scripts/chart/promote.sh", LOOKUP="present", PULL_FAIL="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] in ("package", "push") for c in self.calls()))

    def test_confirmed_missing_candidate_keeps_warned_local_fallback(self):
        result = self.run_script("scripts/chart/promote.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("working tree", result.stdout)

    def test_dependency_registry_is_independent(self):
        result = self.run_script("scripts/chart/registry.sh", "dependencies",
                                 CHART_DEPENDENCY_REGISTRY="deps.example",
                                 CHART_DEPENDENCY_REGISTRY_USERNAME="reader",
                                 CHART_DEPENDENCY_REGISTRY_PASSWORD="test-chart-secret")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[0][2], "deps.example")
        result = self.run_script("scripts/chart/push.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[1][-1], "oci://registry.example/team/helm")

    def test_public_dependencies_need_no_registry(self):
        result = self.run_script("scripts/chart/registry.sh", "dependencies", CHART_REGISTRY="",
                                 CHART_REGISTRY_USERNAME="", CHART_REGISTRY_PASSWORD="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_init_chart_only_and_both_artifact_validation(self):
        env = {"CHART_REGISTRY_INPUT": "registry.example", "CHART_REPOSITORY_INPUT": "team/helm",
               "IGNORE_DOCKER_INPUT": "true", "IGNORE_CHART_INPUT": "false"}
        result = self.run_script("scripts/init/validate-config.sh", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_script("scripts/init/validate-config.sh", **(env | {"CHART_REGISTRY_INPUT": ""}))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vars.CHART_REGISTRY", result.stdout)
        result = self.run_script("scripts/init/validate-config.sh", **(env | {"IGNORE_DOCKER_INPUT": "false"}))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vars.IMAGE_REGISTRY", result.stdout)

    def test_chart_scan_wires_only_chart_credentials(self):
        config = yaml.safe_load((ROOT / ".github/workflows/scan.yml").read_text())
        step = next(s for job in config["jobs"].values() for s in job.get("steps", [])
                    if s.get("name") == "Render Chart For Config Scan")
        self.assertNotIn("IMAGE_REGISTRY", json.dumps(step))
        self.assertIn("CHART_REGISTRY_PASSWORD", step["env"])
        self.assertIn("registry.sh", step["run"])


if __name__ == "__main__":
    unittest.main()
