"""Execute the release workflow's actual snapshot argv on macOS Bash 3.2.

The Python command is replaced by a shell function that records arguments, so
the test never opens an SDK, server binary, provider, or release artifact.
"""

import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ".github/workflows/release-tvos.yml"
STEP = "      - name: Capture exact native SDK and player inputs before app compilation"


def snapshot_shell():
    revision = os.environ.get("VORTX_SNAPSHOT_WORKFLOW_REF")
    if revision:
        text = subprocess.check_output(
            ["git", "-C", str(ROOT), "show", f"{revision}:{WORKFLOW}"],
            text=True,
        )
    else:
        text = (ROOT / WORKFLOW).read_text()
    step = text.split(STEP + "\n", 1)[1].split("\n      - name:", 1)[0]
    body = step.split("        run: |\n", 1)[1]
    return "\n".join(line[10:] for line in body.splitlines() if line.strip())


class NativeSnapshotArgumentsTests(unittest.TestCase):
    def assert_snapshot(self, test_only, include_server):
        environment = dict(os.environ)
        environment.update(
            TVOS_TEST_ONLY=test_only,
            VORTX_ENGINE_SOURCE_REVISION="synthetic revision with spaces",
            NATIVE_PACKAGE_VERIFIER="/accepted workflow/verify-native-apple-package.py",
        )
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                "python3() { printf '%s\\0' \"$@\"; }\n" + snapshot_shell(),
            ],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        arguments = result.stdout.decode().split("\0")
        self.assertEqual(arguments.pop(), "", "argv recorder must end with NUL")
        expected = {
            "--engine": "app/Vendor/VortxEngine.xcframework",
            "--mpvkit": "app/Vendor/MPVKit-DVFEL",
            "--engine-revision": "synthetic revision with spaces",
            "--output": "out/native-build-inputs.json",
        }
        if include_server:
            expected["--mac-server"] = "app/Vendor/vortx-streaming-server"
        self.assertEqual(arguments[:2], [environment["NATIVE_PACKAGE_VERIFIER"], "snapshot"])
        remainder = arguments[2:]
        self.assertEqual(len(remainder), len(expected) * 2)
        self.assertEqual(dict(zip(remainder[::2], remainder[1::2])), expected)
        self.assertNotIn("", arguments)

    def test_artifact_only_seed_omits_mac_server(self):
        self.assert_snapshot("true", include_server=False)

    def test_full_release_retains_mac_server(self):
        self.assert_snapshot("false", include_server=True)

    def test_push_default_retains_mac_server(self):
        self.assert_snapshot("", include_server=True)


if __name__ == "__main__":
    unittest.main()
