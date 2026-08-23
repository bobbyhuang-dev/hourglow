import Foundation

// 验证靶子：给定坐标、日期、时区，打印日出日落的 ISO8601 UTC 时刻。
// 由 Tests/verify-solar.py 拿去和 NOAA 参考数据对拍。
// 用法: solarcheck <纬度> <经度> <YYYY-MM-DD> <时区标识>

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 4,
      let latitude = Double(args[0]),
      let longitude = Double(args[1]),
      let zone = TimeZone(identifier: args[3]) else {
    FileHandle.standardError.write(Data("用法: solarcheck <lat> <lon> <YYYY-MM-DD> <tz>\n".utf8))
    exit(2)
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = zone

let dayFormat = DateFormatter()
dayFormat.dateFormat = "yyyy-MM-dd"
dayFormat.timeZone = zone
guard let day = dayFormat.date(from: args[2]) else {
    FileHandle.standardError.write(Data("日期格式应为 YYYY-MM-DD\n".utf8))
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
