# HourGlow

> [English](README.md) · **中文**

[![CI](https://github.com/bobbyhuang-dev/hourglow/actions/workflows/ci.yml/badge.svg)](https://github.com/bobbyhuang-dev/hourglow/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bobbyhuang-dev/hourglow?label=release)](https://github.com/bobbyhuang-dev/hourglow/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](#要求)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

跟着天光走的 macOS 壁纸调度器。

macOS Tahoe 提供了 Tahoe Morning / Day / Evening / Night 四张动态壁纸，却没有像旧版
macOS 那样按时间自动切换的能力。HourGlow 补上这个缺口 —— 但不写死这四张，而是做成一个
通用的「触发条件 → 壁纸」调度器：你定义若干时段，每段绑一张壁纸，它负责在正确的时刻切换。

菜单栏常驻，无 Dock 图标。Swift 6.3 + SwiftUI，零第三方依赖，二进制不到 5 MB。

## 功能

- **两种触发条件** —— 固定时刻，或相对日出/日落（偏移可正可负，如「日落前 30 分」）
- **两种壁纸来源** —— 系统自带的 156 张 aerial 动态壁纸，或本地图片
- **时段数量不限** —— Tahoe 那四张只是首次启动写入的预设，随便改、随便删
- **日出日落本地计算** —— NOAA 太阳位置算法，不联网。坐标可以向系统取一次精确定位，
  也可以手填经纬度；两者都没有时，按系统时区反查一个近似坐标，免权限也能用
- **不轮询** —— 定时器直接排到下一个触发点；睡眠唤醒、系统时钟变更、时区变更、跨日
  各有对应的系统通知，合盖睡过了某个触发时刻，醒来会补切
- **不跟你抢** —— 你自己去系统设置里换了一张，HourGlow 不会在下一次原地求值时无声抹掉它；
  手动选择的有效期到下一次排定的切换为止（详见下文）
- **改动不即时生效** —— 时段页上调时刻、换壁纸都先攒成草稿，点「应用」才写进日程、
  才可能换壁纸；试错不必真的把壁纸换过去
- **开机自启** —— `SMAppService` 注册的登录项，在「系统设置 › 登录项」里看得见、关得掉
- **配置是人类可读的 JSON** —— 手改 `schedule.json` 后引擎立刻跟上

## 下载

**[⬇ 下载最新版本](https://github.com/bobbyhuang-dev/hourglow/releases/latest)**
—— 拿 `HourGlow-x.y.z.zip`，解压，把 `HourGlow.app` 拖进「应用程序」。

应用是 ad-hoc 签名、**未经公证**（没有付费的 Apple 开发者账号），macOS 会拦下首次打开。
执行一次这条清掉隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/HourGlow.app
```

或者先双击一次，再去**系统设置 › 隐私与安全性 › 仍要打开**放行。

之后它常驻菜单栏 —— 没有 Dock 图标，也没有窗口。首次启动会写入 Tahoe 四段预设，
随便改、随便删。想让它重启后自己回来，去设置页（⋯ 菜单）打开**开机自启**。

当前构建使用稳定的代码身份和新 bundle ID，避开 macOS 26 Control Center 的一个问题：
ad-hoc 签名应用升级后，即使设置显示已允许，菜单栏项仍可能被隐藏。旧版日程会保留，
但身份迁移后可能需要重新授权定位、重新打开一次**开机自启**。

同一个页面上的 `hourglow-cli-x.y.z.zip` 是可选的命令行工具（见下），
把里面的二进制放到 `PATH` 上任意位置即可。

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
./build/hourglow-cli solar               # 今天的日出日落
./build/hourglow-cli apply --dry-run     # 看会写什么，不真写
./build/hourglow-cli run                 # 前台常驻引擎
./build/hourglow-cli agent install       # 注册成 LaunchAgent，重启后仍然活着（无头场合用）
```

开机自启与定位问不到 CLI 头上 —— 登录项注册的、定位权限授予的都是「调用者自己的 bundle」，
而 CLI 是个裸二进制。这两条入口在 app 的可执行文件上，打印完就退出：

```bash
build/HourGlow.app/Contents/MacOS/HourGlow --login-item status   # status | on | off
build/HourGlow.app/Contents/MacOS/HourGlow --locate              # 定位一次，只打印不写配置
```

菜单栏 app 与 `hourglow-cli run` 抢同一把单实例锁：先起的那个负责排程，后起的退回从属模式，
只编辑配置，由对方跟上。

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
./build/modelcheck             # 求值：跨午夜回绕、solar 触发、Codable 兼容
./build/enginecheck            # 引擎：覆盖 vs 让位的决策矩阵、定时器排期
./build/appcheck               # 应用状态：草稿、保存边界、外部配置冲突
python3 Tests/verify-solar.py  # 日出日落对拍 ephem 星历（10 个案例，最大偏差 4 秒）
./build/panelshot ~/Desktop    # 把四个界面画成 PNG，改版式时对照
```

## 状态

**1.0 —— MVP 已经完成。** M1（逻辑层）、M2（调度引擎）、M3（菜单栏界面）、
M4（开机自启、精确定位、打包收尾）全部完成，`MVP.md` 第 9 节的验收清单跑过一遍。
规格见 `MVP.md`，进度与实现笔记见 `TODO.md`。

## 它是怎么改壁纸的

macOS 把壁纸配置存在 `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`
（binary plist），改完 `killall WallpaperAgent` 生效。HourGlow 读改写这个文件：保留所有
未知字段、写入前备份、统一写成 `linked`（桌面与屏保一起换）、目标与当前一致时跳过写入以免闪屏。
格式细节见 `MVP.md` 第 2 节，都是实机验证过的。

这是没有公开 API 的做法，随 macOS 小版本变动的风险自负。

## License

MIT
