import Foundation

/// 一个可选的地点：展示名 + 搜索用的别名 + 坐标。
struct City: Equatable, Identifiable, Hashable {
    var name: String
    var detail: String
    var coordinate: Coordinate
    var keys: [String]
    var id: String { "\(name)|\(coordinate.latitude)|\(coordinate.longitude)" }

    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let q = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return keys.contains { key in
            key.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(q)
        }
    }

    var asCoordinate: Coordinate {
        var c = coordinate
        c.name = name
        return c
    }

    /// 离线表里中国城市的 `detail` 是省 / 直辖市 / 特别行政区。
    /// 用来把地点页拆成「中国 / 海外」两段，空搜时不混成一长串。
    var isChina: Bool { Self.chineseRegions.contains(detail) }

    private static let chineseRegions: Set<String> = [
        "北京", "上海", "天津", "重庆",
        "河北", "山西", "辽宁", "吉林", "黑龙江",
        "江苏", "浙江", "安徽", "福建", "江西", "山东",
        "河南", "湖北", "湖南", "广东", "海南",
        "四川", "贵州", "云南", "陕西", "甘肃", "青海",
        "台湾", "内蒙古", "广西", "西藏", "宁夏", "新疆",
        "香港", "澳门",
    ]
}

/// 离线城市表：常用中文城市（含拼音）加上 `zone.tab` 里每个时区的代表点。
///
/// 中国全境都是 `Asia/Shanghai`，时区推断永远落在上海，深圳 / 张家界的日出会差
/// 十几到四十分钟。所以面板要让人自己选城市，不能只靠时区。
enum Cities {

    static func search(_ query: String) -> [City] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = q.isEmpty ? featured : catalog
        let hits = pool.filter { $0.matches(q) }
        if q.isEmpty { return hits }
        return hits.sorted { lhs, rhs in
            rank(lhs, q) < rank(rhs, q)
        }
    }

    /// 精确名或拼音对上时取第一个，其次是从头对上的（`深` → 深圳）。
    ///
    /// 不拿「随便一个子串命中」兜底：`lookup("a")` 会一路命中到 Abidjan，
    /// 用户打错一个字就被静默设到地球另一边去了。认不出就认不出，交给调用方去搜。
    static func lookup(_ query: String) -> City? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let folded = fold(q)
        let hits = search(q)
        if let exact = hits.first(where: { $0.keys.contains { fold($0) == folded } }) {
            return exact
        }
        // 单个拉丁字母做前缀兜底照样会命中到 Abidjan 去；中文单字（深 → 深圳）留着。
        guard folded.count >= 2 || !folded.allSatisfy(\.isASCII) else { return nil }
        return hits.first { $0.keys.contains { fold($0).hasPrefix(folded) } }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    static let featured: [City] = curated

    static let catalog: [City] = {
        var seen = Set<String>()
        var all: [City] = []
        for city in curated + zoneTabCities() {
            let key = String(format: "%.2f,%.2f", city.coordinate.latitude, city.coordinate.longitude)
            if seen.insert(key).inserted { all.append(city) }
        }
        return all
    }()

    private static func rank(_ city: City, _ query: String) -> (Int, String) {
        let q = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if city.name.folding(options: [.caseInsensitive], locale: .current) == q { return (0, city.name) }
        if city.keys.contains(where: {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == q
        }) { return (1, city.name) }
        if city.name.folding(options: [.caseInsensitive], locale: .current).hasPrefix(q) { return (2, city.name) }
        return (3, city.name)
    }

    // name, pinyin, english, lat, lon, region
    private static let curated: [City] = rows.map { row in
        City(name: row.0,
             detail: row.5,
             coordinate: Coordinate(latitude: row.3, longitude: row.4, name: row.0),
             keys: [row.0, row.1, row.2, row.1.replacingOccurrences(of: " ", with: "")])
    }

    private static let rows: [(String, String, String, Double, Double, String)] = [
        ("张家界", "zhangjiajie", "Zhangjiajie", 29.117, 110.479, "湖南"),
        ("深圳", "shenzhen", "Shenzhen", 22.543, 114.058, "广东"),
        ("广州", "guangzhou", "Guangzhou", 23.129, 113.264, "广东"),
        ("珠海", "zhuhai", "Zhuhai", 22.271, 113.577, "广东"),
        ("东莞", "dongguan", "Dongguan", 23.021, 113.752, "广东"),
        ("佛山", "foshan", "Foshan", 23.022, 113.121, "广东"),
        ("惠州", "huizhou", "Huizhou", 23.112, 114.416, "广东"),
        ("中山", "zhongshan", "Zhongshan", 22.517, 113.393, "广东"),
        ("汕头", "shantou", "Shantou", 23.354, 116.682, "广东"),
        ("北京", "beijing", "Beijing", 39.904, 116.407, "北京"),
        ("上海", "shanghai", "Shanghai", 31.230, 121.473, "上海"),
        ("杭州", "hangzhou", "Hangzhou", 30.274, 120.155, "浙江"),
        ("宁波", "ningbo", "Ningbo", 29.868, 121.544, "浙江"),
        ("南京", "nanjing", "Nanjing", 32.061, 118.797, "江苏"),
        ("苏州", "suzhou", "Suzhou", 31.299, 120.585, "江苏"),
        ("无锡", "wuxi", "Wuxi", 31.491, 120.312, "江苏"),
        ("合肥", "hefei", "Hefei", 31.820, 117.227, "安徽"),
        ("济南", "jinan", "Jinan", 36.651, 117.120, "山东"),
        ("青岛", "qingdao", "Qingdao", 36.067, 120.383, "山东"),
        ("天津", "tianjin", "Tianjin", 39.343, 117.361, "天津"),
        ("石家庄", "shijiazhuang", "Shijiazhuang", 38.042, 114.515, "河北"),
        ("太原", "taiyuan", "Taiyuan", 37.870, 112.549, "山西"),
        ("郑州", "zhengzhou", "Zhengzhou", 34.746, 113.625, "河南"),
        ("武汉", "wuhan", "Wuhan", 30.593, 114.305, "湖北"),
        ("长沙", "changsha", "Changsha", 28.228, 112.939, "湖南"),
        ("南昌", "nanchang", "Nanchang", 28.683, 115.858, "江西"),
        ("福州", "fuzhou", "Fuzhou", 26.074, 119.296, "福建"),
        ("厦门", "xiamen", "Xiamen", 24.480, 118.089, "福建"),
        ("成都", "chengdu", "Chengdu", 30.572, 104.066, "四川"),
        ("重庆", "chongqing", "Chongqing", 29.563, 106.552, "重庆"),
        ("昆明", "kunming", "Kunming", 25.038, 102.718, "云南"),
        ("丽江", "lijiang", "Lijiang", 26.855, 100.226, "云南"),
        ("贵阳", "guiyang", "Guiyang", 26.647, 106.630, "贵州"),
        ("南宁", "nanning", "Nanning", 22.817, 108.366, "广西"),
        ("桂林", "guilin", "Guilin", 25.274, 110.290, "广西"),
        ("海口", "haikou", "Haikou", 20.044, 110.199, "海南"),
        ("三亚", "sanya", "Sanya", 18.253, 109.512, "海南"),
        ("西安", "xian", "Xi'an", 34.341, 108.940, "陕西"),
        ("兰州", "lanzhou", "Lanzhou", 36.061, 103.834, "甘肃"),
        ("西宁", "xining", "Xining", 36.617, 101.778, "青海"),
        ("银川", "yinchuan", "Yinchuan", 38.487, 106.231, "宁夏"),
        ("乌鲁木齐", "wulumuqi", "Urumqi", 43.825, 87.617, "新疆"),
        ("拉萨", "lasa", "Lhasa", 29.650, 91.117, "西藏"),
        ("呼和浩特", "huhehaote", "Hohhot", 40.842, 111.749, "内蒙古"),
        ("沈阳", "shenyang", "Shenyang", 41.805, 123.431, "辽宁"),
        ("大连", "dalian", "Dalian", 38.914, 121.615, "辽宁"),
        ("长春", "changchun", "Changchun", 43.817, 125.324, "吉林"),
        ("哈尔滨", "haerbin", "Harbin", 45.803, 126.535, "黑龙江"),
        ("香港", "xianggang", "Hong Kong", 22.319, 114.169, "香港"),
        ("澳门", "aomen", "Macau", 22.198, 113.544, "澳门"),
        ("台北", "taibei", "Taipei", 25.033, 121.565, "台湾"),
        ("高雄", "gaoxiong", "Kaohsiung", 22.627, 120.302, "台湾"),
        ("东京", "dongjing", "Tokyo", 35.676, 139.650, "日本"),
        ("大阪", "daban", "Osaka", 34.694, 135.502, "日本"),
        ("京都", "jingdu", "Kyoto", 35.012, 135.768, "日本"),
        ("首尔", "shouer", "Seoul", 37.567, 126.978, "韩国"),
        ("新加坡", "xinjiapo", "Singapore", 1.352, 103.820, "新加坡"),
        ("曼谷", "mangu", "Bangkok", 13.756, 100.502, "泰国"),
        ("吉隆坡", "jilongpo", "Kuala Lumpur", 3.139, 101.687, "马来西亚"),
        ("雅加达", "yajiada", "Jakarta", -6.208, 106.846, "印度尼西亚"),
        ("马尼拉", "manila", "Manila", 14.599, 120.984, "菲律宾"),
        ("胡志明市", "huzhiming", "Ho Chi Minh City", 10.823, 106.630, "越南"),
        ("悉尼", "xini", "Sydney", -33.869, 151.209, "澳大利亚"),
        ("墨尔本", "moerben", "Melbourne", -37.814, 144.963, "澳大利亚"),
        ("奥克兰", "aokelan", "Auckland", -36.849, 174.763, "新西兰"),
        ("伦敦", "lundun", "London", 51.507, -0.128, "英国"),
        ("巴黎", "bali", "Paris", 48.857, 2.352, "法国"),
        ("柏林", "bolin", "Berlin", 52.520, 13.405, "德国"),
        ("阿姆斯特丹", "amusi", "Amsterdam", 52.368, 4.904, "荷兰"),
        ("罗马", "luoma", "Rome", 41.903, 12.496, "意大利"),
        ("马德里", "madeli", "Madrid", 40.417, -3.704, "西班牙"),
        ("巴塞罗那", "basailuona", "Barcelona", 41.387, 2.168, "西班牙"),
        ("苏黎世", "sulishi", "Zurich", 47.376, 8.541, "瑞士"),
        ("斯德哥尔摩", "sidegeermo", "Stockholm", 59.329, 18.069, "瑞典"),
        ("奥斯陆", "aosilu", "Oslo", 59.913, 10.752, "挪威"),
        ("哥本哈根", "gebenhagen", "Copenhagen", 55.676, 12.568, "丹麦"),
        ("赫尔辛基", "heerxinj", "Helsinki", 60.170, 24.938, "芬兰"),
        ("维也纳", "weiyena", "Vienna", 48.208, 16.374, "奥地利"),
        ("布拉格", "bulage", "Prague", 50.075, 14.438, "捷克"),
        ("华沙", "huasha", "Warsaw", 52.230, 21.012, "波兰"),
        ("莫斯科", "mosike", "Moscow", 55.756, 37.617, "俄罗斯"),
        ("伊斯坦布尔", "yisitanbul", "Istanbul", 41.009, 28.965, "土耳其"),
        ("迪拜", "dibai", "Dubai", 25.205, 55.271, "阿联酋"),
        ("孟买", "mengmai", "Mumbai", 19.076, 72.878, "印度"),
        ("新德里", "xindeli", "New Delhi", 28.614, 77.209, "印度"),
        ("开罗", "kailuo", "Cairo", 30.044, 31.236, "埃及"),
        ("开普敦", "kaipudun", "Cape Town", -33.925, 18.424, "南非"),
        ("约翰内斯堡", "yuehanneisibao", "Johannesburg", -26.204, 28.047, "南非"),
        ("内罗毕", "neiluobi", "Nairobi", -1.292, 36.822, "肯尼亚"),
        ("纽约", "niuyue", "New York", 40.713, -74.006, "美国"),
        ("洛杉矶", "luoshanji", "Los Angeles", 34.052, -118.244, "美国"),
        ("旧金山", "jiujinshan", "San Francisco", 37.775, -122.419, "美国"),
        ("西雅图", "xiyatu", "Seattle", 47.606, -122.332, "美国"),
        ("芝加哥", "zhijiage", "Chicago", 41.878, -87.630, "美国"),
        ("波士顿", "boshidun", "Boston", 42.360, -71.059, "美国"),
        ("迈阿密", "maiami", "Miami", 25.762, -80.192, "美国"),
        ("火奴鲁鲁", "huonululu", "Honolulu", 21.307, -157.858, "美国"),
        ("多伦多", "duolunduo", "Toronto", 43.653, -79.383, "加拿大"),
        ("温哥华", "wengehua", "Vancouver", 49.282, -123.121, "加拿大"),
        ("蒙特利尔", "mengtelier", "Montreal", 45.502, -73.567, "加拿大"),
        ("墨西哥城", "moxigecheng", "Mexico City", 19.433, -99.133, "墨西哥"),
        ("圣保罗", "shengbaoluo", "São Paulo", -23.551, -46.633, "巴西"),
        ("布宜诺斯艾利斯", "buyinuosai", "Buenos Aires", -34.604, -58.382, "阿根廷"),
        ("圣地亚哥", "shengdiyage", "Santiago", -33.449, -70.669, "智利"),
        ("雷克雅未克", "leikeyawieke", "Reykjavik", 64.147, -21.943, "冰岛"),
    ]

    /// `zone.tab` 每个时区一行代表城市，补上「东京 / 伦敦」这类没单独写进中文表的点。
    static func zoneTabCities() -> [City] {
        guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab",
                                      encoding: .utf8) else { return [] }
        var cities: [City] = []
        for line in table.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let coord = ApproxLocation.parseISO6709(String(fields[1])) else { continue }
            let tz = String(fields[2])
            let english = (tz.split(separator: "/").last ?? Substring(tz))
                .replacingOccurrences(of: "_", with: " ")
            let comment = fields.count >= 4 ? String(fields[3]) : tz
            var named = coord
            named.name = english
            cities.append(City(
                name: english,
                detail: comment,
                coordinate: named,
                keys: [english, english.replacingOccurrences(of: " ", with: ""), tz, comment]
            ))
        }
        return cities
    }
}
