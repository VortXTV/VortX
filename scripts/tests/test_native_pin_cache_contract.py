"""Source-only pin/cache gate; never fetches private code or builds an SDK.

Negative fixtures mutate workflow text in memory. The Android release contract owns
the reviewed SHA; every checkout and post-checkout assertion must agree with it.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ("release-tvos.yml", "android.yml", "android-release.yml")
SHA_PATTERN = r"[0-9a-f]{40}"


def step(text, name):
    sections = re.split(r"^      - name: ", text, flags=re.MULTILINE)
    matches = [part.split("\n", 1)[1] for part in sections[1:]
               if part.split("\n", 1)[0] == name]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one workflow step: {name}")
    return matches[0]


def validate(workflows, reviewed_sha):
    if not re.fullmatch(SHA_PATTERN, reviewed_sha):
        raise ValueError("reviewed SHA must be immutable")
    for name in WORKFLOWS:
        text = workflows[name]
        fetch = step(text, "Fetch vortx-core (private monorepo, pinned)")
        refs = re.findall(r"^          ref: (\S+)$", fetch, re.MULTILINE)
        if refs != [reviewed_sha] or "repository: VortXTV/vortx-core" not in fetch:
            raise ValueError(f"{name}: checkout pin differs from reviewed SHA")
        apple = name == "release-tvos.yml"
        promotion = step(text, "Promote the vortx-core engine workspace + verify both engines (fail closed)"
                         if apple else "Promote the vortx-core workspace + record exact private source pins")
        check_pattern = (r'\[ "\$NATIVE_REVISION" = (' + SHA_PATTERN + r') \]'
                         if apple else r'test "\$vortx_sha" = "(' + SHA_PATTERN + r')"')
        if re.findall(check_pattern, promotion) != [reviewed_sha]:
            raise ValueError(f"{name}: post-checkout equality differs from reviewed SHA")

    apple = workflows["release-tvos.yml"]
    cache = step(apple, "Cache vortx-ffi xcframework")
    keys = re.findall(r"^          key: (.+)$", cache, re.MULTILINE)
    if len(keys) != 1 or not keys[0].startswith("vortx-ffi-resource-host-v1-"):
        raise ValueError("Apple native cache key is missing or ambiguous")
    for source in ("vortx-core/Cargo.toml", "vortx-core/Cargo.lock",
                   "vortx-core/rust-toolchain.toml", "vortx-core/.cargo/**",
                   "vortx-core/crates/**", "scripts/build-ffi-xcframework.sh",
                   "scripts/verify-native-engine-abi.sh"):
        if f"'{source}'" not in keys[0]:
            raise ValueError(f"Apple native cache omits {source}")
    if "hashFiles(" not in keys[0] or "steps.toolchain.outputs.xcode_version" not in keys[0]:
        raise ValueError("Apple native cache omits source/toolchain identity")
    if re.search(r"^\s*restore-keys:", cache, re.MULTILINE):
        raise ValueError("Apple native SDK must not use broad cache fallback")
    if "run: ./scripts/build-ffi-xcframework.sh --resource-host" not in step(apple, "Build the vortx-ffi xcframework"):
        raise ValueError("Apple native SDK resource-host feature changed")
    abi = step(apple, "Verify complete native engine ABI")
    if "run: ./scripts/verify-native-engine-abi.sh apple app/Vendor/VortxEngine.xcframework resource-host" not in abi:
        raise ValueError("Apple native ABI gate changed")
    if re.search(r"^\s*if:", abi, re.MULTILINE):
        raise ValueError("Apple native ABI must be verified on warm cache hits too")


class NativePinCacheContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = {name: (ROOT / ".github/workflows" / name).read_text() for name in WORKFLOWS}
        contract = (ROOT / "scripts/test-android-native-release-contracts.sh").read_text()
        matches = re.findall(r"^readonly REVIEWED_NATIVE_SHA='(" + SHA_PATTERN + r")'$", contract, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("expected exactly one reviewed native SHA in release contract")
        cls.reviewed_sha = matches[0]
        cls.wrong_sha = "0" * 40 if matches[0] != "0" * 40 else "1" * 40

    def test_current_workflows(self):
        validate(self.workflows, self.reviewed_sha)

    def test_every_checkout_pin_is_enforced(self):
        for name in WORKFLOWS:
            with self.subTest(workflow=name):
                changed = dict(self.workflows)
                changed[name] = changed[name].replace(f"ref: {self.reviewed_sha}", f"ref: {self.wrong_sha}")
                with self.assertRaisesRegex(ValueError, "checkout pin"):
                    validate(changed, self.reviewed_sha)

    def test_every_post_checkout_assertion_is_enforced(self):
        for name in WORKFLOWS:
            with self.subTest(workflow=name):
                changed = dict(self.workflows)
                # Leave only the checkout ref correct, isolating a stale post-checkout assertion.
                changed[name] = changed[name].replace(self.reviewed_sha, self.wrong_sha).replace(
                    f"ref: {self.wrong_sha}", f"ref: {self.reviewed_sha}")
                with self.assertRaisesRegex(ValueError, "post-checkout equality"):
                    validate(changed, self.reviewed_sha)

    def test_every_apple_cache_input_is_required(self):
        for source in ("vortx-core/.cargo/**", "vortx-core/crates/**",
                       "scripts/build-ffi-xcframework.sh", "scripts/verify-native-engine-abi.sh"):
            with self.subTest(source=source):
                changed = dict(self.workflows)
                changed["release-tvos.yml"] = changed["release-tvos.yml"].replace(f"'{source}', ", "").replace(f", '{source}'", "")
                with self.assertRaisesRegex(ValueError, "cache omits"):
                    validate(changed, self.reviewed_sha)

    def test_apple_broad_cache_fallback_is_rejected(self):
        changed = dict(self.workflows)
        changed["release-tvos.yml"] = changed["release-tvos.yml"].replace(
            "          key: vortx-ffi-resource-host-v1-", "          restore-keys: vortx-ffi-\n          key: vortx-ffi-resource-host-v1-")
        with self.assertRaisesRegex(ValueError, "broad cache fallback"):
            validate(changed, self.reviewed_sha)

    def test_apple_features_cannot_silently_shrink(self):
        changed = dict(self.workflows)
        changed["release-tvos.yml"] = changed["release-tvos.yml"].replace(
            "run: ./scripts/build-ffi-xcframework.sh --resource-host", "run: ./scripts/build-ffi-xcframework.sh --state-bridge")
        with self.assertRaisesRegex(ValueError, "resource-host feature"):
            validate(changed, self.reviewed_sha)

    def test_warm_cache_still_requires_abi_verification(self):
        changed = dict(self.workflows)
        changed["release-tvos.yml"] = changed["release-tvos.yml"].replace(
            "      - name: Verify complete native engine ABI\n",
            "      - name: Verify complete native engine ABI\n        if: steps.cache-ffi-xcframework.outputs.cache-hit != 'true'\n")
        with self.assertRaisesRegex(ValueError, "warm cache"):
            validate(changed, self.reviewed_sha)


if __name__ == "__main__":
    unittest.main()
