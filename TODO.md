# HourGlow — TODO

规格见 `MVP.md`。本文件是执行清单，新会话冷启动读这两个文件即可接上，
不需要回溯对话历史。

**当前进度**：M3 完成（菜单栏 UI 跑通，`build/HourGlow.app` 可直接双击）。下一步 M4。

---

## 已定的决策（不再讨论）

- 名字 `HourGlow`；`hourglow.app` 与 `github.com/hourglow` 均未被占用
- Swift 6.3 + SwiftUI，`swiftc` 手工打包，不依赖 Xcode，零第三方依赖
- 触发器：固定时刻 + 日出日落（带偏移）
- 壁纸来源：系统 aerial + 本地图片
- 写入时统一保持 `linked`（桌面与屏保一起换）
- 首次启动预设：日出→Morning、09:00→Day、日落前30分→Evening、日落后60分→Night
- 先做逻辑层和引擎（M1/M2），UI 放 M3
- **UI 风格**：贴 macOS 原生，简洁、版式固定。单面板 + 层级推进
  （时间轴 → 时段 → 选壁纸），不开第二个窗口；宽度锁死 360 pt
- **用户手动改了壁纸怎么办**：按「是否跨过新的触发边界」分开处理（M2 已实现，
  见 `Scheduler` 的类型注释）。跨过了就照常写；没跨过（启动、唤醒、时区变更等
  原地重新求值）只有当前壁纸还是我们上次写的那张时才写。

---

## M1 — 逻辑层（已完成）

- [x] 工程骨架：`Sources/` 目录树 + `build.sh`（swiftc → 二进制；`.app` 打包留到 M4）
- [x] `Model/Schedule.swift`：`Slot` / `Trigger` / `Wallpaper` + 自定义 `Codable`（扁平 JSON，便于手改）
- [x] `Model/Store.swift`：读写 `~/Library/Application Support/HourGlow/schedule.json`，缺失时写入 Tahoe 预设
- [x] `Model/Resolver.swift`：前后各展开一天求值，天然处理跨午夜回绕
- [x] `System/WallpaperWriter.swift`
  - [x] 读 `Index.plist`，保留未知顶层字段
  - [x] 支持 aerial 与 image 两种 Provider
  - [x] 写入前备份 `.hourglow.bak`；强制 slot 为 `linked`
  - [x] 目标与当前一致时跳过写入（避免闪烁）
  - [x] 写入后 `killall WallpaperAgent`
- [x] `System/AerialCatalog.swift`：156 个 asset 的名称/分类/缩略图/下载状态与体积
- [x] `System/Location.swift`：从 `/usr/share/zoneinfo/zone.tab` 反查近似坐标，
      免定位权限（CoreLocation 留到 M4 做精确化）
- [x] `System/Solar.swift`：NOAA 算法 + 两轮迭代
- [x] `Tests/verify-solar.py`：以 ephem 星历为参考对拍，10 个案例全过，**最大偏差 4 秒**
- [x] `hourglow-cli`：`list` / `now` / `current` / `apply` / `set` / `catalog` / `simulate` / `solar` / `location`
- [x] `simulate` 时间旅行：按分钟走完一整天打印每次切换，验证跨午夜回绕与季节漂移
      （同一份配置：夏至傍晚 18:00 切 Evening，冬至 16:26 就切，差 2.5 小时）

### M1 期间踩到的坑（别再踩一次）

- ephem 的 `next_rising(horizon='-0:50')` 会在给定 horizon 之外**再扣一次日面半径**，
  等于把 16 角分算了两遍，结果偏约 75 秒。验证脚本因此改成直接二分求
  「太阳几何中心高度 = -50 角分」，定义上无歧义。
- `api.sunrise-sunset.org` 的结果与 NOAA 定义差约 65 秒，不适合当秒级参考；
  且它会 403 掉 urllib 的默认 User-Agent。现在验证已完全离线。
- zsh 不对无引号变量做分词，`set -- $var` 不会拆开。

## M2 — 调度引擎（已完成）

- [x] `Engine/Scheduler.swift`
  - [x] 求值复用 M1 的 `Resolver`；定时器直接排到下一个触发点，不轮询
  - [x] `NSWorkspace.didWakeNotification` 唤醒补跑
  - [x] `NSSystemClockDidChange` / `NSSystemTimeZoneDidChange` / `NSCalendarDayChanged`
        —— 时钟被改、时区变更、夏令时、跨日各有各的通知，都不靠轮询发现
  - [x] 安全网：定时器最长睡 6 小时；求不出值（缺坐标 / 极昼极夜）15 分钟后重试
  - [x] 全局暂停 / 恢复；恢复时无视手动改动立即校正
- [x] `Engine/EngineState.swift`：`state.json` 记下「我们上次写的是哪张」，
      这是判断「用户是不是自己换过」的唯一依据
- [x] `Engine/ConfigWatcher.swift`：手改 `schedule.json` 后引擎立刻跟上
- [x] **用户手动改壁纸的语义**（原先在 a / b / c 里犹豫，最后落在 a+c 的组合上）
      - 纯 a：合盖睡一小时，醒来还在同一时段内，却会拿同一张盖掉用户十分钟前的选择
      - 纯 c：手动换过一次之后自动切换就此永久失效，除非手动换回我们写的那张 ——
        与「不需要用户额外点任何东西」的初衷正好相反
      - 落地：**跨过新的触发边界就照常写；没跨过则只在当前壁纸仍是我们写的那张时才写**。
        手动选择的有效期到下一次排定的切换为止，跟空调的「临时保持」一个意思
- [x] `hourglow-cli run`：前台常驻，`flock` 单实例，SIGINT/SIGTERM 优雅退出
- [x] `hourglow-cli status / pause / resume`
- [x] `hourglow-cli agent install|uninstall|status`：注册成 LaunchAgent
      （`app.hourglow.agent`，日志 `~/Library/Logs/HourGlow.log`）。
      M4 的 `.app` 会改用 `SMAppService`，在那之前靠它活过重启
- [x] `Tests/EngineCheck`：覆盖/让位的决策矩阵 + 定时器排期，纯离线
- [x] 临时方案已不存在（`~/.local/bin/tahoe-wallpaper` 与
      `com.bobby.tahoe-wallpaper` 都查无此物，`launchctl` 里也没有），无需卸载

### M2 的端到端实测（都跑过真机）

- 起 daemon → 到点自动切换，日志 `[到点] 已切换`，落在触发时刻 +1 秒
- 手动换壁纸后原地重写 `schedule.json` → `[配置变更] 让位给手动选择`，壁纸不动
- `pause` → `[配置变更] 已暂停`，定时器撤掉；`resume` → `[恢复] 已切换`，无视手动改动
- 第二个 `run` 被文件锁挡住

### M2 期间踩到的坑（别再踩一次）

- **目录级 vnode 事件接不住原地改写**。`ConfigWatcher` 一开始只盯目录，理由是
  `Store.save` 用原子写会换掉 inode。结果 `echo >` / `open(path,"w")` 这类
  原地截断重写根本不产生目录事件，实测漏掉了一次配置变更。现在目录和文件两个
  source 都挂，并且每次检查后重新挂一次文件 source（inode 可能刚被顶掉）。
- **自激循环**：`state.json` 和 `schedule.json` 在同一个目录里，引擎每次求值都会写
  前者，目录事件又会触发下一次求值。靠比对 `schedule.json` 的实际内容挡掉。
- 定时器要排在触发时刻**之后** 1 秒。早几毫秒会求值到上一段，白跑一轮。
- 收到 `NSSystemTimeZoneDidChange` 后必须 `NSTimeZone.resetSystemTimeZone()`，
  否则 `TimeZone.current` 拿到的还是旧时区，日出日落会整天算错。
- `Timer` 要加到 `.common` mode。M3 的菜单栏面板一打开就是另一个 run loop mode，
  用 `.default` 的话面板开着定时器就不走了。
- launchd 把 stdout 重定向到文件时是全缓冲的，`setvbuf(_IOLBF)` 之后日志才会实时落盘。
- 默认的 SIGINT/SIGTERM 处理会直接砍掉进程，`DispatchSource` 收不到；
  得先 `signal(sig, SIG_IGN)` 再自己接管。

## M3 — 菜单栏 UI（已完成）

- [x] `App/HourGlowApp.swift`：`MenuBarExtra` + `.menuBarExtraStyle(.window)`；
      打包脚本写的 `Info.plist` 里设 `LSUIElement`（无 Dock 图标、无主窗口）
- [x] `App/AppModel.swift`：UI 与引擎之间唯一的一层。视图只读它的展示状态、
      只调它的方法，求值与写入仍旧全在 `Scheduler` 里，没有为 UI 复制一份调度逻辑
- [x] `UI/PanelRoot.swift`：三页在同一块画布上左右推进（像「控制中心」那种系统面板）
- [x] `UI/TimelineView.swift`：时段列表，按今天的实际时刻排序，当前生效项高亮；
      顶部是「现在挂着哪张 / 几点换下一张」，底部是立即应用 / 暂停 / ⋯
- [x] `UI/SlotEditorView.swift`：触发条件编辑器（固定时刻用步进式时间选择器，
      日出日落用 ±5 分钟步进并显示「今天是 HH:mm」）、壁纸、启用、删除
- [x] `UI/WallpaperPicker.swift`：3 列缩略图网格，5 个分类筛选 + 名称/shotID 搜索，
      未下载的压暗并标下载角标，底部「选择本地图片…」
- [x] `UI/PanelKit.swift`：固定度量、页头、分区卡片、行样式、缩略图缓存
- [x] `Engine/EngineLock.swift`：把 M2 藏在 `RunCommand` 里的单实例锁提出来共用
- [x] `build.sh` 产出 `build/HourGlow.app`（ad-hoc 签名，可双击运行）
- [x] `Tests/PanelShot`：把三个页面离屏画成 PNG，改版式时对照

### M3 的几个决定

- **领跑 / 从属**。后台可能已经有 `hourglow-cli run` 或 M2 装的 LaunchAgent 在排程，
  两个引擎同时跑会互相把对方的写入当成「用户手动改的」。启动时抢 `EngineLock`：
  抢到就自己起 `Scheduler`，没抢到就只编辑 `schedule.json`（对方的 `ConfigWatcher`
  会跟上），面板顶部说明现在是谁在管。
- ~~**改动即时生效，没有「保存」按钮**~~（M4 推翻，见下）。原方案是连续变化的控件
  在 `AppModel` 里去抖 0.35 秒再落盘 —— 拖一次步进器写十几次配置、连带写十几次壁纸
  并不合适。
- **面板宽度锁死 360 pt**；时间轴与时段页按内容收（列表最多 300 pt 再滚动），
  选壁纸那页固定 470 pt。只有四个时段却撑出一屏空白不好看，而网格页跟着筛选结果
  一跳一跳更不好看。
- **删除要点两下**（按钮就地变成「再点一次以删除」）。菜单栏面板里弹确认框太重。

### M3 期间踩到的坑（别再踩一次）

- `@main` 不能和含顶层代码的 `main.swift` 编进同一个模块。`Tests/PanelShot` 要复用
  界面代码，所以 `build.sh` 把入口文件 `HourGlowApp.swift` 从 `UI` 里单列成 `ENTRY`。
- **`ImageRenderer` 画不出 `ScrollView` 里的内容**，也画不出 AppKit 撑着的控件
  （分段控件、时间步进器、输入框、菜单）—— 第一版截图工具因此只拍到空面板。
  改成真窗口 + `NSView.cacheDisplay`。
- 那个窗口的 `alphaValue` **必须是 1**。设成 0.02 想让它不显眼，`cacheDisplay`
  抓回来的就是黑底、只有图片没有文字的半张图，白白排查了一轮。
- 顶层代码不是 main actor 隔离的，`Scheduler` 的 `onLog` / `onEvaluate` 和
  `Timer` 的回调也都是非隔离闭包 —— 它们确实都跑在主线程上，用
  `MainActor.assumeIsolated` 接进来。
- 菜单栏面板一失焦就收起，`NSOpenPanel` 一开它就没了。所以选完本地图片直接落到
  配置里，不能指望面板还开着。
- `Timer` 记得加到 `.common` mode（M2 就写在注释里了，面板一开就是另一个 mode）。

## M4 — 收尾

- [x] 时段页改成「草稿 + 应用」：编辑不再即时生效
- [ ] 开机自启（`SMAppService.mainApp`）
- [ ] 定位权限流程；被拒时回退到手填经纬度
- [ ] 首次启动写入 Tahoe 四段预设
- [ ] 打包脚本产出可双击运行的 `HourGlow.app`
- [ ] 跑一遍 `MVP.md` 第 9 节的验收清单

### 草稿 + 应用（推翻 M3 的「即时生效」）

改一个时段的时刻或壁纸就立刻换壁纸，试错的代价太大 —— 想比较两张只能真的换过去。
现在时段页的每一次改动只写 `AppModel.draft`，点底部「应用」才 `commit`。

- 草稿放在 `AppModel` 而不是 `SlotPage` 的 `@State`：选壁纸是另一页，`SlotPage` 会被
  卸下来重建；`NSOpenPanel` 更是必定把面板整个关掉。草稿得比页面和面板都活得久 ——
  `PanelRoot.onAppear` 发现还有草稿就回到那一段，不无声地丢掉没应用的改动。
- `beginEditing(id)` 对同一个 id 是幂等的，否则从选壁纸页返回时会把半路的改动冲掉。
- 「添加时段」也只起草稿（`beginNewSlot`），点「添加」才进配置。所以 `PanelRoot` 里
  「时段被别处删掉就退回时间轴」的守卫要用 `editing(_:)` 判断，不能用 `slot(_:)`,
  否则新时段刚建出来就被自己踢掉。
- 「应用」按钮里要先记下 `draftIsNew` 再 `applyDraft()` —— 落盘之后它就不「新」了。
- 去抖没有了：连续变化的控件只改内存里的草稿，本来就不写盘。
- 删除仍然即时（本来就要点两下确认）；暂停 / 立即应用是时间轴上的操作，不受影响。
- `Tests/AppCheck` 覆盖草稿状态机：保存成功前不冒充已应用；编辑期间外部修改会标冲突，
  外部删除不会把旧草稿误认成新时段并复活。

### M4 期间踩到的坑（别再踩一次）

- **`NSDatePicker` 的内容是贴着自己盒子的底边画的**，下面固定留着字体的降部空间
  （12 pt 字体 6.5 pt、13 pt 字体也是 6.5 pt），盒子多出来的高度全加在上面。时刻只有
  数字和冒号，一个降部都用不上 —— 所以上下给一样的 padding，看上去是「上 8.5 下 10」
  的偏上。`TimeField` 里字号用 12（与左边的「每天」一齐，这时数字与步进器的偏移
  正好都是半点），再上 3.5 / 下 3 补平。13 pt 时差额是 1.5 pt，补平数字反而会把
  步进器顶歪。药丸的底色与留白因此整个包进 `TimeField`，不留给调用方去写。
- 时间轴上「现在正在跑的那一段」原来是整行铺强调色 —— 那是 macOS 列表里「我选中了它」的
  样子，看着像用户点过，而不是引擎的状态。改成行首一根强调色竖条（`Panel.nowBar`），
  底色只留给悬停与按下；`PanelRowStyle` 的 `tinted` 参数跟着删掉了。
- `panelshot` 只抓第一个时段的话，配置里第一段是日出/日落就永远看不到固定时刻那一栏
  （两栏版式完全不同）。现在会另外抓一张 `2b-slot-clock.png`。

---

## 环境速查

```
壁纸配置   ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
aerial 库  ~/Library/Application Support/com.apple.wallpaper/aerials/
项目目录   ~/documents/programming/HourGlow/
引擎配置   ~/Library/Application Support/HourGlow/schedule.json
引擎状态   ~/Library/Application Support/HourGlow/state.json   # 上次写了哪张
单实例锁   ~/Library/Application Support/HourGlow/run.lock
常驻       ~/Library/LaunchAgents/app.hourglow.agent.plist
守护日志   ~/Library/Logs/HourGlow.log
临时方案   已不存在（曾经是 ~/.local/bin/tahoe-wallpaper + com.bobby.tahoe-wallpaper）
构建验证   swiftc -O -parse-as-library main.swift -o Probe    # 已验证可行
```

```
./build.sh                    # CLI + 各验证靶子 + panelshot + HourGlow.app
open build/HourGlow.app       # 菜单栏 app（M3）
./build/panelshot ~/Desktop   # 把三个页面画成 PNG（固定时刻那一栏另出一张），改版式时对照
./build/enginecheck           # 引擎决策矩阵与定时排期
./build/hourglow-cli run      # 前台常驻，Ctrl-C 退出（和 app 抢同一把 EngineLock）
./build/hourglow-cli status   # 上次写了什么、现在是不是还是那张
```

plist 结构、Provider 格式、四个 assetID 见 `MVP.md` 第 2 节。
