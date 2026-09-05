# CLAUDE.md

本文件给 Claude Code（claude.ai/code）以及其他编码代理提供指引。仓库根目录的 `AGENTS.md`
是它的符号链接，两份内容完全一样 —— 改这一份即可。

HourGlow 是一个 macOS 菜单栏壁纸调度器：按固定时刻、日出日落（带偏移）或天光分段，自动切换
系统 aerial 动态壁纸或本地图片。Swift 6.3 + SwiftUI，零第三方依赖，**不使用 Xcode 工程**
（`swiftc` 直接编译 + 手工组装 `.app` bundle）。当前版本 1.4，已发布。

面向用户的说明看 `README.md` / `README.zh-CN.md`，贡献流程看 `CONTRIBUTING.md`。
本文件是实现者视角：怎么构建、怎么验证、哪些系统事实可以直接依赖、哪些坑别再踩一次。
冷启动读完这一份就能接上，不需要回溯对话历史；做完一项工作后把结论回写进来。

## 构建与验证

没有 XCTest，也没有 `swift test`。验证靠几个独立编译的「靶子」二进制，全部离线、不碰真实壁纸
（`panelshot` 除外，它会短暂弹一个窗口）。

```bash
./build.sh                    # 一次编出全部：CLI、八个靶子、panelshot、build/HourGlow.app
./build/modelcheck            # 求值：跨午夜回绕、solar 触发、天光分段、Codable 兼容
./build/enginecheck           # 引擎：覆盖 vs 让位的决策矩阵、定时器排期
./build/importcheck           # 导入：文件名与分子目录归类、多分辨率、均分、跳过与清理
./build/appcheck              # 应用状态：草稿、保存边界、外部配置冲突、新手指引的弹出规则
./build/appstartupcheck        # Startup recovery and visible/hidden refresh (about 2 minutes)
./build/panelvisibilitycheck   # Native window visibility and observer teardown; briefly shows a test window
./build/updatecheck           # 更新器：SemVer、Release 解析、SHA-256
python3 Tests/verify-updater-location.py # 运行中移动 app/父目录、旧路径副本、助手缺失
./build/l10ncheck Sources     # 文案表：漏词/空词/多词、占位符、挑语言的规则、代码里的 key 是否存在
bash Tests/verify-updater-helper.sh build/HourGlow.app/Contents/Helpers/HourGlowUpdater
bash Tests/verify-app-signature.sh build/HourGlow.app   # 签名与稳定的 designated requirement
./build/solarcheck            # 日出日落，被 verify-solar.py 当作被测程序调用
python3 Tests/verify-solar.py # 以 ephem 星历对拍（需 pip install ephem，容差 30 秒）
python3 Tests/verify-cli-boundaries.py # 非法输入与夏令时 23/25 小时日
./build/panelshot ~/Desktop   # 五个页面 + 新手指引五步画成 PNG（固定时刻那一栏另出一张），改版式时对照
./build/panelshot ~/Desktop --only timeline --now 2026-09-04T06:20   # 只抓一页，并把「现在」定格在某一刻
./build/panelshot ~/Desktop --appearance dark                        # 钉住外观（light | dark），不跟系统
./build/panelshot ~/Desktop --only settings --update-rate-limit       # 限流提示与恢复时间，不联网
Tools/makedemo.sh             # README 顶上的 docs/demo.gif + 官网/GitHub 的分享卡片（见下面「演示图与分享卡片」）
```

配置目录可以用 `HOURGLOW_HOME` 整体改道（`schedule.json` / `state.json` / `run.lock` 都跟着走），
端到端实测拿一份一次性配置跑，不碰真配置：

```bash
HOURGLOW_HOME=/tmp/hg ./build/hourglow-cli list   # 空目录会自动写入 Tahoe 四段预设
```

界面语言用 `HOURGLOW_LANG` 改道，压过存下来的偏好与系统语言，只影响这一次运行、不写任何设置：

```bash
HOURGLOW_LANG=en ./build/hourglow-cli list        # 三种产物都认它
HOURGLOW_LANG=en ./build/panelshot ~/Desktop      # 换版式或加语言之后对着看
./build/hourglow-cli language en                  # 这条才是真写偏好（app 与 CLI 共用）
```

开机自启与定位**问不到 CLI 头上** —— 登录项注册的、定位权限授予的都是「调用者自己的 bundle」，
而 CLI 是裸二进制。这两条排障入口长在 app 的可执行文件上，打印完就退出：

```bash
build/HourGlow.app/Contents/MacOS/HourGlow --login-item status   # status | on | off
build/HourGlow.app/Contents/MacOS/HourGlow --locate              # 定位一次，只打印不写配置
build/HourGlow.app/Contents/MacOS/HourGlow --guide status        # 新手指引：status | reset | show
```

`--guide show` 是唯一不退出的一个：它把这一次启动标成「无论如何都弹指引」，改完版式直接看效果。
「看过了」存在 `UserDefaults`（`onboarding.seenVersion`），`HOURGLOW_HOME` 带不走它，
所以要演一次干净的首次启动得两条一起用：

```bash
HOURGLOW_HOME=/tmp/hg-guide build/HourGlow.app/Contents/MacOS/HourGlow --guide reset
HOURGLOW_HOME=/tmp/hg-guide build/HourGlow.app/Contents/MacOS/HourGlow   # 配置目录是空的 → 指引自动弹
```

单跑某一项检查：靶子里没有过滤机制，改 `Tests/<Name>/main.swift` 里的 `check(...)` 调用即可；
它们是顺序执行的断言列表，失败计数非零时退出码为 1。

排障与手工验证走 CLI：

```bash
./build/hourglow-cli now                # 当前应生效的壁纸、下次切换、与实际是否一致
./build/hourglow-cli simulate 2026-12-21 # 时间旅行：打印该日全天每一次切换
./build/hourglow-cli import ~/Pictures/zhangjiajie  # 一组静帧 → 天光分段时间轴
./build/hourglow-cli location 深圳      # 按城市名设坐标
./build/hourglow-cli apply --dry-run    # 看会写什么，不真写
./build/hourglow-cli run                # 前台常驻引擎，Ctrl-C 退出
./build/hourglow-cli status             # 引擎视角：上次写了什么、现在是不是还是那张
open build/HourGlow.app                 # 菜单栏 app
```

应用图标是画出来的：`Tools/makeicon.swift` 用 SF Symbol 的沙漏加一条晨光→夜色的渐变生成
`Resources/HourGlow.icns`，产物已提交进仓库，`build.sh` 只负责拷进 bundle。改图标才需要
按那个文件头上的用法重跑一次。

### 演示图与分享卡片

`docs/demo.gif`（README 顶上那张，1000 × 625、32 帧、约 10 秒、3.2 MB）与官网仓库的
`assets/og.png`（1200 × 630，`og:image` / Twitter Card / GitHub Social Preview 三处共用一张）
都由 `Tools/makedemo.sh` 生成：拿一份一次性配置（深圳、Tahoe 四段、英文、日期钉死 2026-09-04），
用 `panelshot --only timeline --now …` 在一天里抓十二张时间轴，再由 `Tools/makedemo.swift`
用 AppKit 离屏合成「桌面 + 菜单栏 + 面板」，ImageIO 编成 GIF —— 不引入 ffmpeg / gifsicle。
Evening / Night 两段的面板用 `--appearance dark` 抓：壁纸暗下去面板跟着暗，顺带展示深色模式；
`makedemo.swift` 里 `Phase.dark` 给这两段换成亮色描边，两处名单要一致。
壁纸底图 `tahoe-*.jpg` 不进这个仓库，默认从旁边的官网仓库 `../hourglow-web/assets/` 取。

面板上的「现在」全部走 `AppModel.now`（`nonisolated(unsafe) static var`），只有 `panelshot --now`
会改它；app 与 CLI 永远是真实时钟。新加用到「现在」的界面逻辑时别直接写 `Date()`，
不然定格的截图里那一处会漏出真实时间。

**官网是另一个仓库** `bobbyhuang-dev/hourglow-web`（本机在 `../hourglow-web`），纯静态页 +
Cloudflare Workers，push 到 `main` 即部署。GitHub 仓库的 Social Preview 没有 API，
只能在 Settings › General › Social preview 里手工上传 `og.png`；Homepage 与 Topics 可以
`gh repo edit` 设。

版本号由 `build.sh` 顶上的 `HOURGLOW_VERSION` / `HOURGLOW_BUILD` 决定（默认 `1.4.0` / `1`），
发版流水线用 tag 与 run number 覆盖它们。CI 与发版都在 GitHub Actions 上：
`.github/workflows/ci.yml` 每次 push / PR 跑一遍构建 + 主靶子 + 星历对拍，
`.github/workflows/release.yml` 见到 `v*` tag 就构建、验证、压包、建 Release。
发版踩过的坑见下面「CI 与发版」。

`build.sh` 里入口文件单列成 `ENTRY`：`@main`（`HourGlowApp.swift`）不能和含顶层代码的
`main.swift` 编进同一模块，而 `panelshot` 要复用 `UI/`。新增 UI 文件会被 `Sources/UI/*.swift`
通配到，新增入口则要改脚本。

## 架构

分层是单向的：`UI → AppModel → Scheduler → Resolver/WallpaperWriter`。求值与写入的逻辑
**只有一份**，在 `Engine` 与 `Model` 里；UI 层没有自己的调度副本。

```
Sources/
├── L10n/                      // 界面与命令行的全部文案，三种产物共用
│   ├── L10n.swift             // 挑语言（HOURGLOW_LANG > 偏好 > 系统 > en）、查表、单复数
│   └── Catalogs/<code>.swift  // 一门语言一个文件；zh-Hans 是原文，加语言只加这里
├── App/
│   ├── HourGlowApp.swift      // @main，MenuBarExtra 场景；--login-item / --locate / --guide 入口
│   ├── AppModel.swift         // UI 与引擎之间唯一的一层，@MainActor @Observable
│   ├── SlotDraft.swift        // 时段页的草稿模型（编辑不即时生效）
│   ├── Onboarding.swift       // 新手指引的步骤、文案与「谁该看到它」的规则（纯 Foundation）
│   └── AppUpdater.swift       // GitHub Release 检查、下载、校验与安装交接
├── Model/                     // 纯数据与求值，不碰系统
│   ├── Schedule.swift         // Slot / Trigger / Wallpaper + 手写 Codable（扁平 JSON）
│   ├── Store.swift            // 原子读写 schedule.json，缺失时写入 Tahoe 预设
│   ├── Resolver.swift         // 求值：前后各展开一天，跨午夜回绕由此自然成立
│   ├── TimeMap.swift          // 天光分段：把日出/白昼/日落/夜晚均分到当天的晨昏窗口
│   └── SceneImport.swift      // 一组静帧 → solarPhase 时段（文件名 / 分子目录 / .sundialScene）
├── System/                    // 与 macOS 打交道
│   ├── WallpaperWriter.swift  // 读改写 Index.plist + killall WallpaperAgent
│   ├── AerialCatalog.swift    // 解析系统的 entries.json：名称、分类、缩略图、下载状态与体积
│   ├── Solar.swift            // NOAA 太阳位置算法，日出日落与晨昏
│   ├── Location.swift         // 从 zone.tab 反查近似坐标（免权限的兜底）
│   ├── PreciseLocation.swift  // CoreLocation 只取一次精确坐标，被拒时回退手填
│   ├── Cities.swift           // 常用城市离线表，指引与地点页共用
│   ├── Geocode.swift          // 坐标反查地名（只用来起名字，不替换坐标）
│   └── LaunchAtLogin.swift    // 开机自启，包 SMAppService.mainApp
├── Engine/
│   ├── Scheduler.swift        // 核心：定时器排到下一个触发点 + 系统事件观察 + 决定写不写
│   ├── EngineState.swift      // state.json：我们上次写的是哪张
│   ├── ConfigWatcher.swift    // schedule.json 被手改后立刻跟上
│   ├── EngineLock.swift       // 单实例锁，app 与 CLI 抢同一把
│   └── LaunchAgentInstaller.swift  // 无头常驻：把 CLI run 注册成 LaunchAgent
├── UI/                        // 单面板左右推进，度量集中在 PanelKit
│   ├── PanelRoot.swift        // 面板的根
│   ├── PanelKit.swift         // 固定度量、页头、分区卡片、行样式、缩略图缓存
│   ├── TimelineView.swift     // 主面板：时间轴
│   ├── SlotEditorView.swift   // 单个时段的编辑页
│   ├── WallpaperPicker.swift  // aerial 缩略图网格 + 本地图片
│   ├── SettingsView.swift     // 开机自启 + 位置 + 自动更新 + 帮助
│   ├── PlaceView.swift        // 选择地区
│   ├── OnboardingView.swift   // 新手指引的五步版式
│   └── OnboardingWindow.swift // 装它的那扇窗（全项目唯一一扇）
├── Updater/main.swift         // 主进程退出后原位替换 app 并重启
└── CLI/                       // 排障与无头常驻入口
```

- `Model/` —— `Schedule.swift` 的 `Trigger`/`Wallpaper` 用手写 `Codable` 编成扁平 JSON
  （便于用户手改）。`Resolver.swift` 按每个 slot 的偏移反推基准日再前后各展开一天。
  `TimeMap` 把日出/白昼/日落/夜晚均分到当天的航海晨光→民用黄昏窗口；
  `SceneImport` 按文件名（认不出时看上级文件夹名）把一组静帧编成 `solarPhase` 时段。
- `System/` —— `WallpaperWriter` 读改写 `Index.plist`（保留未知顶层字段、写前备份、强制
  `linked`、目标一致时跳过写入以免闪屏、写后 `killall WallpaperAgent`）。坐标有三条路，
  优先级是 手填/定位写下的 > 时区推断。
- `Engine/` —— `Scheduler` 是核心：定时器直接排到下一个触发点、**不轮询**，由四类系统通知
  （唤醒 / 时钟变更 / 时区变更 / 跨日）补齐意外情况，外加最长 6 小时的安全网。
  `EngineState` 的 `state.json` 记录「我们上次写的是哪张」，是判断用户有没有手动换过的唯一依据。
- `L10n/` —— 只依赖 Foundation，被 `Model` / `System` / `Engine` / `UI` / `CLI` / `Updater`
  一起用，所以在依赖图上排在最前面，`build.sh` 里也单列成 `L10N`。细节见「语言与本地化」。
- `App/Onboarding.swift` —— 纯 Foundation，不碰 UI 也不碰 `Store`，所以能单独编进 `appcheck`。
- `App/AppUpdater.swift` —— 从 GitHub Releases 查正式版、比较 SemVer、下载并校验 asset digest，
  解压后同时核对 bundle ID / 版本 / 代码签名；`Updater/main.swift` 在主进程退出后原位替换 app。

### 两条必须守住的语义

**1. 用户手动换了壁纸时谁说了算**（`Scheduler.shouldAssert`，类型注释里有完整推导）：
跨过了新的触发边界（到点、睡过头、暂停后恢复）就照常写；没跨过的原地重新求值（启动、唤醒、
时区变更）只有当前壁纸仍是我们上次写的那张时才写，否则让位。判据是
`EngineState.lastFiredAt` 与本次 `Resolution.since` 谁更晚。`enginecheck` 覆盖了整个决策矩阵。

两种极端都试过，都不成立：只看「是不是同一段」，那么合盖睡一小时醒来会拿同一张盖掉用户十分钟前的
选择；只看「是不是我们写的那张」，那么手动换过一次之后自动切换就永久失效 —— 与「不需要用户额外
点任何东西」的初衷正好相反。手动选择的有效期到下一次排定的切换为止，跟空调的「临时保持」一个意思。

**2. 领跑 / 从属**（`Engine/EngineLock.swift`）：菜单栏 app 与 `hourglow-cli run` 可能同时在。
两个引擎同时排程会互相把对方的写入当成「用户手动改的」，所以启动时先抢 `run.lock`：
抢到的起 `Scheduler`，没抢到的退回从属模式，只编辑 `schedule.json`，由对方的 `ConfigWatcher` 跟上。
从属方要定期重试：原领跑者退出或 LaunchAgent 被卸载后自动接管，不能留下一个仍显示运行、
实际无人排程的进程。

## 已验证的系统事实

这一节是实机验证过的结论，不是推测。实现时直接依赖，不要重新推测。

### 壁纸配置文件

```
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist   # binary plist
```

写入后需要 `killall WallpaperAgent` 才生效。实测修改不会被系统改回去 ——
用户自己在系统设置里换的会覆盖我们写的，反过来我们写的也会覆盖他的，所以「谁说了算」
完全由上面那条语义决定，不能指望系统帮忙仲裁。

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

每个 choice 形如 `{ Provider: <string>, Files: [], Configuration: <嵌套的 binary plist> }`。

### 两种 Provider

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

静态图的格式是通过调用公开 API `NSWorkspace.setDesktopImageURL` 反推出来的 —— 该 API 确实会
写入 `Index.plist`，但它的读回接口 `desktopImageURL(for:)` 返回的是陈旧值（实测返回
`DefaultDesktop.heic`），**不可信**。另外它会把 slot 从 `linked` 强制改成 `individual`，
写入时必须自己纠正回来。

### Aerial 素材库

```
~/Library/Application Support/com.apple.wallpaper/aerials/
├── manifest/entries.json      # 156 个 asset 的完整元数据
├── thumbnails/<uuid>.png      # 156 张缩略图，全部已本地缓存
└── videos/<uuid>.mov          # 已下载的视频，每个约 430 MB
```

`entries.json` 中每个 asset 的可用字段：`id`、`accessibilityLabel`、`shotID`、
`localizedNameKey`、`categories[]`、`subcategories[]`、`preferredOrder`、`previewImage`、
`includeInShuffle`、`showInTopLevel`、`url-4K-SDR-240FPS`。

分类共 5 个：Landscapes(18 子类) / Cities(6) / Underwater(17) / Space(21) / Mac(1)。

判断某张是否已下载：检查 `videos/<id>.mov` 是否存在。未下载的可以照常写入配置，由系统自行拉取。

### Tahoe 四张的 assetID

首次启动写入的预设就是这四段：日出 → Morning、09:00 → Day、日落前 30 分 → Evening、
日落后 60 分 → Night。它只是一份数据预设，不是硬编码逻辑。

| 时段 | 名称 | shotID | assetID |
|---|---|---|---|
| 晨 | Tahoe Morning | TA_L_001 | `B2FC91ED-6891-4DEB-85A1-268B2B4160B6` |
| 昼 | Tahoe Day     | TA_L_002 | `4C108785-A7BA-422E-9C79-B0129F1D5550` |
| 昏 | Tahoe Evening | TA_D_001 | `52ACB9B8-75FC-4516-BC60-4550CFF3B661` |
| 夜 | Tahoe Night   | TA_D_002 | `CF6347E2-4F81-4410-8892-4830991B6C5A` |

## UI 约定

贴 macOS 原生、简洁、**版式固定**。所有度量集中在 `UI/PanelKit.swift` 的 `Panel` 里
（宽度锁死 360 pt；选壁纸页固定 470 pt，其余按内容收）—— 改布局先改那里，不要在视图里散写数字。
行的常驻底色是 macOS 里「选中项」的语言，而这个面板里的行点下去是翻页、没有选中态 ——
所以底色只留给悬停与按下，「现在正在跑的那一段」靠行首一根强调色竖条（`Panel.nowBar`）标。

设置页（语言 + 开机自启 + 位置 + 自动更新）与时段页并排在第一层，从 ⋯ 菜单或「缺少坐标」那条提示条
进去 —— 提示条说的是哪儿不对，点进去就该是在哪儿改。它的改动**即时生效**：一个开关、
一对坐标、换一门语言都是单次动作，没有「一组改动一起应用」的语义。

时段页则相反，它的改动**不即时生效**：先落进 `AppModel.draft`（草稿），界面立刻跟手，
点底部「应用」才写进 `schedule.json`、才可能换壁纸 —— 否则试错的代价是真把壁纸换过去。
草稿放在 model 里而不是视图的 `@State`：选壁纸是另一页，面板还会一失焦就收起，
草稿得比两者都活得久。回到时间轴即结束编辑（`endEditing`），没应用的改动到此为止。
删除是就地两段式确认，不弹对话框（菜单栏面板里弹框太重），确认后立即生效。

地区是调度的一部分，不是设置里的附录：入口在时间轴右上角那颗胶囊，选完回到时间轴直接看
今天的切换时刻。日出日落的偏移用下拉档位（±120 / 90 / 60 / 45 / 30 / 15 / 正好）而不是步进器 ——
±5 分钟一步在这儿是假精度，而从「正好」按到「一小时后」要点十二下。档位之外的值
（手改过配置、或旧版步进出来的 37 分）会被临时插进列表里，不然菜单选不中当前值。

**新手指引是全项目唯一一扇独立的窗**（`UI/OnboardingWindow.swift`，480 × 566，度量在
`PanelKit` 的 `Guide` 里，与 `Panel` 分开）。破例的理由只有一条：`LSUIElement` 的 app
首次启动后屏幕上什么都不会出现，入口只是菜单栏里一个沙漏，而 `MenuBarExtra` 没有
「替用户点开」的 API —— 指引要是长在面板里，就只有已经找到入口的人看得见，
正好把最需要它的人挡在外面。它**只在真·全新安装时自动弹**（`schedule.json` 不存在），
升级上来的老用户不打扰；入口在 ⋯ 菜单和设置页的「帮助」。关窗即算看过 ——
跳过、走完、点红灯一视同仁。别拿 `OnboardingWindow` 去开第二扇窗。

## 语言与本地化

界面有简体中文与英文两种，默认跟随系统。**面向用户的字符串一个都不写在视图、命令或错误里**，
全部是 `L10n.t("key")` 查出来的。新文案先写进 `Catalogs/zh-Hans.swift`（原文语言），再补别的。

**为什么不是 `.lproj/Localizable.strings`**：这个仓库不走 Xcode 工程，产物里有一堆没有 bundle
的裸二进制（`hourglow-cli`、`panelshot`、八个靶子）。`Bundle.main.localizedString` 在它们身上
只会把 key 原样退回来，靶子也就查不出漏翻。文案编进二进制里，三种产物拿到的是同一份，
加一门语言只是加一个 Swift 文件。

**加一门语言 = 两处改动**：`Sources/L10n/Catalogs/<code>.swift` 加一个文件，
`L10n.catalogs` 加一行。别的都不用动 —— `build.sh` 按通配拿文件，
`CFBundleLocalizations` 也是从这些文件里数出来的，CI 的逐语言冒烟同理。
面向贡献者的完整步骤写在 `CONTRIBUTING.md` 的「Adding a language」里，改了这里记得同步。

**挑哪一门**（`L10n.resolve`，纯函数，`l10ncheck` 按表断言）：
`HOURGLOW_LANG` > 用户在设置页/CLI 选的 > 系统语言 > `defaultCode`（英文）。
每一档都走 `match`：完全一致 → 语言+文字一致（`zh-Hans-CN` → `zh-Hans`）→ 只有语言一致
（`en-GB` → `en`、`zh-Hant` → `zh-Hans`）。最后一档是有意为之，繁体读者看简体比被扔去英文近。

**兜底不是原文语言**：系统是法语、我们只有中英，给英文。`sourceCode`（对完整性、缺词时退回）
与 `defaultCode`（谁都对不上时用）是两件事，别合成一个。

**地名不算翻译工作量**：`StringCatalog.placeNames` 只有 `.chinese` / `.latin` 两档，
`System/Cities.swift` 按它选一列。翻一门语言不必逐个翻几百个地名。

**换语言即时生效**：`L10n.setPreference` 写盘 → 清缓存 → 发 `didChangeNotification`，顺序不能反。
`AppModel` 收到就 `languageGeneration += 1`，`PanelRoot` 拿它当 `.id` 把面板整棵重建。
`.id` 挂在页面上而不是 `PanelRoot` 自己身上，所以在设置页改完语言，人还留在设置页。

**偏好存在 `UserDefaults`，不在 `HOURGLOW_HOME` 里**（和新手指引的 `seenVersion` 一样）：
app 用 `.standard`，CLI 是裸二进制、得显式指名 `UserDefaults(suiteName: "dev.bobbyhuang.hourglow")`。
把自己的 bundle ID 当 suite 传给 `UserDefaults(suiteName:)` 是未定义行为，所以分两条路走。

**`l10ncheck` 守着的**：漏词、空词、多出原文没有的词、孤儿单数形、占位符与原文对不上、
一条文案里混用 `%@` 与 `%1$@`、多参数没写序号；带上 `Sources` 还会把代码里
`L10n.t("…")` 写死的 key 与原文表对一遍 —— 打错一个字母的后果是界面上露出 `slot.apply`
这种半成品，编译器不会拦。

## 运行时路径

```
~/Library/Application Support/HourGlow/schedule.json   # 配置（HOURGLOW_HOME 可整体改道）
~/Library/Application Support/HourGlow/state.json      # 上次写了哪张
~/Library/Application Support/HourGlow/run.lock        # 单实例锁
~/Library/Application Support/HourGlow/Scenes/         # 导入的壁纸组素材
UserDefaults dev.bobbyhuang.hourglow onboarding.seenVersion   # 新手指引看过没（不在 HOURGLOW_HOME 里）
UserDefaults dev.bobbyhuang.hourglow language                 # 界面语言偏好，没有这一条就是跟随系统
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist  # 系统壁纸配置
~/Library/Application Support/com.apple.wallpaper/aerials/           # aerial 素材库
~/Library/LaunchAgents/app.hourglow.agent.plist        # 可选的无头常驻（hourglow-cli agent install）
~/Library/Logs/HourGlow.log                            # LaunchAgent 日志
~/Library/Logs/HourGlow-Updater.log                    # 最近一次 helper 安装结果
~/Library/Caches/HourGlow/Updates/                     # 下载与解包暂存（成功后清理）
```

## 非目标

以下都**不做**，提这些需求时先确认是不是真的要改变这个边界：

- 多显示器 / 多 Space 分别设置（统一写 `linked`，桌面与屏保一起换）
- 桌面与屏保拆开控制
- 随机 / 文件夹轮播
- 跟随系统亮暗模式的触发器
- 天气、Focus 模式触发
- 锁屏壁纸
- 整份 `schedule.json` 的导入导出与 iCloud 同步（壁纸组文件夹导入已做，指的不是它）

## 踩过的坑（别再踩一次）

改对应模块前先看这一节。每一条都是实机上栽过的，不是理论风险。

### 调度与引擎

- **定时器要排在触发时刻之后 1 秒**。早几毫秒会求值到上一段，白跑一轮。
- **`Timer` 要加到 `.common` mode**。菜单栏面板一打开就是另一个 run loop mode，
  用 `.default` 的话面板开着定时器就不走了。
- **收到 `NSSystemTimeZoneDidChange` 后必须 `NSTimeZone.resetSystemTimeZone()`**，
  否则 `TimeZone.current` 拿到的还是旧时区，日出日落会整天算错。
- **目录级 vnode 事件接不住原地改写**。`ConfigWatcher` 一开始只盯目录，理由是 `Store.save`
  用原子写会换掉 inode。结果 `echo >` / `open(path,"w")` 这类原地截断重写根本不产生目录事件，
  实测漏掉了一次配置变更。现在目录和文件两个 source 都挂，并且每次检查后重新挂一次文件
  source（inode 可能刚被顶掉）。
- **自激循环**：`state.json` 和 `schedule.json` 在同一个目录里，引擎每次求值都会写前者，
  目录事件又会触发下一次求值。靠比对 `schedule.json` 的实际内容挡掉。
- **相同触发时刻要稳定决胜**：按配置顺序，靠后的生效；并且「下一次」预告与到点结果必须一致。
- launchd 把 stdout 重定向到文件时是全缓冲的，`setvbuf(_IOLBF)` 之后日志才会实时落盘。
- 默认的 SIGINT/SIGTERM 处理会直接砍掉进程，`DispatchSource` 收不到；
  得先 `signal(sig, SIG_IGN)` 再自己接管。

### 天光分段与导入

- **窗口必须每天重算**。用固定「日出后 20 分」近似 3 张日出，冬天晨光变短就会对不齐。
- 夜晚最后几张的 `fireDate` 落在次日凌晨，靠 Resolver 现成的 ±1 天展开接住，
  不要给 `solarPhase` 再套一层偏移锚点。
- **文件名用 token 匹配，不要 `contains("day")`**：`sunday.heic` 会被误伤。
- **多分辨率去重的键是「去掉 `5120x2880` 那一层之后的整条路径」**，不是光秃秃的文件名。
  按 basename 去重分不清「同一张图的两个分辨率」和「`sunrise/1.jpg` 与 `night/1.jpg`」——
  按段分子目录、文件名从 1 编号的图集会被吃掉大半（12 张进去、3 张出来，还报成功）。
- **判断「是不是同一个目录」一律走 `canonicalPath`**（`resolvingSymlinksInPath`）。
  `standardizedFileURL` 对 `/private/tmp` 的处理不一致：自己拼的 URL 留着 `/private`，
  `contentsOfDirectory` 拿回来的已经是 `/tmp`，按字符串比会把刚写好的素材当成别人的删掉。
- **认不出时段的文件可以不收，但必须报数**。闷声丢掉的结果是一个「已导入」对话框加一条
  少了几张的时间轴，用户无从知道。
- **晨昏算不出来时不要回退成日出/日落本身**：那让「晨光→日出」长度为 0，被除零保护撑成 60 秒，
  一段三张壁纸挤在 20 秒里刷过去，还连着 `killall` 三次 `WallpaperAgent`。用名义时长
  （45 分钟）兜底，并且只在算不出来时用 —— 赤道的民用黄昏本来就只有二十来分钟。
- **极昼极夜那几天一段都排不上**，壁纸会停几个星期。`needsCoordinate` 盖不住它（坐标是有的），
  时间轴要单独给一条提示。
- **定位拿到的精确坐标不要被反查结果替换**。反查回来的是行政区中心点，大城市差几十公里，
  而那次定位授权换来的就是这几十公里。反查只用来起名字。
- **导入是整体替换时间轴且不可撤销，动手前问一句**；素材拷贝放后台，一套几百 MB 会卡住面板。
- **导入要两阶段提交**：新素材先写进唯一目录，配置成功落盘后才按磁盘上的最新时间轴清理旧目录。
  这样复制 / 保存失败可以撤掉新目录，同名或并发导入也不会破坏仍在被引用的素材。
- **菜单栏面板点 ⋯ 的同时会把自己关掉**。立刻 `NSOpenPanel.runModal` 会被一起取消，
  对话框里「导入」像坏了。要等面板收完，临时把 `activationPolicy` 改成 `.regular`，
  并且允许选文件、文件夹和 `.sundialScene`，不能只许选目录。

### 界面

- **`@main` 不能和含顶层代码的 `main.swift` 编进同一个模块**。`Tests/PanelShot` 要复用界面代码，
  所以 `build.sh` 把入口文件 `HourGlowApp.swift` 从 `UI` 里单列成 `ENTRY`。
- **`ImageRenderer` 画不出 `ScrollView` 里的内容**，也画不出 AppKit 撑着的控件（分段控件、
  时间步进器、输入框、菜单）—— 第一版截图工具因此只拍到空面板。改成真窗口 + `NSView.cacheDisplay`。
  那个窗口的 `alphaValue` **必须是 1**：设成 0.02 想让它不显眼，`cacheDisplay` 抓回来的
  就是黑底、只有图片没有文字的半张图。
- 顶层代码不是 main actor 隔离的，`Scheduler` 的 `onLog` / `onEvaluate` 和 `Timer` 的回调
  也都是非隔离闭包 —— 它们确实都跑在主线程上，用 `MainActor.assumeIsolated` 接进来。
- **菜单栏面板一失焦就收起，`NSOpenPanel` 一开它就没了**。所以选完本地图片直接落到配置里，
  不能指望面板还开着。
- **`NSDatePicker` 的内容是贴着自己盒子的底边画的**，下面固定留着字体的降部空间
  （12 pt 与 13 pt 字体都是 6.5 pt），盒子多出来的高度全加在上面。时刻只有数字和冒号，
  一个降部都用不上 —— 所以上下给一样的 padding，看上去是偏上的。`TimeField` 里字号用 12
  （与左边的「每天」一齐），再上 3.5 / 下 3 补平。药丸的底色与留白因此整个包进 `TimeField`，
  不留给调用方去写。
- **`NSPopUpButton` 按最宽的那一项定宽**（给它 `frame(width:)` 也不认），换档时不会忽宽忽窄；
  但它只有一百四十来点宽，单独占一行右边全是空的 —— 所以「今天是 18:16」与它并排摆在同一行的
  右端。缺坐标 / 极昼极夜那两句因此得短，不然挤不进同一行。
- **`.fullSizeContentView` 不改变 `contentRect:` → 窗框的换算**。想把天光渐变铺到顶，
  结果 566 高的内容摆成了 598 高的窗，顶上多一条对不上的空带；`setFrame` 也压不回去
  （`NSHostingView` 把内容尺寸变成了窗口的最小尺寸）。老老实实用系统标题栏并写上标题。
- **第一步那台假 Mac 是示意图，不是仿真图**。按真实比例画，菜单栏在一张 88 pt 高的「屏幕」上
  只剩两三个像素，沙漏根本认不出来 —— 而这一步唯一要说的就是「入口是它」。所以菜单栏占了
  整台机器三分之一高。桌面上原先还画了一颗带光晕的太阳，删了：整张图最亮的一团在正中间，
  视线先落那儿，再也到不了右上角。指着谁，谁最显眼。
- `PlacePage` 里已经有一个叫 `search` 的视图属性，抽出来的 `CitySearch` 状态别也叫 `search` ——
  同名会直接编不过。
- 空搜时 `Cities.search("")` 会给一份常用城市。地点页那种满屏列表放得下，指引里放不下：
  默认列表会把「搜」这个动作本身挤到屏幕外。指引里只在真的输入了才出结果。
- `panelshot` 只抓第一个时段的话，配置里第一段是日出/日落就永远看不到固定时刻那一栏
  （两栏版式完全不同）。现在会另外抓一张 `2b-slot-clock.png`。
- **`panelshot --now` 必须在第一次碰 `AppModel.shared` 之前赋值**：`init` 里就按「现在」求过一次值，
  晚了那张「哪一段在跑」就是真实时间的。演示图要在真实 app 也在跑的机器上抓，所以一定用
  `HOURGLOW_HOME` 指到一次性目录 —— 否则抢不到 `run.lock`，面板上会多一条「后台守护进程在排程」。
- **GIF 里照片帧很贵**：1000 × 625 一帧两三百 KB，交叉淡入每多一帧就多这么多。所以停帧长
  （0.75 秒）、过渡帧只有五帧且很短，总共 32 帧压在 3.2 MB；想加时长加停帧，别加过渡帧。

### 语言

- **`Preference` 要 `Hashable`，不能只 `Equatable`**。设置页那个 `Picker` 的 `selection`
  与 `.tag(...)` 都要求 `Hashable`，只写 `Equatable` 编不过，而错误信息指向的是 SwiftUI。
- **靶子里断言中文原文，就必须先钉住语言**。`modelcheck` 与 `appcheck` 里写着
  `深圳`、`第 1 步 / 共 5 步`，在英文系统上跑会挂在 `深圳` vs `Shenzhen`。两个文件开头
  `setenv("HOURGLOW_LANG", L10n.sourceCode, 1)` + `L10n.invalidate()`，别删。
  真正测「换语言」的是 `l10ncheck`。
- **`getenv` 而不是 `ProcessInfo.environment`**。后者是进程启动时的快照，靶子里 `setenv`
  之后再问它拿到的还是旧值（`Store.directoryURL` 同理）。改完环境变量要 `L10n.invalidate()`，
  语言是缓存住的。
- **Info.plist 里要写 `CFBundleLocalizations`**，否则系统把 app 当成只有开发语言的单语应用，
  「语言与地区 › 应用程序」里也不会出现 HourGlow 这一行。它由 `build.sh` 从
  `Catalogs/*.swift` 里数出来，不另立一份名单 —— 名单一旦有两份，加语言就会漏改一处。
- **同一个词在句子里和在按钮上不是同一条文案**。`sun.sunrise` 是「日落前30分」里的那个词，
  英文要小写；时段页与「固定时刻」并排的分段控件是按钮标题，英文要大写。所以另有
  `slot.kind.sunrise` / `slot.kind.sunset`，中文两处同形，不要合并。
- **CLI 的列宽按显示宽度现算，不写死数字**。`配置` 占四列、`config` 占六列，
  `日落前30分` 占十列、`30 min before sunset` 占二十列 —— 写死 14 会让英文的箭头贴上文字。
  `column(_:min:)` 从当前这批字符串里取最大值，`padded(to:)` 按 `displayWidth` 补齐。
- **多参数的文案必须写 `%n$` 序号**。语序一变，不带序号的那份就取错了参数，
  轻则乱码重则崩。`l10ncheck` 会拦，但先知道比被拦住快。

### 登录项、定位与签名

- **`SMAppService.mainApp.status` 在从没注册过时返回的是 `.notFound`，不是 `.notRegistered`**
  （实测：全新 ad-hoc 签名的 bundle）。照字面把它当成「登录项指向的 app 已不在原位」会一上来
  就报一句假警告 —— 它和 `.notRegistered` 一样只表示「没开」，照样能注册成功。界面上只有
  `.requiresApproval`（用户自己在系统设置里关过）才值得说一句。
- **注册的是当前这个 bundle 的路径**。`build.sh` 每次都 `rm -rf` 重建 `build/HourGlow.app`，
  重建之后原来的登录项就指向了一个不存在的 bundle。所以开着自启时设置页会把 bundle 路径
  显示出来提醒一句；自用请把 app 拷进 `/Applications` 再开。
- **`--locate` 要等系统回调，必须放在 `applicationDidFinishLaunching` 里自己转 run loop**，
  `willFinishLaunching` 太早。
- `CLLocationManagerDelegate` 的方法要声明成 `nonisolated`，再在里面 `MainActor.assumeIsolated` ——
  协议本身没有隔离，`@MainActor` 的类直接实现会被警告「不能满足非隔离的要求」。
  回调确实都在主线程（manager 是在主线程建的）。
- **缺 `NSLocationWhenInUseUsageDescription` 的话系统直接拒绝**，连授权对话框都不弹。
  这一条写在 `build.sh` 生成的 Info.plist 里。
- **ad-hoc 的默认 designated requirement 是 `cdhash`，不能用来升级菜单栏 app**。每次重编都会
  变身份；macOS 26 的 `group.com.apple.controlcenter/trackedApplications` 还可能把新产物误关联
  到旧的 blocked 记录，表现为「允许在菜单栏中显示」已开却启动即退。已被污染的 `app.hourglow`
  记录连系统的 Reset Control Center 都清不掉，所以正式 bundle ID 一次性迁移到
  `dev.bobbyhuang.hourglow`。`build.sh` 同时显式写入 `designated => identifier
  "dev.bobbyhuang.hourglow"`，以后重编和升级都沿用同一身份；`Tests/verify-app-signature.sh`
  与 CI/Release 同时防回归。

### 新手指引

- **`MenuBarExtra` 的 label 会在 `applicationWillFinishLaunching` 之前就把 `AppModel` 造出来**。
  实测：一个在 `willFinishLaunching` 里就 `exit(0)` 的探针，跑完之后 `HOURGLOW_HOME` 目录里
  已经躺着 `schedule.json` 了 —— 那是 `AppModel.init → Store.load()` 写的。所以「这次是不是
  全新安装」不能在 delegate 里问，`AppModel.init` 的第一行才是最早的时机。两处都调
  `Onboarding.captureFirstRun`，第一次调用说了算。
- **指引不能自动弹给老用户**。`seenVersion` 为空只说明「没看过」，不说明「新装」—— 自动更新到
  新版之后突然弹一扇窗解释「什么是时间轴」是打扰。判据得是配置文件存不存在。
- **关窗就得算看过**，跳过、走完、点红灯一视同仁。少写一种，它下次启动还会来，
  比没有这个指引更烦人。

### 更新器

- **不能让正在运行的主进程覆盖自己**。下载与验签由 app 做，真正的 move 交给一个先复制到缓存
  目录的 helper；helper 等旧 PID 消失之后才动 bundle，且始终先把旧 app 挪成备份，
  新 app 到位和 `open` 都成功后才删备份。
- **只校验下载哈希不够**。GitHub asset digest 能挡传输损坏，但发布元数据和文件在同一信任域；
  所以解压后仍用 `codesign --verify --deep --strict` 校验整个 bundle，并要求稳定的
  `designated => identifier "dev.bobbyhuang.hourglow"`。
- **嵌套 helper 要先签名**。外层 app 的签名会把 `Contents/Helpers` 当 nested code；
  `build.sh` 必须先签 `HourGlowUpdater`，再签 `HourGlow.app`，否则深度验签不成立。
- **要边读取边等待 `ditto` / `codesign`**。先 `waitUntilExit` 再读 pipe，会在子进程输出写满
  管道缓冲时父子互等，死在那儿。
- 自动更新沿用 app 当前路径。父目录不可写（只读卷、某些标准用户的 `/Applications`）时不尝试提权，
  设置页直接给出失败原因，用户仍可打开 GitHub 发布页手动安装。

### CI 与发版

- **runner 必须是 `macos-26`**。`LSMinimumSystemVersion` 是 26.0，SDK 低了根本编不过；
  `macos-latest` 现在正好指向它，但写死版本号更稳，免得哪天 `latest` 漂走。
- **runner 上常并存多个 Xcode，默认那个不一定最新**，所以两个 workflow 都先
  `ls -d /Applications/Xcode_*.app | sort -V | tail -1` 再 `xcode-select -s`。
- **`.app` 只能用 `ditto -c -k --keepParent` 压**。`zip` 不保留符号链接与扩展属性，解压出来的
- **403 不一定是限流**。额度剩余为 0、429、Retry-After 或明确的限流响应正文才进入等待。
  读取 `x-ratelimit-reset` / `Retry-After`，提示本地日期、时间与时区；缺失或异常时不编造
  重置时间，至少等一分钟。期限存在 UserDefaults，手动、自动检查与重启都遵守它；普通
  403 单独解释请求被拒。错误在设置页占整行并允许换行，不能把恢复时间截掉。
- **`Bundle.main` 的路径会停在启动时的位置**。运行中移动 app 或它的父目录，旧路径下找不到
  helper，不能误报「不是从 app 启动」。更新器用 `proc_pidpath` 取得当前可执行文件的位置，
  校验 bundle ID 与 executable 后统一用于检查、复制 helper 与安装目标；助手缺失另报原因。
  `verify-updater-location.py` 用真实子进程覆盖移动、改名、旧路径出现副本与助手权限变化。
  bundle 签名是坏的。反过来，裸二进制的 CLI 用 `zip -qj` 就够 —— `ditto --sequesterRsrc`
  会额外塞一份 `__MACOSX/`。压完再解一次跑 `codesign --verify --deep --strict`，
  确认压包这一步没把签名弄坏。
- **CI 里不能跑要读系统文件的 CLI 子命令**：runner 上没有 aerial 素材库、也没有 `Index.plist`，
  `catalog` / `now` / `status` / `apply` 在那里没有意义。冒烟只跑 `list` / `solar` / `simulate`，
  并且用 `HOURGLOW_HOME` 指到 `$RUNNER_TEMP`。
- **GitHub runner 的时区是 UTC，而 UTC 在 `zone.tab` 里查不到坐标**。没手填经纬度时，`Location`
  的时区反查落空，`solar` / `list` 里的 solar 段就会（正确地）报「没有坐标可用」并退出 1 ——
  CI 第一次跑就栽在这。冒烟步骤因此把 `TZ` 指成 `Asia/Shanghai`。这不是 bug：
  UTC 本来就不对应任何地面位置。
- **ad-hoc 签名 + 未公证 = 用户首次打开会被拦**。README 与发布说明都写了两条出路：
  `xattr -dr com.apple.quarantine`，或系统设置 › 隐私与安全性 › 仍要打开。真要免掉这一步，
  得有付费开发者账号做 `notarytool` 公证。

### 日出日落的验证

- **ephem 的 `next_rising(horizon='-0:50')` 会在给定 horizon 之外再扣一次日面半径**，
  等于把 16 角分算了两遍，结果偏约 75 秒。`verify-solar.py` 因此改成直接二分求
  「太阳几何中心高度 = -50 角分」，定义上无歧义。
- `api.sunrise-sunset.org` 的结果与 NOAA 定义差约 65 秒，不适合当秒级参考；且它会 403 掉
  urllib 的默认 User-Agent。现在验证已完全离线。

## 写作语言

代码注释与文档一律中文。注释解释「为什么这么做」与踩过的坑，不复述代码。

面向用户的字符串（UI 文案、CLI 输出、错误消息）**不写在代码里**，全部是 `Sources/L10n/` 里的
一条 key；新文案先写进 `Catalogs/zh-Hans.swift`，那份是原文。详见上面的「语言与本地化」。

**例外是面向外部读者的文件，它们用英文**：`CONTRIBUTING.md`、`SECURITY.md`，
以及 `README.md`。README 是双语的 —— `README.md`（英文，仓库首页那份）与 `README.zh-CN.md`
（中文），两份内容对等、互相在顶部链接，**改其中一份就必须同步改另一份**，不允许只更新一边。


### 2026-09-05 发版边界回归

- **坏配置不是首次安装**。`AppModel` 初次读取失败时使用空时间轴并留在从属重试状态，
  不抢排程锁、不拿 Tahoe 预设换壁纸、也不允许设置动作覆盖原文件；配置修复后由监听与
  30 秒接管重试恢复。`appstartupcheck` 编入真实 AppModel 验证整条链，恢复时用暂停配置。
- **配置校验要同时守住解码与保存**。经纬度必须有限且在合法范围内，固定时刻不能超出
  23:59，slot ID 不能重复；保存前先校验，失败不触碰原文件。旧配置 `id: null` 与省略 ID
  一样会生成 UUID，必须回写，不然每次加载都变身份。
- **外部整数不能直接取负或相乘**。太阳偏移的 `Int.min` 用 `magnitude` 转字符串展示，
  中英文占位符都用 `%@`，避免溢出和 `%d` 的 32 位截断；图集分辨率评分乘法检测溢出。
  扫描时只收普通文件，名为 `night.jpg` 的目录不是图片。
- **本地一天不是永远 24 小时**。CLI `simulate` 按 Calendar 的 day interval 扫描，
  夏令时开始/结束日分别覆盖 23/25 小时。`verify-cli-boundaries.py` 从真实 CLI 验证。
- 更新 helper 回归除成功替换外还覆盖等待活着的父进程、第二次 move 失败后恢复旧 app。

## Performance and idle power (2026-09-05)

- Display refresh runs every 30 seconds only while the menu panel is visible. A hidden leader
  has no display ticker; a hidden follower retains the same 30-second takeover retry without
  reading wallpaper/state files on every retry. Promotion cancels that ticker when hidden.
  Opening the panel refreshes immediately. Scheduler deadlines, manual override rules, and
  configuration watching remain independent of panel visibility.
- Use `PanelVisibilityObserver` to observe the host window's actual visibility. A retained
  `NSHostingView` does not necessarily call SwiftUI `onDisappear` on `orderOut`, or `onAppear`
  on reopening. `panelvisibilitycheck` verifies repeated show/hide, rapid closing, and teardown.
  `appstartupcheck` verifies hidden idle periods, visible updates, reopening, and takeover.
- Scene resolution shares `TimeMap.DayWindows` within one `firings` call, including nil results
  on polar days. Never retain these results across calls: the location, calendar, or date may
  change. The direct-trigger comparisons in `modelcheck` cover DST, polar days, missing location,
  mixed triggers, disabled slots, and ties.
- `Tools/benchmark-resolver.swift` measures offline scene resolution with 300 iterations per
  size. On the review machine with Swift 6.3.3 and `-O`, 120 slots improved from about 3.43 to
  0.31 ms per resolution; 480 slots improved from 13.94 to 1.36 ms. These are computation timings,
  not measurements of battery-life improvement or of macOS's aerial renderer.
