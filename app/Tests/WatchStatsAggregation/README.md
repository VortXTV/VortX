# Watch Stats Swift 6 migration

This standalone package selects Swift 6 and shares the actual production source
through its source symlink. Its private ISO8601 formatters are lock-owned; parsing
retains the original fractional, plain and day-prefix fallback order.

The production file passed strict Swift 6 compilation and eight focused local
source-unit groups, including exact legacy-date and concurrent-call comparisons.
The separate hosted package validation in run39114019008 passed its twelve Swift
Testing cases at that recorded source. New source changes still require their own package run;
the standalone package result does not certify an application target.

To run the package suite when allocating a test slot:

```sh
swift test --package-path app/Tests/WatchStatsAggregation --jobs 1
```

This package's language setting does not change the Apple application targets.
Their migration and application/device verification are separate requirements.
