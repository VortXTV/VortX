#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

baseline_ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-ref)
      [[ $# -ge 2 ]] || { echo "missing value for --baseline-ref" >&2; exit 2; }
      baseline_ref=$2
      shift 2
      ;;
    *)
      echo "usage: $0 [--baseline-ref REV]" >&2
      exit 2
      ;;
  esac
done

source_path="$repo_root/app/SourcesiOS/iOSRootView.swift"
template_path="$repo_root/app/Tests/AppleSearchSubmissionExtractionRunner.swift"
mkdir -p "$repo_root/app/build"
build_root=$(mktemp -d "$repo_root/app/build/apple-search-submission.XXXXXX")
extractor="$build_root/extractor"
receipt="$build_root/receipt.txt"

[[ -f "$source_path" ]] || { echo "missing production source: $source_path" >&2; exit 1; }
[[ -f "$template_path" ]] || { echo "missing extraction runner: $template_path" >&2; exit 1; }

# Each run gets a fresh generated directory inside the registered app build tree. Existing
# baseline/current source, binaries, logs, and receipts remain available for inspection.
{
  printf 'format\tapple-search-submission-receipt-v1\n'
  printf 'script_commit\t%s\n' "$(git rev-parse HEAD)"
  printf 'baseline_ref\t%s\n' "${baseline_ref:-none}"
} > "$receipt"

xcrun swiftc -parse-as-library -O "$repo_root/scripts/AppleSearchSubmissionExtract.swift" -o "$extractor"

run_variant() {
  local variant=$1
  local variant_source=$2
  local mode=$3
  local variant_dir="$build_root/$variant"
  mkdir -p "$variant_dir"
  "$extractor" --source "$variant_source" --template "$template_path" --output "$variant_dir/runner.swift"
  printf 'source_path\t%s\t%s\n' "$variant" "$variant_source" >> "$receipt"
  printf 'source_sha256\t%s\t%s\n' "$variant" "$(shasum -a 256 "$variant_source" | awk '{print $1}')" >> "$receipt"
  printf 'runner_sha256\t%s\t%s\n' "$variant" "$(shasum -a 256 "$variant_dir/runner.swift" | awk '{print $1}')" >> "$receipt"
  xcrun swiftc -parse-as-library -O "$variant_dir/runner.swift" -o "$variant_dir/runner"
  if [[ "$mode" == baseline ]]; then
    "$variant_dir/runner" --baseline | tee "$variant_dir/run.log"
    grep -F 'BASELINE RED dedicated one-handoff searches=2' "$variant_dir/run.log" >/dev/null
    grep -F 'BASELINE RED merged one-handoff searches=2' "$variant_dir/run.log" >/dev/null
    grep -F 'BASELINE RED burst refreshes=4 current-binding=current-query' "$variant_dir/run.log" >/dev/null
  else
    "$variant_dir/runner" | tee "$variant_dir/run.log"
    grep -F 'GREEN dedicated one-handoff searches=1' "$variant_dir/run.log" >/dev/null
    grep -F 'GREEN merged one-handoff searches=1' "$variant_dir/run.log" >/dev/null
    grep -F 'GREEN burst refreshes=1 current-binding=current-query' "$variant_dir/run.log" >/dev/null
    grep -F 'PASS actual-source Apple Search extraction' "$variant_dir/run.log" >/dev/null
  fi
  printf 'result\t%s\tPASS\n' "$variant" >> "$receipt"
}

if [[ -n "$baseline_ref" ]]; then
  baseline_source="$build_root/baseline-source.swift"
  git show "$baseline_ref:app/SourcesiOS/iOSRootView.swift" > "$baseline_source"
  run_variant baseline "$baseline_source" baseline
fi

run_variant current "$source_path" current
summary="current"
if [[ -n "$baseline_ref" ]]; then summary="$summary; baseline $baseline_ref RED proof"; fi
printf 'Apple Search extraction gate passed (%s); artifacts: %s\n' "$summary" "$build_root"
