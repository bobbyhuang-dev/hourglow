import Foundation

// Verification target: print sunrise and sunset as ISO8601 UTC times for given coordinates, date, and time zone.
// Tests/verify-solar.py compares this output against NOAA reference data.
// Usage: solarcheck <latitude> <longitude> <YYYY-MM-DD> <time-zone-identifier>

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 4,
      let latitude = Double(args[0]),
      let longitude = Double(args[1]),
      let zone = TimeZone(identifier: args[3]) else {
    FileHandle.standardError.write(Data("Usage: solarcheck <lat> <lon> <YYYY-MM-DD> <tz>\n".utf8))
    exit(2)
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = zone

let dayFormat = DateFormatter()
dayFormat.dateFormat = "yyyy-MM-dd"
dayFormat.timeZone = zone
guard let day = dayFormat.date(from: args[2]) else {
    FileHandle.standardError.write(Data("Date format must be YYYY-MM-DD\n".utf8))
    exit(2)
}

guard let times = Solar.times(on: day,
                              at: Coordinate(latitude: latitude, longitude: longitude),
                              calendar: calendar) else {
    print("POLAR")
    exit(0)
}

let iso = ISO8601DateFormatter()
iso.timeZone = TimeZone(identifier: "UTC")
print(iso.string(from: times.sunrise))
print(iso.string(from: times.sunset))
