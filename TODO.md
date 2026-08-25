# HourGlow — TODO

规格见 `MVP.md`。本文件是执行清单，新会话冷启动读这两个文件即可接上，
不需要回溯对话历史。

**当前进度**：M1–M6 全部完成；1.2 在做 24 Hour Wallpaper 导入与天光分段。`build/HourGlow.app`
可直接双击，开机自启、定位、首次启动预设和内建更新都已落地，`MVP.md` 第 9 节的验收清单
跑过一遍（结果见 M4 末尾）；CI 与发版流水线见 M5，更新实现与安全边界见 M6。

---

## 已定的决策（不再讨论）

- 名字 `HourGlow`；`hourglow.app` 与 `github.com/hourglow` 均未被占用
- Swift 6.3 + SwiftUI，`swiftc` 手工打包，不依赖 Xcode，零第三方依赖
- 触发器：固定时刻 + 日出日落（带偏移）+ 天光分段（24 Hour Wallpaper 模型）
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
      顶部是「现在挂着哪张 / 几点换下一张」，底部是暂停 / ⋯（M4 删掉了「立即应用」）
- [x] `UI/SlotEditorView.swift`：触发条件编辑器（固定时刻用步进式时间选择器，
      日出日落从预设档位的下拉列表里挑并显示「今天是 HH:mm」）、壁纸、启用、删除
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

## M4 — 收尾（已完成）

- [x] 时段页改成「草稿 + 应用」：编辑不再即时生效
- [x] 设置页（面板的第四页，从 ⋯ 或「缺少坐标」那条提示进）
- [x] 开机自启（`System/LaunchAtLogin.swift`，走 `SMAppService.mainApp`）
- [x] 定位权限流程（`System/PreciseLocation.swift`）；被拒时回退到手填经纬度
- [x] 首次启动写入 Tahoe 四段预设 —— 代码 M1 就在 `Store.load` 里，这次才**真的**
      在一个空目录上验过（靠新加的 `HOURGLOW_HOME`，见下）
- [x] 打包脚本产出可双击运行的 `HourGlow.app`，并补上应用图标
- [x] 跑一遍 `MVP.md` 第 9 节的验收清单

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
- 删除仍然即时（本来就要点两下确认）；暂停是时间轴上的操作，不受影响。
- `Tests/AppCheck` 覆盖草稿状态机：保存成功前不冒充已应用；编辑期间外部修改会标冲突，
  外部删除不会把旧草稿误认成新时段并复活。

### 验收清单实测（`MVP.md` 第 9 节）

在一份一次性配置上跑的（`HOURGLOW_HOME` 指向临时目录，两个时段分别排在实测时刻的
1 分钟与 2 分钟后），跑完把真配置该有的那张写回去：

| 项 | 结果 |
|---|---|
| 菜单栏图标、时间轴、当前时段有标记 | ✓ app 起来后拿到 `EngineLock`（`status` 显示「引擎 在跑」）；版式见 `panelshot` |
| 新增时段绑 aerial，到点自动切换 | ✓ `21:49:01 [到点] 已切换 → Tahoe Evening`，落在触发时刻 +1 秒 |
| 绑本地图片，到点切换且 slot 仍是 `linked` | ✓ `21:50:01 → Dusty Rose.png`，写完两个 slot 的 `Type` 都还是 `linked` |
| 「日落前 30 分」随日期变化 | ✓ `simulate`：夏至 18:32 切 Evening，冬至 16:26，差 2 小时 6 分 |
| 合盖睡过触发时刻后唤醒补切 | M2 已在真机上验过；`enginecheck` 覆盖决策矩阵。本轮没再合盖 |
| 重启后自动运行且状态保持 | 开机自启注册/注销都验过（`--login-item on/off` → `已开启` / `未开启`），真重启没做 |
| 暂停不再切换，恢复立即校正 | ✓ 暂停期间手动换成 Tahoe Day 引擎不动；`resume` 立刻校正回 Dusty Rose |
| 手动换过、没跨触发点时手动那张仍在 | ✓ 手动换成 Tahoe Morning 后改配置逼它重新求值：`[配置变更] 让位给手动选择` |

首次启动预设另外单验：空目录 + `HOURGLOW_HOME` → `schedule.json` 自动生成，
四段正是日出/09:00/日落前 30/日落后 60。

定位单验：`--locate` 拿到 22.7963, 114.6854，而时区推断给的是上海 31.23, 121.47 ——
差出来的日出日落有二十多分钟，这一栏确实值得做。

### M4 的几个决定

- **设置页与时段页并排**（都是从时间轴推进一层），不是模态、也不开第二个窗口。
  开机自启与坐标都不是每天要动的东西，但又都会决定调度对不对（没坐标日出日落整段被跳过），
  所以「缺少坐标」那条提示条本身做成了可点的入口 —— 说的是哪儿不对，点进去就是在哪儿改。
- **设置页的改动即时生效**，不套时段页那套草稿。一个开关、一对坐标都是单次动作，
  没有「一组改动一起应用」的语义，草稿只会碍事。
- **`LaunchAgentInstaller` 从 `CLI/` 挪进了 `Engine/`**。设置页要能看见 M2 那条
  LaunchAgent、能一键卸载它（app 自己会开机自启之后它就是多余的第二份常驻），
  而 CLI 那份代码 app 编不进来。挪过去时把 `fail()` 换成了 `throws`。
- **定位只取一次**，不做持续定位：坐标不会自己跑，日出日落对它的敏感度也就是
  「几十公里 ≈ 一分钟」。拿到就写进 `schedule.json` 的 `location`，之后一直用它。
- **`HOURGLOW_HOME` 环境变量**可以把整个配置目录挪走（`schedule.json` / `state.json` /
  `run.lock` 都跟着走）。加它是因为「首次启动写入预设」只能在空目录上验证，而
  `NSHomeDirectory()` 在 macOS 上取的是账户真实家目录，**改 `$HOME` 不管用**
  （非沙盒进程走 getpwuid）。顺带也让端到端实测能在一份一次性配置上跑，不动真配置。
- **图标是画出来的**（`Tools/makeicon.swift`：SF Symbol 沙漏 + 晨光→暮色→夜色的竖向渐变），
  产物 `Resources/HourGlow.icns` 提交进仓库，`build.sh` 只负责拷。改图标才需要重跑那个工具。
- **日出日落的偏移从步进器换成了下拉列表**（±120 / 90 / 60 / 45 / 30 / 15 / 正好）。
  ±5 分钟一步在这儿是假精度：日出日落本身按季节每天挪一两分钟，没人分得清「日落后 55 分」
  与「后 60 分」，而从「正好」按到「一小时后」要点十二下。档位之外的值（手改过
  `schedule.json`、或旧版步进出来的 37 分）会被临时插进列表里，不然菜单选不中当前值。
  弹出菜单只有一百四十来点宽，单独占一行右边全是空的 —— 所以「今天是 18:16」不再另起一行，
  与它并排摆在同一行的右端（和固定时刻那一栏「每天 …… 09:00」同构），一栏正好两行。
  缺坐标 / 极昼极夜那两句因此得短，不然挤不进同一行。
  宽度不用管：`NSPopUpButton` 按最宽的那一项定宽（给它 `frame(width:)` 也不认），
  换档时不会忽宽忽窄。

- **删掉了时间轴上的「立即应用」**。它做的事引擎自己一直在做（到点、唤醒、改配置都会
  重新求值），按下去多半什么也不变，却占着底部唯一一个主按钮的位置。`AppModel.applyNow()`
  跟着删掉；`Scheduler.applyNow()` 留着，CLI 的 `apply` 还用它。

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
- **`SMAppService.mainApp.status` 在从没注册过时返回的是 `.notFound`，不是
  `.notRegistered`**（实测：全新 ad-hoc 签名的 bundle、放在 `build/` 里）。照字面把它
  当成「登录项指向的 app 已不在原位」会一上来就报一句假警告 —— 它和 `.notRegistered`
  一样只表示「没开」，照样能注册成功。界面上只有 `.requiresApproval`（用户自己在系统设置里
  关过）才值得说一句。
- **注册的是当前这个 bundle 的路径**。`build.sh` 每次都 `rm -rf` 重建 `build/HourGlow.app`，
  重建之后原来的登录项就指向了一个不存在的 bundle。所以开着自启时，设置页会把 bundle
  路径显示出来提醒一句；自用请把 app 拷进 `/Applications` 再开。
- **开机自启与定位都没法从 `hourglow-cli` 验证**：`SMAppService.mainApp` 注册的、
  以及定位权限授予的，都是**调用者自己的 bundle**，而 CLI 是个裸二进制。所以这两条排障
  入口长在 app 的可执行文件上：`HourGlow.app/Contents/MacOS/HourGlow --login-item [status|on|off]`
  与 `--locate`，打印完就 `exit`，菜单栏上不留图标。`--locate` 要等系统回调，
  必须放在 `applicationDidFinishLaunching` 里自己转 run loop，`willFinishLaunching` 太早。
- `CLLocationManagerDelegate` 的方法要声明成 `nonisolated`，再在里面
  `MainActor.assumeIsolated` —— 协议本身没有隔离，`@MainActor` 的类直接实现会被警告
  「不能满足非隔离的要求」。回调确实都在主线程（manager 是在主线程建的）。
- 缺 `NSLocationWhenInUseUsageDescription` 的话系统**直接拒绝**，连授权对话框都不弹。
  这一条写在 `build.sh` 生成的 Info.plist 里。

---

## M5 — 发布 1.0（已完成）

- [x] `.github/workflows/ci.yml`：每次 push / PR 在 `macos-26` 上编一遍、跑主靶子、
      跑一遍 `verify-solar.py` 对拍星历，外加几条纯计算的 CLI 冒烟
- [x] `.github/workflows/release.yml`：推 `v*` tag 就构建、验证、压包、建 GitHub Release
- [x] `build.sh` 的版本号改成可注入：`HOURGLOW_VERSION` / `HOURGLOW_BUILD`（默认 1.0.1 / 1），
      流水线用 tag 与 run number 覆盖
- [x] README 双语都加上下载入口、徽章，状态改成 1.0

### 发布相关的坑

- **runner 必须是 `macos-26`**。`LSMinimumSystemVersion` 是 26.0，SDK 低了根本编不过；
  `macos-latest` 现在正好指向它，但写死版本号更稳，免得哪天 `latest` 漂走。
- **runner 上常并存多个 Xcode，默认那个不一定最新**，所以两个 workflow 都先
  `ls -d /Applications/Xcode_*.app | sort -V | tail -1` 再 `xcode-select -s`。
- **`.app` 只能用 `ditto -c -k --keepParent` 压**。`zip` 不保留符号链接与扩展属性，
  解压出来的 bundle 签名是坏的。反过来，裸二进制的 CLI 用 `zip -qj` 就够 ——
  `ditto --sequesterRsrc` 会额外塞一份 `__MACOSX/`。
  压完再解一次跑 `codesign --verify --deep --strict`，确认压包这一步没把签名弄坏。
- **CI 里不能跑要读系统文件的 CLI 子命令**：runner 上没有 aerial 素材库、也没有
  `Index.plist`，`catalog` / `now` / `status` / `apply` 在那里没有意义。冒烟只跑
  `list` / `solar` / `simulate`，并且用 `HOURGLOW_HOME` 指到 `$RUNNER_TEMP`。
- **GitHub runner 的时区是 UTC，而 UTC 在 `zone.tab` 里查不到坐标**。没手填经纬度时，
  `Location` 的时区反查落空，`solar` / `list` 里的 solar 段就会（正确地）报
  「没有坐标可用」并退出 1 —— CI 第一次跑就栽在这。冒烟步骤因此把 `TZ` 指成
  `Asia/Shanghai`。这不是 bug：UTC 本来就不对应任何地面位置。
- **ad-hoc 签名 + 未公证 = 用户首次打开会被拦**。README 与发布说明都写了两条出路：
  `xattr -dr com.apple.quarantine`，或系统设置 › 隐私与安全性 › 仍要打开。
  真要免掉这一步，得有付费开发者账号做 `notarytool` 公证 —— 1.0 不做。
- **ad-hoc 的默认 designated requirement 是 `cdhash`，不能用来升级菜单栏 app**。
  每次重编都会变身份；macOS 26 的 `group.com.apple.controlcenter/trackedApplications`
  还可能把新产物误关联到旧的 blocked 记录，表现为「允许在菜单栏中」已开却启动即退。
  已被污染的 `app.hourglow` 记录连系统的 Reset Control Center 都清不掉，
  所以正式 bundle ID 一次性迁移到 `dev.bobbyhuang.hourglow`。`build.sh` 同时显式写入
  `designated => identifier "dev.bobbyhuang.hourglow"`，以后重编和升级都沿用同一身份；
  `Tests/verify-app-signature.sh` 与 CI/Release 同时防回归。

---

## M6 — 内建更新（已完成，1.1）

- [x] 设置页新增「自动更新」开关（默认开）、「检查更新」与「更新并重启」
- [x] app 启动后检查一次，常驻期间每小时看一次时间戳，实际最多每 24 小时联网一次
- [x] 只读取 `bobbyhuang-dev/hourglow` 的 GitHub `releases/latest`；SemVer 比较不会按字符串
      把 `1.10` 误判成小于 `1.9`，也不会把开发中的较新构建降级
- [x] 下载 GitHub Release 中精确命名的 `HourGlow-x.y.z.zip`，先核对 asset 的 SHA-256 digest，
      再核对 bundle ID、`CFBundleShortVersionString` 与完整代码签名
- [x] `Contents/Helpers/HourGlowUpdater` 等主进程退出后才原位替换 bundle；失败时把旧版回滚，
      成功后重启并清理缓存
- [x] `Tests/UpdateCheck` 离线覆盖版本、Release fixture 与 SHA-256；
      `verify-updater-helper.sh` 用临时假 bundle 覆盖替换和清理
- [x] CI 与 Release 发版前都跑更新器两组检查；版本默认值升到 1.1.0

### 更新相关的坑

- **不能让正在运行的主进程覆盖自己**。下载与验签由 app 做，真正的 move 交给一个先复制到
  缓存目录的 helper；helper 等旧 PID 消失之后才动 bundle，且始终先把旧 app 挪成备份，
  新 app 到位和 `open` 都成功后才删备份。
- **只校验下载哈希不够**。GitHub asset digest 能挡传输损坏，但发布元数据和文件在同一信任域；
  所以解压后仍用 `codesign --verify --deep --strict` 校验整个 bundle，并要求稳定的
  `designated => identifier "dev.bobbyhuang.hourglow"`。
- **嵌套 helper 要先签名**。外层 app 的签名会把 `Contents/Helpers` 当 nested code；
  `build.sh` 必须先签 `HourGlowUpdater`，再签 HourGlow.app，否则深度验签不成立。
- 自动更新沿用 app 当前路径。父目录不可写（只读卷、某些标准用户的 `/Applications`）时不尝试
  提权，设置页直接给出失败原因，用户仍可打开 GitHub 发布页手动安装。

## 天光分段 / 24 Hour Wallpaper 导入（1.2）

24 Hour Wallpaper / Sunshift 那套：一组图按日出/白昼/日落/夜晚均分到当天太阳窗口。
HourGlow 原先只有 clock + 日出/日落偏移，张数要手填时段，窗口也不会随晨昏长度变。

- [x] `Solar.events`：同一套 NOAA 迭代，额外给出航海晨光（−12°）和民用黄昏（−6°）；
      高纬给不出晨昏时回退到官方日出/日落
- [x] `Trigger.solarPhase { phase, index, count }`：存张数而不是钟点
- [x] `TimeMap`：日出窗口 = 航海晨光 → 日出 + (日出−晨光)/3；
      日落窗口 = 日落 − (黄昏−日落)/3 → 民用黄昏；每段按 count 等分
- [x] `SceneImport`：认 `01_sunrise_1.heic`、`sunrise_1.heic`、morning/evening 别名，
      以及 `.sundialScene/images/5120x2880/`（多分辨率留最大的）；否则按文件名顺序均分成四段
- [x] 各段张数可以不同（4 张日出 + 6 张白昼 + 4 张日落 + 5 张夜晚）
- [x] CLI `import <文件夹>`；面板 ⋯ 菜单「导入 24 小时壁纸…」
- [x] 常用城市离线表 + 地点页搜索（中国全境都是 Asia/Shanghai，时区推断永远落在上海）
- [x] `Tests/ImportCheck` 离线覆盖文件名、多分辨率、均分；`modelcheck` 覆盖窗口与 Codable

### 踩到的坑（别再踩一次）

- 窗口必须每天重算。用固定「日出后 20 分」近似 3 张日出，冬天晨光变短就会对不齐。
- 夜晚最后几张的 `fireDate` 落在次日凌晨，靠 Resolver 现成的 ±1 天展开接住，
  不要给 solarPhase 再套一层偏移锚点。
- 文件名用 token 匹配，不要 `contains("day")`：`sunday.heic` 会被误伤。
- 24 Hour Wallpaper 把同一张图按分辨率放在子目录里，按 basename 去重，留像素最多的那份。
- 地区是调度的一部分，不是设置里的附录。时间轴右上角那颗胶囊进「选择地区」；
  空搜时中国 / 海外分段，选完回到时间轴看今天的切换时刻。
- 菜单栏面板点 ⋯ 的同时会把自己关掉。立刻 `NSOpenPanel.runModal` 会被一起取消，
  对话框里「导入」像坏了。要等面板收完，临时把 `activationPolicy` 改成 `.regular`，
  并且允许选文件、文件夹和 `.sundialScene`，不能只许选目录。

## 环境速查

```
壁纸配置   ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
aerial 库  ~/Library/Application Support/com.apple.wallpaper/aerials/
项目目录   ~/documents/programming/HourGlow/
引擎配置   ~/Library/Application Support/HourGlow/schedule.json   # HOURGLOW_HOME 可整体改道
引擎状态   ~/Library/Application Support/HourGlow/state.json   # 上次写了哪张
单实例锁   ~/Library/Application Support/HourGlow/run.lock
常驻       ~/Library/LaunchAgents/app.hourglow.agent.plist
守护日志   ~/Library/Logs/HourGlow.log
更新日志   ~/Library/Logs/HourGlow-Updater.log
更新缓存   ~/Library/Caches/HourGlow/Updates/
临时方案   已不存在（曾经是 ~/.local/bin/tahoe-wallpaper + com.bobby.tahoe-wallpaper）
构建验证   swiftc -O -parse-as-library main.swift -o Probe    # 已验证可行
```

```
./build.sh                    # CLI + 各验证靶子 + panelshot + HourGlow.app
open build/HourGlow.app       # 菜单栏 app（M3）
./build/panelshot ~/Desktop   # 把三个页面画成 PNG（固定时刻那一栏另出一张），改版式时对照
./build/enginecheck           # 引擎决策矩阵与定时排期
./build/importcheck           # 24 Hour Wallpaper 文件名与导入
./build/updatecheck           # 更新版本、Release 解析与 SHA-256
./build/hourglow-cli run      # 前台常驻，Ctrl-C 退出（和 app 抢同一把 EngineLock）
./build/hourglow-cli status   # 上次写了什么、现在是不是还是那张

# 只影响 app 自己那个 bundle，CLI 问不出结果
build/HourGlow.app/Contents/MacOS/HourGlow --login-item status   # 开机自启：status|on|off
build/HourGlow.app/Contents/MacOS/HourGlow --locate              # 定位一次，只打印不写配置

# 一次性配置目录，端到端实测用它，不碰真配置
HOURGLOW_HOME=/tmp/hg ./build/hourglow-cli list
```

plist 结构、Provider 格式、四个 assetID 见 `MVP.md` 第 2 节。
