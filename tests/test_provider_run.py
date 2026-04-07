import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class ProviderRunSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.scripts_dir = self.root / "scripts"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.scripts_dir.mkdir(parents=True, exist_ok=True)
        self.provider_log = self.root / "provider.log"
        self.install_script("provider-run.sh")
        self.install_script("provider-lib.sh")
        self.provider_run_bash = self.to_bash_path(self.scripts_dir / "provider-run.sh")
        self.root_bash = self.to_bash_path(self.root)
        self.bin_dir_bash = self.to_bash_path(self.bin_dir)
        self.provider_log_bash = self.to_bash_path(self.provider_log)

    def tearDown(self):
        self.temp_dir.cleanup()

    def install_script(self, name: str):
        source = REPO_ROOT / "scripts" / name
        destination = self.scripts_dir / name
        content = source.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
        with destination.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        destination.chmod(0o755)

    def to_bash_path(self, path: Path) -> str:
        if os.name != "nt":
            return str(path)
        raw = str(path).replace("\\", "/")
        drive, tail = os.path.splitdrive(raw)
        if drive:
            return f"/mnt/{drive[0].lower()}{tail}"
        return raw

    def write_runtime_env(self, provider: str):
        with (self.root / ".env").open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(f"AGENTGLS_PROVIDER={provider}\n")

    def write_prompt(self, text: str) -> Path:
        prompt = self.root / f"{text.replace(' ', '_')}.prompt"
        prompt.write_text(text, encoding="utf-8")
        return prompt

    def write_fake_codex(self):
        script = """#!/bin/bash
set -euo pipefail
printf 'cwd=%s args=%s\\n' "$PWD" "$*" >> "$FAKE_PROVIDER_LOG"
if [[ "$1" == "exec" && "${2:-}" == "resume" && "${3:-}" == "--last" ]]; then
  printf 'resume:%s\\n' "${4:-}"
else
  printf 'first:%s\\n' "${@: -1}"
fi
"""
        path = self.bin_dir / "codex"
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(script)
        path.chmod(0o755)

    def write_fake_claude(self):
        script = """#!/bin/bash
set -euo pipefail
printf 'cwd=%s args=%s\\n' "$PWD" "$*" >> "$FAKE_PROVIDER_LOG"
if [[ "$1" == "-c" && "$2" == "-p" ]]; then
  printf 'resume:%s\\n' "${3:-}"
else
  printf 'first:%s\\n' "${2:-}"
fi
"""
        path = self.bin_dir / "claude"
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(script)
        path.chmod(0o755)

    def run_provider(self, channel: str, prompt_path: Path):
        command = (
            f"export AGENTOS_DIR={shlex.quote(self.root_bash)}; "
            f"export FAKE_PROVIDER_LOG={shlex.quote(self.provider_log_bash)}; "
            f"export PATH={shlex.quote(self.bin_dir_bash)}:\"$PATH\"; "
            f"bash {shlex.quote(self.provider_run_bash)} "
            f"{shlex.quote(channel)} "
            f"{shlex.quote(self.to_bash_path(prompt_path))}"
        )
        return subprocess.run(
            ["bash", "-lc", command],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_codex_first_run_resume_and_channel_isolation(self):
        if not shutil.which("bash"):
            self.skipTest("bash is required for provider-run smoke tests")

        self.write_runtime_env("codex")
        self.write_fake_codex()

        first_prompt = self.write_prompt("first prompt")
        second_prompt = self.write_prompt("second prompt")
        third_prompt = self.write_prompt("third prompt")

        first = self.run_provider("human", first_prompt)
        second = self.run_provider("human", second_prompt)
        third = self.run_provider("summary", third_prompt)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("first:first prompt", first.stdout)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("resume:second prompt", second.stdout)
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertIn("first:third prompt", third.stdout)

        log_text = self.provider_log.read_text(encoding="utf-8")
        self.assertIn(self.to_bash_path(self.root / "runtime" / "human"), log_text)
        self.assertIn(self.to_bash_path(self.root / "runtime" / "summary"), log_text)

    def test_claude_first_run_then_resume(self):
        if not shutil.which("bash"):
            self.skipTest("bash is required for provider-run smoke tests")

        self.write_runtime_env("claude")
        self.write_fake_claude()

        first_prompt = self.write_prompt("hello")
        second_prompt = self.write_prompt("again")

        first = self.run_provider("human", first_prompt)
        second = self.run_provider("human", second_prompt)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("first:hello", first.stdout)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("resume:again", second.stdout)


if __name__ == "__main__":
    unittest.main()
