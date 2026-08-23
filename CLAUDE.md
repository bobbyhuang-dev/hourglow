# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

HourGlow 是一个 macOS 菜单栏壁纸调度器：按固定时刻或日出日落（带偏移）自动切换系统
aerial 动态壁纸或本地图片。Swift 6.3 + SwiftUI，零第三方依赖，**不使用 Xcode 工程**
（`swiftc` 直接编译 + 手工 `.app` bundle）。

## 先读这两份文档

- `MVP.md` —— 规格。第 2 节是**实机验证过的系统事实**（`Index.plist` 结构、两种
  Provider 的写法、aerial 素材库路径、Tahoe 四张的 assetID），实现时直接依赖，不要重新推测。
- `TODO.md` —— 执行清单与当前进度（M1–M3 已完成，M4 收尾中）。每个里程碑末尾有
  「踩到的坑（别再踩一次）」小节，改对应模块前务必先看。

新会话冷启动读这两份即可接上，不需要回溯对话历史。做完一项工作后，把结论/进度回写进去。

## 构建与验证

没有 XCTest，也没有 `swift test`。验证靠四个独立编译的「靶子」二进制，全部离线、不碰真实壁纸
（`panelshot` 除外，它会短暂弹一个窗口）。

```bash
./build.sh                    # 一次编出全部：CLI、三个靶子、panelshot、build/HourGlow.app
./build/modelcheck            # 求值：跨午夜回绕、solar 触发、Codable 兼容
./build/enginecheck           # 引擎：覆盖 vs 让位的决策矩阵、定时器排期
./build/appcheck              # 应用状态：草稿、保存边界、外部配置冲突
./build/solarcheck            # 日出日落，被 verify-solar.py 当作被测程序调用
python3 Tests/verify-solar.py # 以 ephem 星历对拍（需 pip install ephem，容差 30 秒）
./build/panelshot ~/Desktop   # 三个页面画成 PNG（固定时刻那一栏另出一张），改版式时对照
```

单跑某一项检查：靶子里没有过滤机制，改 `Tests/<Name>/main.swift` 里的 `check(...)` 调用即可；
它们是顺序执行的断言列表，失败计数非零时退出码为 1。

排障与手工验证走 CLI：

```bash
./build/hourglow-cli now                # 当前应生效的壁纸、下次切换、与实际是否一致
./build/hourglow-cli simulate 2026-12-21 # 时间旅行：打印该日全天每一次切换
./build/hourglow-cli apply --dry-run    # 看会写什么，不真写
./build/hourglow-cli run                # 前台常驻引擎，Ctrl-C 退出
./build/hourglow-cli status             # 引擎视角：上次写了什么、现在是不是还是那张
open build/HourGlow.app                 # 菜单栏 app
```

`build.sh` 里入口文件单列成 `ENTRY`：`@main`（`HourGlowApp.swift`）不能和含顶层代码的
`main.swift` 编进同一模块，而 `panelshot` 要复用 `UI/`。新增 UI 文件会被 `Sources/UI/*.swift`
通配到，新增入口则要改脚本。

## 架构

分层是单向的：`UI → AppModel → Scheduler → Resolver/WallpaperWriter`。求值与写入的逻辑
**只有一份**，在 `Engine` 与 `Model` 里；UI 层没有自己的调度副本。

- `Model/` —— 纯数据与求值。`Schedule.swift` 的 `Trigger`/`Wallpaper` 用手写 `Codable`
  编成扁平 JSON（便于用户手改）。`Resolver.swift` 按每个 slot 的偏移反推基准日再前后各展开一天，
  跨午夜回绕由此自然成立。`Store.swift` 原子写 `schedule.json`。
- `System/` —— 与 macOS 打交道。`WallpaperWriter` 读改写 `Index.plist`（保留未知顶层字段、
  写前备份、强制 `linked`、目标一致时跳过写入以免闪屏、写后 `killall WallpaperAgent`）；
  `AerialCatalog` 解析系统的 `entries.json`；`Solar` 是 NOAA 算法；`Location` 从
  `zone.tab` 反查近似坐标（免定位权限）。
- `Engine/` —— `Scheduler` 是核心：定时器直接排到下一个触发点、**不轮询**，由四类系统通知
  （唤醒 / 时钟变更 / 时区变更 / 跨日）补齐意外情况，外加最长 6 小时的安全网。
  `EngineState` 的 `state.json` 记录「我们上次写的是哪张」，是判断用户有没有手动换过的唯一依据。
- `App/AppModel.swift` —— UI 与引擎之间唯一的一层，`@MainActor @Observable`。
- `UI/` —— 单面板 + 三页左右推进（时间轴 → 时段 → 选壁纸），不开第二个窗口。

### 两条必须守住的语义

**1. 用户手动换了壁纸时谁说了算**（`Scheduler.shouldAssert`，类型注释里有完整推导）：
跨过了新的触发边界（到点、睡过头、暂停后恢复）就照常写；没跨过的原地重新求值（启动、唤醒、
时区变更）只有当前壁纸仍是我们上次写的那张时才写，否则让位。判据是
`EngineState.lastFiredAt` 与本次 `Resolution.since` 谁更晚。`enginecheck` 覆盖了整个决策矩阵。

**2. 领跑 / 从属**（`Engine/EngineLock.swift`）：菜单栏 app 与 `hourglow-cli run` 可能同时在。
两个引擎同时排程会互相把对方的写入当成「用户手动改的」，所以启动时先抢 `run.lock`：
抢到的起 `Scheduler`，没抢到的退回从属模式，只编辑 `schedule.json`，由对方的 `ConfigWatcher` 跟上。

## UI 约定

贴 macOS 原生、简洁、**版式固定**。所有度量集中在 `UI/PanelKit.swift` 的 `Panel` 里
（宽度锁死 360 pt；选壁纸页固定 470 pt，其余按内容收）—— 改布局先改那里，不要在视图里散写数字。
行的常驻底色是 macOS 里「选中项」的语言，而这个面板里的行点下去是翻页、没有选中态 ——
所以底色只留给悬停与按下，「现在正在跑的那一段」靠行首一根强调色竖条（`Panel.nowBar`）标。
时段页的改动**不即时生效**：先落进 `AppModel.draft`（草稿），界面立刻跟手，点底部
「应用」才写进 `schedule.json`、才可能换壁纸。草稿放在 model 里而不是视图的 `@State`：
选壁纸是另一页，面板还会一失焦就收起，草稿得比两者都活得久。回到时间轴即结束编辑
（`endEditing`），没应用的改动到此为止。删除是就地两段式确认，不弹对话框
（菜单栏面板里弹框太重），确认后立即生效。

## 运行时路径

```
~/Library/Application Support/HourGlow/schedule.json   # 配置
~/Library/Application Support/HourGlow/state.json      # 上次写了哪张
~/Library/Application Support/HourGlow/run.lock        # 单实例锁
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist  # 系统壁纸配置
~/Library/Application Support/com.apple.wallpaper/aerials/           # aerial 素材库
~/Library/Logs/HourGlow.log                            # LaunchAgent 日志
```

## 语言

代码注释、文档、CLI 输出、UI 文案一律中文。注释解释「为什么这么做」与踩过的坑，不复述代码。

**唯一的例外是 README，它是双语的**：`README.md`（英文，仓库首页给外部读者看的那份）
与 `README.zh-CN.md`（中文），两份内容对等、互相在顶部链接。
**改其中一份就必须同步改另一份**，不允许只更新一边。
