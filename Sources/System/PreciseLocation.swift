import AppKit
import CoreLocation
import Foundation

/// 向系统要一次精确坐标。
///
/// 只要一次，不做持续定位：一台机器的经纬度不会自己跑，而日出日落对坐标的敏感度也就是
/// 「几十公里 ≈ 一分钟」的量级。拿到之后写进 `schedule.json` 的 `location`，之后就一直用它。
///
/// 拿不到坐标不是死路：`ApproxLocation` 会按系统时区反查一个近似坐标（免权限），
/// 用户也可以在设置页手填经纬度。三条路的优先级是 手填 > 定位写下的 > 时区推断。
///
/// 坑：
/// - `CLLocationManager` 要在有 run loop 的线程上建，回调也回到那个线程 —— 这里固定用主线程。
/// - 权限对话框只在 `.notDetermined` 时弹一次。用户拒绝之后再调 `requestWhenInUseAuthorization`
///   不会有任何反应，也不会有回调 —— 所以拒绝要当成一个明确的结局报出去，让 UI 切到手填。
/// - `requestLocation()` 有可能既不回位置也不回错误（冷启动、无 Wi-Fi 的台式机），
///   所以自己加一个超时兜底。
@MainActor
final class PreciseLocation: NSObject, CLLocationManagerDelegate {

    enum Outcome {
        case coordinate(Coordinate)
        /// 权限被拒或被管控。UI 应当把手填经纬度顶到前面。
        case denied
        case failed(String)
    }

    static let shared = PreciseLocation()

    private let manager = CLLocationManager()
    private var completion: ((Outcome) -> Void)?
    private var timeout: DispatchWorkItem?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // 日出日落用不着更准
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// 打开「系统设置 › 隐私与安全性 › 定位服务」。
    ///
    /// 被拒之后 `requestWhenInUseAuthorization` 不会再弹第二次框，UI 只能引导用户
    /// 自己去开 —— 既然说了在哪儿改，就得能点过去。Ventura 之后 pane 的标识变了，
    /// 旧的仍被系统映射；两条都试，谁先打得开算谁。
    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 请求一次坐标。已经在请求中时后来者直接顶掉前一个回调（面板上只有一个按钮）。
    func request(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion

        switch manager.authorizationStatus {
        case .notDetermined:
            // 授权结果走 `locationManagerDidChangeAuthorization`，那里再真正取一次位置。
            manager.requestWhenInUseAuthorization()
            arm(seconds: 60)   // 对话框要等用户点，给足时间
        case .denied, .restricted:
            finish(.denied)
        default:
            manager.requestLocation()
            arm(seconds: 20)
        }
    }

    // MARK: - 委托

    // 委托回调都回到建 manager 的那个线程 —— 这里固定是主线程。声明成 `nonisolated`
    // 是为了满足协议（它本身没有隔离），实际执行仍旧在主 actor 上，用 `assumeIsolated` 接进来，
    // 和 `Scheduler` 的回调是同一套写法。
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard completion != nil else { return }
            switch manager.authorizationStatus {
            case .notDetermined:
                break                       // 对话框还开着，等下一次回调
            case .denied, .restricted:
                finish(.denied)
            default:
                manager.requestLocation()
                arm(seconds: 20)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let last = locations.last else { return }
            finish(.coordinate(Coordinate(latitude: last.coordinate.latitude,
                                          longitude: last.coordinate.longitude)))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if (error as? CLError)?.code == .denied { finish(.denied); return }
            finish(.failed((error as NSError).localizedDescription))
        }
    }

    // MARK: - 内部

    private func arm(seconds: TimeInterval) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(.failed("定位超时")) }
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func finish(_ outcome: Outcome) {
        timeout?.cancel()
        timeout = nil
        let callback = completion
        completion = nil
        callback?(outcome)
    }
}
