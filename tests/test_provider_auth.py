import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "provider-auth.py"
SPEC = importlib.util.spec_from_file_location("provider_auth", MODULE_PATH)
provider_auth = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(provider_auth)


class ProviderAuthTests(unittest.TestCase):
    def test_extracts_codex_device_code_from_multiline_prompt(self):
        sample = """
Welcome to Codex [v0.118.0]
OpenAI's command-line coding agent

Follow these steps to sign in with ChatGPT using device code authorization:

1. Open this link in your browser and sign in to your account
   https://auth.openai.com/codex/device

2. Enter this one-time code (expires in 15 minutes)
   619H-RR4LV

Device codes are a common phishing target. Never share this code.
""".strip()

        self.assertEqual(provider_auth.extract_codex_user_code(sample), "619H-RR4LV")

    def test_extracts_claude_callback_parts(self):
        payload = provider_auth.parse_claude_callback(
            "https://platform.claude.com/oauth/code/callback?code=abc123&state=xyz789"
        )

        self.assertEqual(payload, {"code": "abc123", "state": "xyz789"})


if __name__ == "__main__":
    unittest.main()
