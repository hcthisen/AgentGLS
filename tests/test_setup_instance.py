import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SETUP_INSTANCE = REPO_ROOT / "scripts" / "setup-instance.py"
GOALMETA = REPO_ROOT / "scripts" / "goalmeta.py"


class SetupInstanceTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        (self.root / "scripts").mkdir(parents=True, exist_ok=True)
        shutil.copy2(GOALMETA, self.root / "scripts" / "goalmeta.py")
        (self.root / ".env").write_text("", encoding="utf-8")

    def tearDown(self):
        self.temp_dir.cleanup()

    def env(self):
        payload = os.environ.copy()
        payload["AGENTGLS_DIR"] = str(self.root)
        return payload

    def run_setup(self, action, payload=None, check=True):
        result = subprocess.run(
            [sys.executable, str(SETUP_INSTANCE), action],
            input=json.dumps(payload or {}),
            capture_output=True,
            text=True,
            env=self.env(),
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(result.stderr or result.stdout)
        return result

    def run_goalmeta(self, *args, check=True):
        result = subprocess.run(
            [sys.executable, str(self.root / "scripts" / "goalmeta.py"), *map(str, args)],
            capture_output=True,
            text=True,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(result.stderr or result.stdout)
        return result

    def test_approve_goal_marks_goal_approved_and_unblocks_manual_run(self):
        self.run_setup("create-goal", {"title": "Ship Landing Page", "summary": "Launch the site."})
        goal_path = self.root / "goals" / "active" / "ship-landing-page.md"

        self.run_goalmeta("set", goal_path, "approval_policy", "manual")
        self.run_goalmeta("set", goal_path, "approved_for_next_run", "null")
        self.run_setup("approve-goal", {"slug": "ship-landing-page"})

        self.assertEqual(self.run_goalmeta("get", goal_path, "brief_status").stdout.strip(), "approved")
        self.assertEqual(self.run_goalmeta("get", goal_path, "approved_for_next_run").stdout.strip(), "true")


if __name__ == "__main__":
    unittest.main()
