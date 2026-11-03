import Foundation

// Standalone harness for SourceTitleMatch (#172). It reads the fixtures the Android twin also runs, so both
// platforms score every case the same way:
//   swiftc -strict-concurrency=complete -warnings-as-errors app/SourcesShared/SourceTitleMatch.swift \
//     app/Tests/SourceTitleMatchTests.swift -o build/source-title-match
//   build/source-title-match test/fixtures/source-title-match.json

private struct Fixture: Decodable {
    struct Case: Decodable {
        let `case`: String
        let title: String
        let year: Int?
        let season: Int?
        let episode: Int?
        let texts: [String]
        let expected: Int?
    }
    struct PassCase: Decodable {
        let `case`: String
        let title: String
        let year: Int?
        let season: Int?
        let episode: Int?
        let texts: [String]
        let threshold: Int
        let expected: Bool
    }
    let schemaVersion: Int
    let scores: [Case]
    let passes: [PassCase]
}

@main
enum SourceTitleMatchTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ what: String) {
        checks += 1
        if condition {
            print("  ok    \(what)")
        } else {
            failures += 1
            print("  FAIL  \(what)")
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: source-title-match <fixtures.json>")
            exit(2)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        check(fixture.schemaVersion == 1, "fixtures are the schema this harness reads")

        print("scores")
        for item in fixture.scores {
            let target = SourceTitleMatch.Target(title: item.title, year: item.year, season: item.season, episode: item.episode)
            let score = SourceTitleMatch.score(texts: item.texts, target: target)
            check(score == item.expected, "\(item.case) (\(score.map(String.init) ?? "nil"), expected \(item.expected.map(String.init) ?? "nil"))")
        }

        print("passes")
        for item in fixture.passes {
            let target = SourceTitleMatch.Target(title: item.title, year: item.year, season: item.season, episode: item.episode)
            check(SourceTitleMatch.passes(texts: item.texts, target: target, threshold: item.threshold) == item.expected, item.case)
        }

        print("thresholds")
        check(SourceTitleMatch.thresholds == [0, 50, 70, 90], "the setting offers off, 50, 70 and 90 percent")
        check(SourceTitleMatch.normalized("  Léon: The Professional (1994) ") == "leon the professional 1994",
              "normalisation folds accents and collapses punctuation")
        check(SourceTitleMatch.admittedThreshold(70) == 70 && SourceTitleMatch.admittedThreshold(65) == nil
              && SourceTitleMatch.admittedThreshold(nil) == nil,
              "only an offered threshold is admitted from storage or sync")

        for unknown in [true, false, 70.5, "70", NSNumber(value: Double.infinity), 65, 4294967366 as Int64] as [Any] {
            check(SourceTitleMatch.admittedThreshold(unknown) == nil, "unoffered or coerced raw threshold is ignored: \(unknown)")
        }
        check(SourceTitleMatch.admittedThreshold(NSNumber(value: 70.0)) == 70,
              "an exact integral JSON number remains an offered threshold")

        print("release year")
        check(SourceTitleMatch.year(from: "2021") == 2021, "a plain year")
        check(SourceTitleMatch.year(from: "2019-2023") == 2019, "the first year of a range")
        check(SourceTitleMatch.year(from: "2019–") == 2019, "an open range")
        check(SourceTitleMatch.year(from: "123456") == nil, "a longer number is not a year")
        check(SourceTitleMatch.year(from: "1850") == nil && SourceTitleMatch.year(from: nil) == nil,
              "an implausible or absent year is none")

        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
        print("OK")
    }
}
