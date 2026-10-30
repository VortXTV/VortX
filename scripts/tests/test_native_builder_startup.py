#!/usr/bin/env python3
"""Exercise actual builder startup prefixes; no Cargo, compiler or build code runs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE_ROOT = Path(os.environ.get("VORTX_NATIVE_STARTUP_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
SCRIPTS = {
    "build-ffi-xcframework.sh": "\nBUILDSTD=",
    "build-mac-server.sh": '\necho "Building vortx-streaming-server ',
}
SHELLS = list(dict.fromkeys(str(path) for path in (
    Path("/bin/bash"), Path("/opt/homebrew/bin/bash"),
    Path(shutil.which("bash") or "/bin/bash"),
) if path.is_file()))
MARKER = b"VORTX_NATIVE_STARTUP_COMPLETE"


class NativeBuilderStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not SHELLS:
            raise RuntimeError("No Bash available for startup verification")

    def run_prefix(self, script_name, shell, initialization, expected_exit):
        text = (SOURCE_ROOT / "scripts" / script_name).read_text()
        self.assertEqual(text.count(SCRIPTS[script_name]), 1)
        prefix = text.split(SCRIPTS[script_name], 1)[0]
        self.assertIn("set -euo pipefail", prefix)
        self.assertNotIn("2>/dev/null || true", prefix)
        # The one fixture substitution does not redefine HOME or expose actual initialization.
        # Everything else is the current builder prefix, including strict mode and resolver.
        self.assertEqual(prefix.count('"$HOME/.cargo/env"'), 2)
        prefix = prefix.replace('"$HOME/.cargo/env"', '"$VORTX_TEST_CARGO_ENV"')
        body = prefix + '\nprintf "%s\\n" VORTX_NATIVE_STARTUP_COMPLETE\n'
        self.assertNotIn("cargo build", body)
        self.assertNotIn("build_slice ", body)
        with tempfile.TemporaryDirectory(prefix="native-builder-startup-") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "resolve-native-engine.sh").write_bytes(
                (SOURCE_ROOT / "scripts" / "resolve-native-engine.sh").read_bytes())
            engine = root / "engine"
            for crate in ("ffi", "streaming-server"):
                target = engine / "crates" / crate
                target.mkdir(parents=True)
                (target / "Cargo.toml").write_text('[package]\nname="fixture"\nversion="0.0.0"\n')
            (engine / "Cargo.toml").write_text('[workspace]\n')
            initializer = root / "optional-cargo-env"
            if initialization is not None:
                initializer.write_text(initialization)
            # A present valid initializer proves its export reaches the caller after source.
            if initialization == 'export VORTX_TEST_INITIALIZED=ready\n':
                body += 'test "$VORTX_TEST_INITIALIZED" = ready\n'
            target = scripts / script_name
            target.write_text(body)
            environment = {**os.environ, "VORTX_ENGINE_DIR": str(engine),
                           "VORTX_TEST_CARGO_ENV": str(initializer)}
            environment.pop("VORTX_TEST_REQUIRED_MISSING", None)
            environment.pop("VORTX_TEST_INITIALIZED", None)
            result = subprocess.run(
                [shell, str(target), "--resource-host"] if script_name.startswith("build-ffi")
                else [shell, str(target)], cwd=root,
                env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
            )
            if expected_exit == 0:
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertIn(MARKER, result.stdout.splitlines())
                self.assertEqual(result.stderr, b"")
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(MARKER, result.stdout.splitlines())
                self.assertIn(b"VORTX_TEST_REQUIRED_MISSING", result.stderr)

    def test_missing_optional_initializer(self):
        for name in SCRIPTS:
            for shell in SHELLS:
                with self.subTest(script=name, shell=shell):
                    self.run_prefix(name, shell, None, 0)

    def test_present_valid_initializer(self):
        for name in SCRIPTS:
            for shell in SHELLS:
                with self.subTest(script=name, shell=shell):
                    self.run_prefix(name, shell, 'export VORTX_TEST_INITIALIZED=ready\n', 0)

    def test_present_broken_initializer_keeps_strict_failure_and_diagnostic(self):
        for name in SCRIPTS:
            for shell in SHELLS:
                with self.subTest(script=name, shell=shell):
                    self.run_prefix(name, shell, 'printf "%s\\n" "$VORTX_TEST_REQUIRED_MISSING"\n', 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
