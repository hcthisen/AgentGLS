import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "operator_chat.py"


class OperatorChatTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        (self.root / "state" / "telegram").mkdir(parents=True, exist_ok=True)
        (self.root / "scripts").mkdir(parents=True, exist_ok=True)
        (self.root / ".env").write_text("", encoding="utf-8")
        self.original_root = os.environ.get("AGENTGLS_DIR")
        os.environ["AGENTGLS_DIR"] = str(self.root)

        spec = importlib.util.spec_from_file_location("operator_chat_test", MODULE_PATH)
        self.module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(self.module)

    def tearDown(self):
        if self.original_root is None:
            os.environ.pop("AGENTGLS_DIR", None)
        else:
            os.environ["AGENTGLS_DIR"] = self.original_root
        self.temp_dir.cleanup()

    def test_append_and_read_dashboard_messages_preserves_visibility(self):
        telegram_message = self.module.append_message(
            "telegram_user",
            "How are the goals coming along?",
            display_name="Telegram User",
            chat_id="123",
        )
        dashboard_message = self.module.append_message(
            "dashboard_user",
            "Do not mirror this prompt",
            display_name="Dashboard Operator",
        )
        assistant_message = self.module.append_message("assistant", "Current status is draft.", display_name="AgentGLS")

        transcript = self.module.read_dashboard_messages(10)

        self.assertEqual([entry["id"] for entry in transcript], [
            telegram_message["id"],
            dashboard_message["id"],
            assistant_message["id"],
        ])
        self.assertTrue(transcript[0]["visible_in_telegram"])
        self.assertFalse(transcript[1]["visible_in_telegram"])
        self.assertEqual(transcript[2]["role"], "assistant")

    def test_goal_status_prompt_hint_is_added_for_dashboard_chat(self):
        envelope = self.module.build_prompt_envelope(
            "dashboard",
            "How are the goals coming along right now?",
            {"display_name": "Dashboard Operator"},
        )

        self.assertIn("This message is a live goal-status request.", envelope)
        self.assertIn("dashboard user's prompt stays in the dashboard only", envelope)
        self.assertIn("/opt/agentgls/goals/", envelope)


if __name__ == "__main__":
    unittest.main()
