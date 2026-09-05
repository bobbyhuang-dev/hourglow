import Foundation

// Offline benchmark; all image paths are fixtures and no wallpaper is read or written.
// swiftc -O Sources/L10n/L10n.swift Sources/L10n/Catalogs/*.swift Sources/Model/*.swift \
//   Sources/System/*.swift Tools/benchmark-resolver.swift -o build/resolverbench
// ./build/resolverbench
@main
enum ResolverBenchmark {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let coordinate = Coordinate(latitude: 22.543, longitude: 114.058)
        let date = ISO8601DateFormatter().date(from: "2026-09-04T04:00:00Z")!
        let iterations = 300
        for count in [4, 24, 120, 480] {
            let slots = (0..<count).map { index in
                Slot(trigger: .solarPhase(phase: DayPhase.allCases[index % 4],
                                          index: index / 4, count: count / 4),
                     wallpaper: .image(path: "/fixture/\(index)"))
            }
            let schedule = Schedule(slots: slots, location: coordinate)
            var checksum = 0.0
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<iterations {
                checksum += schedule.resolve(at: date, calendar: calendar)!.since.timeIntervalSince1970
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000 / Double(iterations)
            print("\(count) slots: \(elapsed) ms/resolve; checksum=\(checksum)")
        }
    }
}
