# HourGlow — MVP 规格

> 跟着天光走的 macOS 壁纸调度器。

macOS Tahoe 提供了 Tahoe Morning / Day / Evening / Night 四张动态壁纸，
却没有像旧版 macOS 那样按时间自动切换的能力。HourGlow 补上这个缺口 ——
但不写死这四张，而是做成一个通用的「触发条件 → 壁纸」调度器。

---

## 1. 一句话定义

菜单栏常驻的小工具：你定义若干时段（固定时刻或日出日落相对时间），
每个时段绑一张壁纸（系统 aerial 或本地图片），它负责在正确的时刻切换。

**设计原则**：Tahoe 那四张只是一个内置预设，不是硬编码逻辑。
任何时段数量、任何触发方式、任何壁纸来源都应该是数据，不是代码。

---

## 2. 已验证的系统事实

这一节是实机验证过的结论，不是推测。实现时直接依赖。

### 2.1 配置文件

```
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist   # binary plist
```

写入后需要 `killall WallpaperAgent` 才生效。实测修改不会被系统改回去。

### 2.2 plist 结构

顶层四个作用域：

```
AllSpacesAndDisplays
SystemDefault
Spaces      { <space-uuid>: { Default: …, Displays: { <display-uuid>: … } } }
Displays    { <display-uuid>: … }
```

每个 slot 有 `Type` 字段，决定桌面与屏保是否联动：

| Type | 结构 |
|---|---|
| `linked` | 单个 `Linked` 键，桌面和屏保共用一个 choice |
| `individual` | `Desktop` 和 `Idle` 两个键，分别配置 |

每个 choice 形如：

```
{ Provider: <string>, Files: [], Configuration: <嵌套的 binary plist> }
```

### 2.3 两种 Provider

**动态壁纸（aerial）**
```
Provider:      com.apple.wallpaper.choice.aerials
Configuration: { assetID: "CF6347E2-4F81-4410-8892-4830991B6C5A" }
```

**静态图片**
```
Provider:      com.apple.wallpaper.choice.image
Configuration: { type: "imageFile", url: { relative: "file:///path/to.heic" } }
```

> 静态图的格式是通过调用公开 API `NSWorkspace.setDesktopImageURL` 反推出来的 ——
> 该 API 确实会写入 Index.plist，但它的读回接口 `desktopImageURL(for:)` 返回的是
> 陈旧值（实测返回 `DefaultDesktop.heic`），**不可信**。
> 另外它会把 slot 从 `linked` 强制改成 `individual`，写入时必须自己纠正回来。

### 2.4 Aerial 素材库

```
~/Library/Application Support/com.apple.wallpaper/aerials/
├── manifest/entries.json      # 156 个 asset 的完整元数据
├── thumbnails/<uuid>.png      # 156 张缩略图，全部已本地缓存
└── videos/<uuid>.mov          # 已下载的视频，每个约 430 MB
```

`entries.json` 中每个 asset 的可用字段：

```
id, accessibilityLabel, shotID, localizedNameKey,
categories[], subcategories[], preferredOrder,
previewImage, includeInShuffle, showInTopLevel, url-4K-SDR-240FPS
```

分类共 5 个：Landscapes(18 子类) / Cities(6) / Underwater(17) / Space(21) / Mac(1)。

判断某张是否已下载：检查 `videos/<id>.mov` 是否存在。
未下载的可以照常写入配置，由系统自行拉取。

### 2.5 Tahoe 四张的 assetID

| 时段 | 名称 | shotID | assetID |
|---|---|---|---|
| 晨 | Tahoe Morning | TA_L_001 | `B2FC91ED-6891-4DEB-85A1-268B2B4160B6` |
| 昼 | Tahoe Day     | TA_L_002 | `4C108785-A7BA-422E-9C79-B0129F1D5550` |
| 昏 | Tahoe Evening | TA_D_001 | `52ACB9B8-75FC-4516-BC60-4550CFF3B661` |
| 夜 | Tahoe Night   | TA_D_002 | `CF6347E2-4F81-4410-8892-4830991B6C5A` |

---

## 3. 数据模型

配置存 JSON，人类可读、可手改。

```
Schedule = [Slot]

Slot = {
  id:        UUID
  trigger:   Trigger
  wallpaper: Wallpaper
  enabled:   Bool
}

Trigger =
  | clock  { hour: Int, minute: Int }
  | solar  { event: sunrise | sunset, offsetMinutes: Int }   // offset 可负

Wallpaper =
  | aerial { assetID: String }
  | image  { path: String }
```

**求值规则**：把所有 slot 的触发时刻解析成当天的绝对时间并排序，
取「不晚于当前时刻」的最后一个；若全部都晚于当前时刻，取前一天的最后一个（跨午夜回绕）。

配置文件位置：`~/Library/Application Support/HourGlow/schedule.json`

---

## 4. P0 功能

1. **菜单栏常驻** —— `MenuBarExtra` + `.menuBarExtraStyle(.window)`，无 Dock 图标（`LSUIElement`）
2. **时间轴编辑** —— 增删时段、改触发条件、每段绑一张壁纸；数量不限
3. **壁纸选择器** —— 156 张 aerial 缩略图网格（本地缓存，秒开），按 5 个分类筛选 + 按名称搜索；
   未下载的标灰并提示体积；底部有「选择本地图片…」
4. **调度引擎** —— app 内定时器 + `NSWorkspaceDidWakeNotification` 唤醒补跑，取代现有 launchd 方案。
   定时器直接排到下一个触发点，不轮询；时钟变更、时区变更、跨日各有对应通知
5. **日出日落** —— `CLLocationManager` 取坐标后本地计算（NOAA 太阳位置算法），不联网；
   拒绝定位权限时回退为手填经纬度
6. **杂项** —— 全局暂停 / 开机自启（`SMAppService.mainApp`）

### 手动改壁纸的语义

用户随时可能自己去系统设置里换一张。实测确认：他的改动会覆盖我们写的，
我们的写入本身是持久的，系统不会改回去。所以「谁说了算」得我们自己定：

- **跨过了新的触发边界**（到点、睡过了某个触发时刻、暂停后恢复）—— 照常写。
  手动选择的有效期到下一次排定的切换为止，跟空调的「临时保持」一个意思。
- **没跨过边界的原地重新求值**（启动、唤醒、时区变更）—— 只有当前壁纸仍是
  我们上次写的那张时才写；否则让位，别把用户十分钟前的选择无声抹掉。

判据是引擎状态里的 `lastFiredAt` 与本次求值的 `since` 谁更晚。
状态存 `~/Library/Application Support/HourGlow/state.json`。

### 默认预设

首次启动写入 Tahoe 四段预设：
`日出 → Morning`、`09:00 → Day`、`日落前 30 分 → Evening`、`日落后 60 分 → Night`。
用户可任意改动或删除。

---

## 5. 非目标（留给 v2）

- 多显示器 / 多 Space 分别设置（MVP 统一写 `linked`，桌面与屏保一起换）
- 桌面与屏保拆开控制
- 随机 / 文件夹轮播
- 跟随系统亮暗模式的触发器
- 天气、地理位置、Focus 模式触发
- 锁屏壁纸
- 配置导入导出 / iCloud 同步

---

## 6. 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| 语言 / UI | Swift 6.3 + SwiftUI | 菜单栏、唤醒通知、定位、plist 全是一等公民；二进制 < 5 MB |
| 构建 | `swiftc` 直接编译 + 手工 `.app` bundle | 已验证可行，不依赖 Xcode。Xcode 可选安装 |
| 签名 | ad-hoc（`codesign -s -`） | 个人自用足够；要分发再谈公证 |
| 依赖 | 零第三方 | 太阳位置算法自己实现，约 60 行 |

**已验证**：`swiftc -O -parse-as-library main.swift -o Probe` 可编出可用的
`MenuBarExtra` 应用，产物 59 KB。

---

## 7. 模块划分

```
Sources/
├── App/
│   ├── HourGlowApp.swift    // @main，MenuBarExtra 场景
│   └── AppModel.swift       // UI 与引擎之间唯一的一层，@Observable
├── Model/
│   ├── Schedule.swift       // Slot / Trigger / Wallpaper + Codable
│   ├── Store.swift          // 读写 schedule.json
│   └── Resolver.swift       // 求值：前后各展开一天，处理跨午夜回绕
├── System/
│   ├── WallpaperWriter.swift // 写 Index.plist + killall WallpaperAgent
│   ├── AerialCatalog.swift   // 解析 entries.json，枚举缩略图与下载状态
│   ├── Location.swift        // 时区反查近似坐标（免权限的回退路径）
│   ├── PreciseLocation.swift // CoreLocation 取一次精确坐标，被拒时回退手填
│   ├── LaunchAtLogin.swift   // 开机自启（SMAppService.mainApp）
│   └── Solar.swift           // 日出日落计算
├── Engine/
│   ├── Scheduler.swift      // 定时器 + 系统事件观察 + 决定写不写
│   ├── EngineState.swift    // state.json：我们上次写的是哪张
│   ├── ConfigWatcher.swift  // schedule.json 被手改后立刻跟上
│   ├── EngineLock.swift     // 单实例锁，app 与 CLI 抢同一把
│   └── LaunchAgentInstaller.swift // 无头常驻：把 CLI run 注册成 LaunchAgent
├── UI/
│   ├── PanelRoot.swift      // 面板的根，三页左右推进
│   ├── PanelKit.swift       // 固定度量、页头、分区、行样式、缩略图缓存
│   ├── TimelineView.swift   // 主面板
│   ├── SlotEditorView.swift // 单个时段的编辑页
│   ├── SettingsView.swift   // 开机自启 + 位置
│   └── WallpaperPicker.swift// 缩略图网格
└── CLI/                     // 排障与无头常驻入口
```

界面风格：贴 macOS 原生，版式固定。单面板 + 层级推进，宽度锁死 360 pt，
不开第二个窗口（`Tests/PanelShot` 能把三页画成 PNG 对照）。

---

## 8. 风险与未知

| 风险 | 应对 |
|---|---|
| Index.plist 格式随 macOS 小版本变动 | 写入前先读取并保留未知字段，只改 Choices；每次写入前备份 `.bak` |
| `killall WallpaperAgent` 有短暂闪烁 | 已生效的目标与当前相同时跳过写入（现有 CLI 已实现此优化） |
| 未下载的 aerial 切换后有延迟 | UI 上标注体积；切换时若视频缺失给出提示 |
| 定位权限被拒 | 回退手填经纬度，或退化为纯固定时刻 |
| App 未运行时不切换 | 开机自启 + 唤醒补跑。M2 先用 LaunchAgent 常驻 `hourglow-cli run` 顶着，M4 的 `.app` 改用 `SMAppService` |
| 用户手动换的壁纸被无声抹掉 | 见 §4「手动改壁纸的语义」：没跨过触发边界就让位 |

---

## 9. 验收标准

M4 收尾时跑过一遍，逐条的实测记录见 `TODO.md` 的「验收清单实测」。

- [x] 菜单栏出现图标，点开可见时间轴，当前生效时段有标记
- [x] 新增一个时段并绑定任意 aerial，到点自动切换
- [x] 绑定一张本地图片，到点自动切换，且 slot 仍保持 `linked`
- [x] 「日落前 30 分」的触发时刻随日期变化而变化
- [x] 合盖睡眠跨越某个触发时刻后唤醒，壁纸补切到正确的那张（M2 真机验过）
- [~] 重启后自动运行且状态保持 —— 登录项的注册/注销已验证，真重启待用户确认
- [x] 全局暂停后不再自动切换，恢复后立即校正到当前应生效的壁纸
- [x] 手动换过壁纸后合盖再唤醒，若没跨过触发点，手动那张仍在

---

## 10. 里程碑

| 阶段 | 内容 |
|---|---|
| M1 | `WallpaperWriter` + `AerialCatalog` + `Solar`，纯逻辑层，命令行可验证 |
| M2 | `Scheduler` 引擎跑通，无 UI，替代现有 launchd 脚本 |
| M3 | 菜单栏 UI：时间轴 + 壁纸选择器 |
| M4 | 开机自启、暂停、首次启动预设、打包脚本（全部完成） |

---

## 附：临时方案（已退役）

MVP 完成前曾有一个 Python CLI 在跑：

```
~/.local/bin/tahoe-wallpaper                    # 脚本
~/Library/LaunchAgents/com.bobby.tahoe-wallpaper.plist   # 06/09/17/20 点触发
```

M2 完成时这两样都已不存在，`launchctl` 里也查不到，无需卸载。
现在由 `hourglow-cli run`（可选 `hourglow-cli agent install` 注册成 LaunchAgent）接手。
