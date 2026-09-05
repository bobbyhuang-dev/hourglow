# HourGlow

> [English](README.md) · **中文**

[![CI](https://github.com/bobbyhuang-dev/hourglow/actions/workflows/ci.yml/badge.svg)](https://github.com/bobbyhuang-dev/hourglow/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bobbyhuang-dev/hourglow?label=release)](https://github.com/bobbyhuang-dev/hourglow/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](#要求)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

<p align="center">
  <img src="docs/demo.gif" width="800" alt="装着 HourGlow 的 Mac 上的一天：Tahoe 壁纸在日出、09:00、日落前与入夜后各换一次，菜单栏面板里的时间轴标着现在跑到哪一段。">
</p>

跟着天光走的 macOS 壁纸调度器。

macOS Tahoe 提供了 Tahoe Morning / Day / Evening / Night 四张动态壁纸，却没有像旧版
macOS 那样按时间自动切换的能力。HourGlow 补上这个缺口 —— 但不写死这四张，而是做成一个
通用的「触发条件 → 壁纸」调度器：你定义若干时段，每段绑一张壁纸，它负责在正确的时刻切换。

菜单栏常驻，无 Dock 图标。Swift 6.3 + SwiftUI，零第三方依赖，二进制不到 5 MB。
界面有简体中文与英文两种。

## 功能

- **三种触发条件** —— 固定时刻，相对日出/日落（偏移可正可负，如「日落前 30 分」），
  或天光分段：把当天的晨昏/白昼/夜晚窗口按这一段有几张图等分（24 Hour Wallpaper 那套）
- **两种壁纸来源** —— 系统自带的 156 张 aerial 动态壁纸，或本地图片
- **时段数量不限** —— Tahoe 那四张只是首次启动写入的预设，随便改、随便删
- **日出日落本地计算** —— NOAA 太阳位置算法，不联网。坐标可以向系统取一次精确定位，
  也可以搜城市或手填经纬度；都没有时，按系统时区反查一个近似坐标，免权限也能用。
  中国全境都是 `Asia/Shanghai`，选深圳还是上海，日出能差十几到四十分钟
- **不轮询** —— 定时器直接排到下一个触发点；睡眠唤醒、系统时钟变更、时区变更、跨日
  各有对应的系统通知，合盖睡过了某个触发时刻，醒来会补切
- **不跟你抢** —— 你自己去系统设置里换了一张，HourGlow 不会在下一次原地求值时无声抹掉它；
  手动选择的有效期到下一次排定的切换为止（详见下文）
- **改动不即时生效** —— 时段页上调时刻、换壁纸都先攒成草稿，点「应用」才写进日程、
  才可能换壁纸；试错不必真的把壁纸换过去
- **开机自启** —— `SMAppService` 注册的登录项，在「系统设置 › 登录项」里看得见、关得掉
- **内建更新** —— 可以手动检查，也可以每天自动检查 GitHub Releases；下载后校验哈希与
  代码签名，原位安装并自行重启
- **配置是人类可读的 JSON** —— 手改 `schedule.json` 后引擎立刻跟上
- **简体中文与 English** —— 默认跟随系统语言，面板、新手指引与命令行一起切换。
  加一门语言只是加一个文件、加一行，见[怎么加一门语言](CONTRIBUTING.md#adding-a-language)
- **第一次打开有指引** —— 五步讲清楚：图标去哪儿了、要授权什么、系统对话框长什么样、
  位置怎么设（不想给定位就搜城市）、时间轴怎么看。随时可以跳过，⋯ 菜单里还能再打开
- **导入 24 小时壁纸组** —— 文件名带 sunrise / morning / day / sunset / evening / night
  （或 `01_sunrise_1.heic`，或 24 Hour Wallpaper 的 `.sundialScene`），也可以按段分子目录
  （`sunrise/1.jpg`），会编成一条跟着当地太阳走的全天时间轴。四段张数可以各不相同。
  导入会整体替换现有时间轴，动手前会问一次；认不出属于哪一段的文件不收，但会报给你

## 下载

**[⬇ 下载最新版本](https://github.com/bobbyhuang-dev/hourglow/releases/latest)**
—— 拿 `HourGlow-x.y.z.zip`，解压，把 `HourGlow.app` 拖进「应用程序」。

应用是 ad-hoc 签名、**未经公证**（没有付费的 Apple 开发者账号），macOS 会拦下首次打开。
执行一次这条清掉隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/HourGlow.app
```

或者先双击一次，再去**系统设置 › 隐私与安全性 › 仍要打开**放行。

之后它常驻菜单栏 —— 没有 Dock 图标，也没有窗口。全新安装第一次打开会弹一份五步指引：
图标在哪儿、怎么授权定位（不想给就直接搜城市）、开机自启、时间轴怎么看。想跳过随时可以跳，
⋯ 菜单和设置页都能再打开它。同样是这一次启动，会写入 Tahoe 四段预设，随便改、随便删。
想让它重启后自己回来，打开**开机自启** —— 指引第三步，或设置页（⋯ 菜单）。

自动更新默认开启。设置页可以关掉、手动检查，或立即安装已经发现的版本。更新会留在当前
app 所在位置，所以请先把它放进「应用程序」再打开开机自启。

当前构建使用稳定的代码身份和新 bundle ID，避开 macOS 26 Control Center 的一个问题：
ad-hoc 签名应用升级后，即使设置显示已允许，菜单栏项仍可能被隐藏。旧版日程会保留，
但身份迁移后可能需要重新授权定位、重新打开一次**开机自启**。

同一个页面上的 `hourglow-cli-x.y.z.zip` 是可选的命令行工具（见下），
把里面的二进制放到 `PATH` 上任意位置即可。

## 安全与工作原理

HourGlow 对你的 Mac 只做一件事：换壁纸。下面把这件事涉及的每一处都说清楚，信不信得过你自己判断。

- **改的是什么。** macOS 把壁纸设置存在
  `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`。HourGlow 读这个文件，
  换掉里面的壁纸条目，写回去，再重启 `WallpaperAgent` 让改动生效。它不认识的字段原样保留，
  统一写成 `linked`（桌面与屏保一起换），文件里已经是目标值时直接跳过不写 —— 不闪屏。
  这不是公开 API，macOS 更新有可能改格式。
- **先备份。** 每次写入前先把这个文件复制成同目录下的 `Index.plist.hourglow.bak`，备份失败就不写。
  想手动还原：退出 HourGlow，把备份复制回 `Index.plist`，执行 `killall WallpaperAgent` ——
  或者干脆去系统设置里随便选一张。
- **它自己的文件。** 日程、引擎状态与导入的壁纸组在 `~/Library/Application Support/HourGlow/`；
  日志在 `~/Library/Logs/HourGlow*.log`；更新包下载到 `~/Library/Caches/HourGlow/`（装完清掉）；
  语言与「指引看过了」记在它自己的偏好里。它会读系统的 aerial 素材表拿名字和缩略图。
  磁盘上别的地方一概不碰。
- **权限。** 一项都不是必需的。定位是可选的：给了就取一次坐标，以明文经纬度存进 `schedule.json`，
  之后不再问；不给就搜城市或手填经纬度，再不然按时区推断。开机自启是普通的登录项，
  在「系统设置 › 通用 › 登录项」里看得见、关得掉。不要辅助功能，不要完全磁盘访问，不要录屏。
- **日出日落在你的 Mac 上算**，用的是 NOAA 太阳位置算法，从不访问任何日出日落服务。
- **哪些会联网。** 自动更新开着（默认）时，每天向 `api.github.com` 问一次最新版本；
  你点了安装才从 GitHub 下载。搜地点时，内置城市表里没有的名字会先问 Apple 的 MapKit 地理编码，
  再不行问 OpenStreetMap 的 Nominatim。就这些：没有遥测，没有统计，不需要账号。
  在设置里关掉自动更新，它就不会自己发任何请求。
- **更新会先验证再替换**：下载的 SHA-256 对照 Release 里的 asset digest，解压后再核对 bundle ID、
  版本与完整的代码签名。旧 app 会留作备份，直到新 app 成功启动。
- **未经公证。** 发布版由构建脚本 ad-hoc 签名 —— 背后没有付费的 Apple 开发者账号 ——
  所以 macOS 首次打开会问一次。不想信二进制的话，[从源码构建](#从源码构建)，一条命令。

## 要求

macOS 26 (Tahoe) 及以上。从源码构建只需要命令行的 Swift 工具链（`xcode-select --install`
即可），不需要完整的 Xcode。

## 从源码构建

```bash
git clone https://github.com/bobbyhuang-dev/hourglow.git
cd hourglow
./build.sh
open build/HourGlow.app
```

`build.sh` 用 `swiftc` 直接编译并手工组装 `.app`（ad-hoc 签名，个人自用足够），
不经过 Xcode 工程。签名显式写入稳定的 designated requirement，避免重编或升级后
被 macOS 26 误认为新的菜单栏应用。产物全部落在 `build/`。每次推送都由 GitHub Actions
（`.github/workflows/ci.yml`）以同样的方式构建并跑一遍验证；推一个 `v*` tag
则触发构建、验证、发版（`.github/workflows/release.yml`）。

## 命令行

`hourglow-cli` 是排障入口，也可以当作无头常驻使用：

```bash
./build/hourglow-cli now                 # 当前应生效的壁纸、下次切换、与实际是否一致
./build/hourglow-cli list                # 时间轴与今天各段的实际时刻
./build/hourglow-cli catalog Space       # 列出系统 aerial（含下载状态与体积）
./build/hourglow-cli simulate 2026-12-21 # 时间旅行：打印该日全天的每一次切换
./build/hourglow-cli solar               # 今天的日出、日落、航海晨光、民用黄昏
./build/hourglow-cli location 深圳       # 按城市名设坐标
./build/hourglow-cli language en         # 界面与命令行的语言（不带参数只打印现状）
./build/hourglow-cli import ~/Pictures/zhangjiajie   # 一组静帧 → 天光分段时间轴
./build/hourglow-cli apply --dry-run     # 看会写什么，不真写
./build/hourglow-cli run                 # 前台常驻引擎
./build/hourglow-cli agent install       # 注册成 LaunchAgent，重启后仍然活着（无头场合用）
```

开机自启与定位问不到 CLI 头上 —— 登录项注册的、定位权限授予的都是「调用者自己的 bundle」，
而 CLI 是个裸二进制。新手指引也一样：「看过了」记在 app 自己的 `UserDefaults` 里，
不在配置目录里。这几条入口都在 app 的可执行文件上：

```bash
build/HourGlow.app/Contents/MacOS/HourGlow --login-item status   # status | on | off
build/HourGlow.app/Contents/MacOS/HourGlow --locate              # 定位一次，只打印不写配置
build/HourGlow.app/Contents/MacOS/HourGlow --guide status        # 新手指引：status | reset | show
```

`--guide status` 打印这次启动会不会弹指引、为什么；`--guide reset` 把「看过了」忘掉；
`--guide show` 立刻打开一次。

菜单栏 app 与 `hourglow-cli run` 抢同一把单实例锁：先起的那个负责排程，后起的退回从属模式，
只编辑配置，由对方跟上。

## 语言

界面有简体中文与英文两种，默认跟随系统语言。两种都对不上时用英文。

想钉死一种，走设置页（⋯ 菜单 › 设置 › 语言），或者走命令行。app 与 CLI 共用同一份偏好，
面板不用重启就跟着变：

```bash
hourglow-cli language            # 现在是哪门、偏好存的是什么、有哪些可选
hourglow-cli language en         # 钉死英文
hourglow-cli language system     # 改回跟随系统
```

`HOURGLOW_LANG=en hourglow-cli list` 压过上面两者，只影响这一条命令、不写任何设置 ——
截图和提 issue 的时候用得上。

**加一门语言**只需要在 `Sources/L10n/Catalogs/` 里加一个文件、在 `Sources/L10n/L10n.swift`
里加一行 —— 除了把一张字典填满，不用写别的 Swift，还有一个靶子会告诉你到底还缺哪几条。
步骤见 [CONTRIBUTING.md › Adding a language](CONTRIBUTING.md#adding-a-language)。
非常欢迎翻译。

## 手动改壁纸时谁说了算

你随时可能自己去系统设置里换一张。HourGlow 按「是否跨过了新的触发边界」分开处理：

- **跨过了**（到点了、睡过了某个触发时刻、暂停后恢复）—— 照常写。手动选择的有效期到
  下一次排定的切换为止，跟空调的「临时保持」一个意思。
- **没跨过**（启动、唤醒、时区变更等原地重新求值）—— 只有当前壁纸确实还是它上次写的那张
  时才写；否则让位，不把你十分钟前的选择无声抹掉。

## 配置

`~/Library/Application Support/HourGlow/schedule.json`，可以直接手改：

```json
{
  "paused": false,
  "slots": [
    {
      "id": "…",
      "enabled": true,
      "trigger": { "type": "solar", "event": "sunrise", "offsetMinutes": 0 },
      "wallpaper": { "type": "aerial", "assetID": "B2FC91ED-6891-4DEB-85A1-268B2B4160B6" }
    },
    {
      "id": "…",
      "enabled": true,
      "trigger": { "type": "clock", "hour": 9, "minute": 0 },
      "wallpaper": { "type": "image", "path": "/Users/you/Pictures/noon.heic" }
    },
    {
      "id": "…",
      "enabled": true,
      "trigger": { "type": "solarPhase", "phase": "sunrise", "index": 0, "count": 3 },
      "wallpaper": { "type": "image", "path": "/Users/you/Library/Application Support/HourGlow/Scenes/zhangjiajie/sunrise_1.heic" }
    }
  ]
}
```

其余运行时路径：状态 `state.json`、单实例锁 `run.lock`（同目录），
LaunchAgent 日志 `~/Library/Logs/HourGlow.log`。整个配置目录可以用 `HOURGLOW_HOME`
环境变量改道 —— 拿一份一次性配置试东西时用得上，真配置不受影响。

## 验证

没有 XCTest。验证靠几个独立编译的靶子，全部离线、不碰真实壁纸：

```bash
./build/modelcheck             # 求值：跨午夜回绕、solar 触发、天光分段、Codable 兼容
./build/enginecheck            # 引擎：覆盖 vs 让位的决策矩阵、定时器排期
./build/importcheck            # 导入：24 Hour Wallpaper 文件名、多分辨率、均分
./build/appcheck               # 应用状态：草稿、保存边界、外部配置冲突、新手指引的弹出规则
./build/appstartupcheck        # 损坏配置启动、修复后自动接管（约 30 秒）
./build/updatecheck            # 更新器：SemVer 排序、Release 解析、SHA-256
./build/l10ncheck Sources      # 文案表：不漏词、不空、不多词，占位符对得上，代码里用到的 key 都存在
bash Tests/verify-updater-helper.sh build/HourGlow.app/Contents/Helpers/HourGlowUpdater
bash Tests/verify-app-signature.sh build/HourGlow.app   # 签名与稳定的 designated requirement
python3 Tests/verify-solar.py  # 日出日落对拍 ephem 星历（10 个案例，最大偏差 4 秒）
python3 Tests/verify-cli-boundaries.py # 非法输入与夏令时 23/25 小时日
./build/panelshot ~/Desktop    # 把各个界面和新手指引五步画成 PNG，改版式时对照
```

## 状态

稳定，作者本人每天在用。**当前版本 1.5** —— 时间轴上多了一条今日天光条，空闲时更省电，
更新器学会了尊重 GitHub 限流与被移动过的 app。1.4 加了英文界面，1.3 加了新手指引，
1.2 带来了 24 Hour Wallpaper 导入与天光分段调度，1.1 加了内建更新，
1.0 完成了调度引擎、菜单栏界面、开机自启与精确定位。

实现笔记在 [CLAUDE.md](CLAUDE.md)：分层、实机验证过的 macOS 壁纸存储格式，
以及已经踩过一次、不该再踩第二次的坑。

面向用户的文案不写在视图里，全部集中在 `Sources/L10n/`。

### 不打算做的

明说边界，免得你抱着错的期待下载：

- 多显示器 / 多 Space 分别设置 —— 桌面与屏保永远一起换，因为写入时统一保持 `linked`
- 桌面与屏保拆开控制
- 随机 / 文件夹轮播
- 跟随系统亮暗模式、天气、Focus 模式的触发器
- 锁屏壁纸
- 整份日程的导出与同步（导入壁纸**组**是支持的，这里说的是 `schedule.json` 本身）

## 参与

欢迎提 issue 和 PR —— 怎么构建、怎么验证一处改动、这份代码遵循哪些约定，
见 [CONTRIBUTING.md](CONTRIBUTING.md)（那份文件是英文的，给外部读者看）。

把 HourGlow 翻成另一门语言是最小的一种参与：抄一个文件、填一张字典、加一行。
步骤见 [Adding a language](CONTRIBUTING.md#adding-a-language)。

发现安全问题请**不要**开公开 issue，按 [SECURITY.md](SECURITY.md) 私下上报。

## License

[Apache License 2.0](LICENSE)。Copyright 2026 Bobby Huang。
