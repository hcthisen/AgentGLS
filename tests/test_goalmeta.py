import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GOALMETA = REPO_ROOT / "scripts" / "goalmeta.py"


def write_goal(path: Path, front_matter: dict, body: str) -> None:
    yaml_lines = ["---"]
    for key, value in front_matter.items():
        if value is None:
            yaml_lines.append(f"{key}: null")
        elif isinstance(value, bool):
            yaml_lines.append(f"{key}: {'true' if value else 'false'}")
        elif isinstance(value, (int, float)):
            yaml_lines.append(f"{key}: {value}")
        else:
            yaml_lines.append(f'{key}: "{value}"')
    yaml_lines.append("---")
    yaml_lines.append("")
    path.write_text("\n".join(yaml_lines) + body, encoding="utf-8")


class GoalmetaCliTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.active = self.root / "active"
        self.paused = self.root / "paused"
        self.completed = self.root / "completed"
        self.locks = self.root / "locks"
        for directory in (self.active, self.paused, self.completed, self.locks):
            directory.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_cli(self, *args, check=True):
        result = subprocess.run(
            [sys.executable, str(GOALMETA), *map(str, args)],
            capture_output=True,
            text=True,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(result.stderr or result.stdout)
        return result

    def goal_body(self):
        return (
            "## Objective\n\n"
            "Ship the deliverable.\n\n"
            "## Finish Criteria\n\n"
            "- [ ] Deliverable shipped\n"
            "- [ ] Proof captured\n\n"
            "## Scoreboard\n\n"
            "| Metric | Value | Updated |\n"
            "|--------|-------|---------|\n"
            "| Progress | 0 | - |\n\n"
            "## Run Log\n"
        )

    def base_front_matter(self, **overrides):
        front_matter = {
            "title": "Test goal",
            "priority": "medium",
            "brief_status": "approved",
            "run_state": "idle",
            "run_id": None,
            "run_started_at": None,
            "heartbeat_minutes": 60,
            "created": "2026-04-07T10:00:00Z",
            "last_run": None,
            "next_eligible_at": None,
            "measurement_due_at": None,
            "deadline_at": None,
            "approval_policy": "auto",
            "approved_for_next_run": None,
            "template": None,
            "parent": None,
            "notify_chat_id": None,
        }
        front_matter.update(overrides)
        return front_matter

    def test_claim_prefers_highest_priority_and_clears_manual_approval(self):
        draft_goal = self.active / "draft.md"
        write_goal(draft_goal, self.base_front_matter(title="Draft", brief_status="draft"), self.goal_body())

        auto_goal = self.active / "auto.md"
        write_goal(auto_goal, self.base_front_matter(title="Auto", priority="high"), self.goal_body())

        manual_goal = self.active / "manual.md"
        write_goal(
            manual_goal,
            self.base_front_matter(
                title="Manual",
                priority="critical",
                approval_policy="manual",
                approved_for_next_run=True,
            ),
            self.goal_body(),
        )

        result = self.run_cli("claim", self.active)
        payload = json.loads(result.stdout)

        self.assertEqual(payload["slug"], "manual")
        self.assertTrue(payload["run_id"])

        front_matter = {
            "run_state": self.run_cli("get", manual_goal, "run_state").stdout.strip(),
            "approved_for_next_run": self.run_cli("get", manual_goal, "approved_for_next_run").stdout.strip(),
        }
        self.assertEqual(front_matter["run_state"], "running")
        self.assertEqual(front_matter["approved_for_next_run"], "null")

    def test_claim_recovers_stale_running_goal(self):
        stale_goal = self.active / "stale.md"
        write_goal(
            stale_goal,
            self.base_front_matter(
                title="Stale",
                priority="critical",
                run_state="running",
                run_id="old-run",
                run_started_at="2026-04-07T07:00:00Z",
            ),
            self.goal_body(),
        )

        fresh_goal = self.active / "fresh.md"
        write_goal(fresh_goal, self.base_front_matter(title="Fresh", priority="medium"), self.goal_body())

        result = self.run_cli("claim", self.active)
        payload = json.loads(result.stdout)

        self.assertEqual(payload["slug"], "stale")
        self.assertNotEqual(self.run_cli("get", stale_goal, "run_id").stdout.strip(), "old-run")
        self.assertEqual(self.run_cli("get", stale_goal, "run_state").stdout.strip(), "running")

    def test_finalize_complete_and_pause_reset_state_and_move_files(self):
        running_goal = self.active / "running.md"
        write_goal(
            running_goal,
            self.base_front_matter(run_state="running", run_id="run-1", run_started_at="2026-04-07T10:00:00Z"),
            self.goal_body(),
        )

        self.run_cli("finalize", running_goal)
        self.assertEqual(self.run_cli("get", running_goal, "run_state").stdout.strip(), "idle")
        self.assertNotEqual(self.run_cli("get", running_goal, "last_run").stdout.strip(), "null")

        complete_goal = self.active / "complete.md"
        write_goal(
            complete_goal,
            self.base_front_matter(run_state="running", run_id="run-2", run_started_at="2026-04-07T10:00:00Z"),
            self.goal_body(),
        )
        self.run_cli("complete", complete_goal, self.completed)
        self.assertFalse(complete_goal.exists())
        self.assertTrue((self.completed / "complete.md").exists())

        pause_goal = self.active / "pause.md"
        write_goal(
            pause_goal,
            self.base_front_matter(run_state="running", run_id="run-3", run_started_at="2026-04-07T10:00:00Z"),
            self.goal_body(),
        )
        self.run_cli("pause", pause_goal, self.paused)
        self.assertFalse(pause_goal.exists())
        self.assertTrue((self.paused / "pause.md").exists())

    def test_reconcile_parent_updates_scoreboard_rollup(self):
        parent_goal = self.active / "parent.md"
        write_goal(parent_goal, self.base_front_matter(title="Parent"), self.goal_body())

        child_active = self.active / "child-active.md"
        write_goal(child_active, self.base_front_matter(title="Child Active", parent="parent"), self.goal_body())

        child_done = self.completed / "child-done.md"
        write_goal(child_done, self.base_front_matter(title="Child Done", parent="parent"), self.goal_body())

        self.run_cli("reconcile-parent", parent_goal, self.active)
        scoreboard = json.loads(self.run_cli("scoreboard", parent_goal).stdout)

        self.assertEqual(scoreboard["Children total"], "2")
        self.assertEqual(scoreboard["Children completed"], "1")


if __name__ == "__main__":
    unittest.main()
