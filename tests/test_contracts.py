import json
import subprocess
import sys
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
EXPECTED = {
    "init.yml", "node-build.yml", "python-build.yml", "golang-build.yml",
    "java-build.yml", "docker.yml", "chart.yml", "terraform-lint.yml",
    "terraform-test.yml", "scan.yml", "secret-scanning.yml", "sbom.yml",
    "deploy-argocd-gitops.yml", "mono.yml", "release.yml",
}


class WorkflowContracts(unittest.TestCase):
    def load(self, path: Path):
        data = yaml.safe_load(path.read_text())
        self.assertIsInstance(data, dict, path)
        return data

    def test_every_workflow_is_valid_yaml(self):
        files = sorted(WORKFLOWS.glob("*.yml"))
        self.assertTrue(files)
        for path in files:
            with self.subTest(path=path.name):
                self.load(path)

    def test_expected_capabilities_exist(self):
        self.assertFalse(EXPECTED - {p.name for p in WORKFLOWS.glob("*.yml")})

    def test_reusable_workflows_declare_workflow_call(self):
        for path in WORKFLOWS.glob("*.yml"):
            if path.name in {"ci.yml", "cd.yml"}:
                continue
            data = self.load(path)
            triggers = data.get("on", data.get(True, {}))
            with self.subTest(path=path.name):
                self.assertIn("workflow_call", triggers)
                self.assertIsInstance(data.get("jobs"), dict)
                self.assertTrue(data["jobs"])

    def test_release_version_is_exact(self):
        self.assertEqual("1.0.0", (ROOT / "VERSION").read_text().strip())
        text = (ROOT / "README.md").read_text()
        self.assertNotIn("@3.0.0", text)
        self.assertIn("grootan-devops/github-ci-library", text)

    def test_consumer_fixture_covers_supported_shapes(self):
        fixture = yaml.safe_load((ROOT / "tests/fixtures/consumer.yml").read_text())
        uses = json.dumps(fixture)
        for workflow in EXPECTED:
            self.assertIn(workflow, uses)

    def test_shared_structural_verifier(self):
        verifier = ROOT.parent / "ai-skills/ci-library-builder/scripts/verify-github-library.py"
        if not verifier.exists():
            self.skipTest("sibling ai-skills checkout is not available")
        result = subprocess.run(
            [sys.executable, str(verifier), str(ROOT), "--json"],
            text=True, capture_output=True,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
