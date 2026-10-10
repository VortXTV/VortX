#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
receipt_test_dir=$(mktemp -d "$PWD/app/build/native-addon-error-receipts.XXXXXX")
receipt_source_ref=${1:-working-tree}
printf 'Native addon receipt source %s\nRetained synthetic output %s\n' "$receipt_source_ref" "$receipt_test_dir"
for receipt_source in VortxResourceBridge VortxResourceProjection VortxNativeRuntime VortxNativeSession CoreBridge; do
    if [[ "$receipt_source_ref" == working-tree ]]; then
        cp "app/SourcesShared/$receipt_source.swift" "$receipt_test_dir/$receipt_source.swift"
    else
        git show "$receipt_source_ref:app/SourcesShared/$receipt_source.swift" > "$receipt_test_dir/$receipt_source.swift"
    fi
done
# Mechanically extract the actual enum/formatter and ownership/loading methods. Surrounding
# account storage, the lease, transport, and diagnostic sink are inert fixture types only.
awk '/^enum VortxNativeError:/ {emit=1} /^\/\/\/ Every handle call/ {emit=0} emit {print}' \
    "$receipt_test_dir/VortxNativeRuntime.swift" > "$receipt_test_dir/ActualError.swift"
awk '/^    private static func describeResourceError\(/ {emit=1} /^    \/\/\/ Cache of the addon/ {emit=0} emit {print}' \
    "$receipt_test_dir/CoreBridge.swift" > "$receipt_test_dir/ActualFormatter.swift"
awk '/^    private func invalidateScreens\(/ {emit=1} /^    func invalidateResources\(/ {emit=0}
    /^    private func begin\(/ {emit=1} /^    \/\/\/ One screen operation/ {emit=0}
    /^    func loadMeta\(/ {emit=1} /^    \/\/\/ Independent, non-UI metadata lookup/ {emit=0}
    emit {print}' \
    "$receipt_test_dir/VortxNativeSession.swift" > "$receipt_test_dir/ActualSession.swift"
awk -v directory="$receipt_test_dir" '
    /\/\/ INSERT_ACTUAL_ERROR/ {while ((getline line < (directory "/ActualError.swift")) > 0) print line; next}
    /\/\/ INSERT_ACTUAL_FORMATTER/ {while ((getline line < (directory "/ActualFormatter.swift")) > 0) print line; next}
    /\/\/ INSERT_ACTUAL_SESSION/ {while ((getline line < (directory "/ActualSession.swift")) > 0) print line; next}
    {print}' app/Tests/NativeAddonErrorReceiptTests.swift > "$receipt_test_dir/CompiledTests.swift"
xcrun swiftc -swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    "$receipt_test_dir/VortxResourceBridge.swift" "$receipt_test_dir/VortxResourceProjection.swift" \
    "$receipt_test_dir/CompiledTests.swift" -o "$receipt_test_dir/native-addon-error-receipts"
set +e
"$receipt_test_dir/native-addon-error-receipts" 2>&1 | tee "$receipt_test_dir/test.log"
receipt_test_status=${PIPESTATUS[0]}
set -e
shasum -a 256 "$receipt_test_dir/VortxResourceBridge.swift" "$receipt_test_dir/VortxResourceProjection.swift" \
    "$receipt_test_dir/VortxNativeSession.swift" "$receipt_test_dir/CoreBridge.swift" "$receipt_test_dir/test.log" \
    "$receipt_test_dir/ActualError.swift" "$receipt_test_dir/ActualFormatter.swift" "$receipt_test_dir/ActualSession.swift" \
    "$receipt_test_dir/CompiledTests.swift" "$receipt_test_dir/native-addon-error-receipts" \
    app/Tests/NativeAddonErrorReceiptTests.swift scripts/test-native-addon-error-receipts.sh
exit "$receipt_test_status"
