#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"
mkdir -p app/build
fixture_build="$(mktemp -d "$repository_root/app/build/addon-failure-presentation.XXXXXX")"
export SWIFT_MAXIMUM_CONCURRENT_TASKS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
fixture_sdk="$(xcrun --sdk macosx --show-sdk-path)"
fixture_compiler="$(xcrun --find swiftc)"
fixture_arch="$(uname -m)"
case "$fixture_arch" in arm64|x86_64) ;; *) echo "Unsupported host architecture" >&2; exit 1 ;; esac
fixture_target="$fixture_arch-apple-macosx14.0"
python3 - "$repository_root" "$fixture_build" "$fixture_sdk" "$fixture_compiler" "$fixture_target" <<'PYCODE'
from pathlib import Path
import hashlib, json, sys
root, output = map(Path, sys.argv[1:3])
path = root / 'app/SourcesShared/CoreBridge.swift'
raw = path.read_bytes()
source = raw.decode('utf-8')
def line(marker):
    matches = [row for row in source.splitlines(keepends=True) if row.startswith(marker)]
    if len(matches) != 1:
        raise SystemExit('Expected one exact presentation constant: ' + marker)
    return matches[0]
start = '    private static func addonMutationFailureMessage(publicationCurrent:'
end = '\n    /// Add-on operations have local tombstone side effects, so they require the same immutable\n'
if source.count(start) != 1 or source.count(end) != 1:
    raise SystemExit('Presentation extraction anchors are not unique')
selected = source[source.index(start):source.index(end)]
if not selected.endswith('    }\n') or not selected.startswith(start):
    raise SystemExit('Presentation extraction boundary changed')
# Exact source body, zero replacements. Only the declared test wrapper is synthetic.
generated = 'import Foundation\n\nenum CoreBridge {\n'
generated += line('    private static let accountTransitionMessage = ')
generated += line('    private static let profileUnavailableMessage = ')
generated += selected
generated += """
    static func present(publicationCurrent: Bool, operationCredentialCurrent: Bool,
                        installedCredentialCurrent: Bool?, logoutPending: Bool,
                        nativeAvailable: Bool) -> String {
        addonMutationFailureMessage(publicationCurrent: publicationCurrent,
            operationCredentialCurrent: operationCredentialCurrent,
            installedCredentialCurrent: installedCredentialCurrent,
            logoutPending: logoutPending, nativeAvailable: nativeAvailable)
    }
}
"""
result = output / 'ActualAddonMutationFailurePresentation.swift'
result.write_text(generated)
fixture = root / 'app/Tests/AddonMutationFailurePresentationTests.swift'
sdk_settings = Path(sys.argv[3]) / 'SDKSettings.json'
receipt = {'selection': 'Exact production constants and static presentation declaration; zero body rewrites',
           'source': str(path), 'sourceSHA256': hashlib.sha256(raw).hexdigest(),
           'fixtureSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
           'generatedSHA256': hashlib.sha256(result.read_bytes()).hexdigest(),
           'sdkPath': sys.argv[3], 'compilerPath': sys.argv[4], 'target': sys.argv[5],
           'sdkSettingsSHA256': hashlib.sha256(sdk_settings.read_bytes()).hexdigest(),
           'productionDeclarationSHA256': hashlib.sha256(selected.encode()).hexdigest(),
           'nativeRuntime': False, 'credentialRuntime': False}
(output / 'inputs.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('Retained fixture inputs: ' + str(output / 'inputs.json'))
PYCODE
nice -n 15 "$fixture_compiler" -sdk "$fixture_sdk" -target "$fixture_target" -module-cache-path "$fixture_build/module-cache" -parse-as-library -swift-version 6 -strict-concurrency=complete   -warnings-as-errors -j 1 -num-threads 1   "$fixture_build/ActualAddonMutationFailurePresentation.swift"   app/Tests/AddonMutationFailurePresentationTests.swift -o "$fixture_build/presentation"
nice -n 15 "$fixture_build/presentation"
