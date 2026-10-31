#!/usr/bin/env python3
"""Staged macOS SDK source checks; temporary Git/Bash fixtures, no native build tools."""
from pathlib import Path
import tempfile
import re
import subprocess
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
BUILDER = (SCRIPTS / "build-ffi-xcframework.sh").read_text()
ARTIFACT = (SCRIPTS / "verify-apple-engine-artifacts.sh").read_text()
ABI = (SCRIPTS / "verify-native-engine-abi.sh").read_text()


class StagedMacOSSourceContract(unittest.TestCase):
    def _git_fixture(self, root: Path, prefix: str = "") -> Path:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.email", "fixture@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.name", "Fixture"], check=True)
        workspace = root / prefix if prefix else root
        files = {
            "Cargo.toml": "[workspace]\n",
            "Cargo.lock": "version = 4\n",
            "crates/ffi/Cargo.toml": "[package]\nname = \"vortx-ffi\"\nversion = \"0.0.0\"\n",
            "crates/ffi/include/vortx_ffi.h": "/* synthetic fixture */\n",
        }
        for rel, body in files.items():
            path = workspace / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        return workspace

    def _run_workspace_guard(self, workspace: Path) -> subprocess.CompletedProcess[str]:
        start = BUILDER.index("    # BEGIN staged engine workspace guard")
        end = BUILDER.index("    # END staged engine workspace guard", start)
        function = BUILDER[start:end].split("\n", 1)[1]
        runner = (
            'fail_staged() { echo "$*" >&2; exit 2; }\n'
            + function
            + '\nvalidate_staged_engine_workspace "$1"\n'
        )
        return subprocess.run(
            ["bash", "-c", runner, "fixture", str(workspace.resolve())],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_git_root_and_tracked_vortx_core_child_workspaces(self):
        with tempfile.TemporaryDirectory() as temp:
            parent = Path(temp) / "root-workspace"
            parent.mkdir()
            root_workspace = self._git_fixture(parent)
            subprocess.run(["git", "-C", str(parent), "add", "."], check=True)
            subprocess.run(["git", "-C", str(parent), "commit", "-qm", "fixture"], check=True)
            self.assertEqual(self._run_workspace_guard(root_workspace).returncode, 0)

            nested_repo = Path(temp) / "nested-worktree"
            nested_repo.mkdir()
            nested_workspace = self._git_fixture(nested_repo, "vortx-core")
            subprocess.run(["git", "-C", str(nested_repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(nested_repo), "commit", "-qm", "fixture"], check=True)
            self.assertEqual(self._run_workspace_guard(nested_workspace).returncode, 0)

    def test_rejects_arbitrary_or_ignored_nested_workspace_substitution(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / "fixture-repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "fixture@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Fixture"], check=True)
            (repo / ".gitignore").write_text("vortx-core/\nother/\n")
            subprocess.run(["git", "-C", str(repo), "add", ".gitignore"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)
            ignored_workspace = self._git_fixture(repo, "vortx-core")
            self.assertNotEqual(self._run_workspace_guard(ignored_workspace).returncode, 0)

            arbitrary_workspace = self._git_fixture(repo, "other")
            self.assertNotEqual(self._run_workspace_guard(arbitrary_workspace).returncode, 0)

    def test_default_five_slice_route_is_retained(self):
        for triple in (
            "aarch64-apple-ios ", "aarch64-apple-ios-sim ",
            "aarch64-apple-tvos ", "aarch64-apple-tvos-sim ",
            "aarch64-apple-darwin ",
        ):
            self.assertEqual(len(re.findall(rf"^build_slice {re.escape(triple)}", BUILDER, re.M)), 1)
            self.assertEqual(len(re.findall(rf"^localize {re.escape(triple)}", BUILDER, re.M)), 1)
        self.assertIn('OUT="$REPO_ROOT/app/Vendor/VortxEngine.xcframework"', BUILDER)
        self.assertIn('RETAINED_FFI="$REPO_ROOT/app/Vendor/engine-prelocalize/VortxEngine"', BUILDER)
        staged_branch = BUILDER.index('if [ "$STAGED_MACOS" = 1 ]; then\n    # This opt-in')
        self.assertLess(staged_branch, BUILDER.index("build_slice aarch64-apple-ios "))

    def test_required_inputs_and_preflight_precede_toolchain(self):
        for token in (
            "--resource-host", "--staged-macos-arm64", "--staged-output-root=",
            "--staged-prelocalize-root=", "--staged-target-dir=", "--engine-revision=",
            "--abi-review-report=", "RECOVERY_PHYSICAL",
            '[[ -n "${VORTX_ENGINE_DIR:-}" ]]', "destination must be fresh and absent",
            "destination parents may not traverse symlinks", "VORTX_ENGINE_DIR",
            "ENGINE_DEFAULT_TARGET", "ENGINE_DEFAULT_PRELOCALIZE",
            'mkdir -m 700 "$STAGED_PRELOCALIZE_ROOT"',
            'mkdir -m 700 "$STAGED_TARGET_DIR"',
            'git -C "$ENGINE_PHYSICAL" status --porcelain --untracked-files=all',
        ):
            self.assertIn(token, BUILDER)
        self.assertLess(BUILDER.index("destination must be fresh and absent"), BUILDER.index('source "$REPO_ROOT/scripts/native-rust-toolchain-env.sh"'))
        self.assertLess(BUILDER.index("destination must be fresh and absent"), BUILDER.index("rustup +nightly-2026-07-19 target add"))

    def test_staged_only_options_without_mode_fail_before_resolver(self):
        builder_path = str(SCRIPTS / "build-ffi-xcframework.sh")
        staged_only = (
            "--staged-output-root=/unused-output",
            "--staged-prelocalize-root=/unused-prelocalize",
            "--staged-target-dir=/unused-target",
            "--engine-revision=" + "a" * 40,
            "--abi-review-report=/unused-review",
        )
        for option in staged_only:
            completed = subprocess.run(
                ["bash", builder_path, option],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 2, option)
            self.assertIn("staged-only arguments require --staged-macos-arm64", completed.stderr)
            self.assertNotIn("engine workspace:", completed.stdout + completed.stderr)
            self.assertNotIn("native-rust-toolchain-env.sh", completed.stdout + completed.stderr)

    def test_staged_command_is_single_offline_macos_slice_and_owns_target_dir(self):
        self.assertIn('export CARGO_TARGET_DIR="$STAGED_TARGET_DIR"', BUILDER)
        self.assertIn("CARGO_NET_OFFLINE=true CARGO_BUILD_JOBS=1", BUILDER)
        self.assertIn("build --locked --offline -j 1 $BUILDSTD", BUILDER)
        self.assertIn("--target aarch64-apple-darwin", BUILDER)
        staged_start = BUILDER.index('if [ "$STAGED_MACOS" = 1 ]; then\n    # This opt-in')
        staged_end = BUILDER.index("\n# What each slice carries in THIS mode")
        staged = BUILDER[staged_start:staged_end]
        self.assertNotIn("target add", staged)
        self.assertNotIn("iphoneos", staged)
        self.assertNotIn("appletvos", staged)
        self.assertEqual(len(re.findall(r"cargo \+nightly-2026-07-19 build", staged)), 1)
        self.assertEqual(len(re.findall(r"--target aarch64-apple-darwin", staged)), 1)
        self.assertIn("$STAGED_PRELOCALIZE_ROOT/VortxEngine", BUILDER)
        self.assertIn("$STAGED_OUT_ROOT/VortxEngine.xcframework", BUILDER)

    def test_staged_artifact_verifier_has_exact_one_slice_mode(self):
        self.assertIn('"--staged-macos-arm64"', ARTIFACT)
        self.assertIn("AvailableLibraries", ARTIFACT)
        self.assertIn('lib.get("LibraryIdentifier")=="macos-arm64"', ARTIFACT)
        self.assertIn('find "$FFI_XC" -type f -name \'*.a\' | wc -l', ARTIFACT)
        self.assertIn('find "$PRELOC" -type f -name \'*.a\' | wc -l', ARTIFACT)
        self.assertIn("inspect_archive \"$a\"", ARTIFACT)
        self.assertIn("lipo -verify_arch arm64", ARTIFACT)
        self.assertIn(
            """else
  NATIVE_SLICES='ios-arm64 aarch64-apple-ios
ios-arm64-simulator aarch64-apple-ios-sim
tvos-arm64 aarch64-apple-tvos
tvos-arm64-simulator aarch64-apple-tvos-sim
macos-arm64 aarch64-apple-darwin'
fi
while IFS=' ' read -r slice triple; do
  [ -n \"$slice\" ] || continue
  [ -s \"$FFI_XC/$slice/libvortx_ffi.a\" ] || die \"missing or empty native slice $slice\"
  if [ \"$STAGED_MACOS\" = 1 ]; then retained=\"$PRELOC/VortxEngine/$triple/libvortx_ffi.a\"; else retained=\"$PRELOC/VortxEngine/$triple/libvortx_ffi.a\"; fi
  [ -s \"$retained\" ] || die \"missing or empty retained native input $triple\"""",
            ARTIFACT,
        )
        self.assertIn('done <<< "$NATIVE_SLICES"', ARTIFACT)

    def test_staged_abi_verifier_is_explicit_and_keeps_full_apple_gate(self):
        self.assertIn('platform" == apple-macos-arm64-staged', ABI)
        self.assertIn('mode" == resource-host', ABI)
        self.assertIn('count" == 1', ABI)
        self.assertIn('count" == 5', ABI)
        self.assertIn('unexpected public native exports', ABI)
        self.assertIn("vortx_resource_host_abi_version", ABI)

    def test_receipt_binds_source_and_output_identity_without_env_dump(self):
        for field in (
            '"engineRevision"', '"engineClean"', '"headerSha256"',
            '"cargoLockSha256"', '"builderSha256"', '"sdkVersion"',
            '"resolverSha256"', '"toolchainEnvSha256"',
            '"artifactVerifierSha256"', '"abiVerifierSha256"', '"abiReviewReceiptSha256"',
            '"rustToolchain"', '"xcframeworkArchiveSha256"',
            '"xcframeworkInfoPlistSha256"', '"prelocalizeArchiveSha256"',
        ):
            self.assertIn(field, BUILDER)
        self.assertNotIn('"environment"', BUILDER)
        self.assertIn("Cargo.lock changed during build", BUILDER)
        self.assertIn("FFI header changed during build", BUILDER)
        self.assertIn('root.parent/"BUILD-RECEIPT.json"', BUILDER)


if __name__ == "__main__":
    unittest.main()
