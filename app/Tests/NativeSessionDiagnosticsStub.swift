// Standalone checkpoint/session fixtures use the production diagnostic call signature,
// with logging disabled. Never include this collaborator in an application target.
enum VXProbe {
    static func log(_ category: StaticString, _ message: @autoclosure () -> String) {}
}
