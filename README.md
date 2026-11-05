# Fxxking Work

> 仓库：https://github.com/cailish-0425/Fxxking_Work 。假日数据来自 [wrfly/holidays](https://github.com/wrfly/holidays)。

一个 macOS 菜单栏应用。上班的每一秒，公司都在往你账上打精神损失费——这个应用把这笔钱实时算出来。

菜单栏常驻一个数字，点开能看到今日、本月、本年三条进度：钱赚到了百分之几，金额是多少，今天还剩多久刑期。

## 功能

- **实时计费**：菜单栏每秒刷新，弹窗打开时按 0.1 秒跳动
- **敲木鱼**：计薪时弹窗里的木鱼每 0.8 秒被敲一记，不计薪就停手；鼠标移上去指针变木槌，可以自己敲
- **三级进度**：今日 / 本月 / 本年的百分比与金额
- **可配置工时**：每周哪几天上班、上下班时间、午休时段（午休不计薪）
- **国家与货币**：从 ISO 地区列表里选，货币默认跟着国家走，也可以单独改
- **自动排除法定假日**：拉取当年和次年的公共假日，本地缓存，断网可用
- **自动识别调休补班**：中国、俄罗斯、越南这类会把周末挪成工作日的安排，从数据源里直接算出来
- **手动补丁**：额外休息日（年假、连休）和调休上班日，优先级高于自动数据
- **摸鱼战报**：锁屏离开再回来时，告诉你这段时间公司照付了多少钱
- **13 薪 / 14 薪**：年终奖按进度平摊到全年
- **菜单栏显示内容可选**：今日金额、今日百分比、本月金额、本月百分比、本年百分比
- **开机自启**：通过 `SMAppService` 注册登录项
- **五种语言**：英、中、法、俄、西，默认跟随系统，也可以在设置里单独指定，切换即时生效无需重启

## 升级说明

- 应用更名为「Fxxking Work」，bundle 标识已变更：此前开启过开机自启的用户，升级后请在「显示」设置中重新开启。

## 安装

需要 macOS 14 或更高版本。安装包是 arm64 + x86_64 通用二进制，Apple Silicon 和 Intel 都能用，不需要额外装 Swift 运行时或 Xcode。

### 下载现成的

暂未提供独立安装包，请使用下面的「从源码构建」。

### 从源码构建

需要 Xcode Command Line Tools（`xcode-select --install`）。本机编译的产物不带隔离标记，装完直接能用。

```bash
./Scripts/build-app.sh --install
```

`--install` 会把产物拷进 `/Applications` 并打开。去掉这个参数则只在 `dist/` 下生成 `Fxxking Work.app`。构建脚本会尽量产出通用二进制，另一架构编译失败时自动降级为仅本机架构。

首次运行后，从菜单栏图标进入「设置…」填写薪资和作息。

界面语言默认跟随系统，所以在英文系统上装完看到的是英文。想固定用某种语言的话，去「显示」页改「界面语言」。

## 在其他机器上运行

产物是 arm64 + x86_64 的通用二进制，只链接系统自带的框架和 `/usr/lib/swift`，**目标机器不需要安装 Swift 运行时或 Xcode**。唯一的硬性要求是 macOS 14 或更高。

麻烦的地方在 Gatekeeper：构建脚本只做了 ad-hoc 临时签名，没有 Developer ID 也没有公证（notarization）。签名本身有效，但 `spctl` 会判定 `rejected`。三种做法：

### 一、对方自己从源码构建（最省事）

对方装了 Command Line Tools 就行。本机构建出来的东西不带隔离属性，不会有任何提示。

```bash
./Scripts/build-app.sh --install
```

### 二、拷贝构建好的包

```bash
./Scripts/build-app.sh --zip     # 生成 dist/Fxxking Work.zip，约 500 KB
```

必须用脚本里的 `ditto` 打包，普通 `zip` 命令不保留 macOS 元数据，解压后签名会失效。

对方拿到后，如果是**通过网络传的**（下载、微信、邮件、AirDrop），文件会被打上 `com.apple.quarantine`，双击会弹「Apple 无法验证此 App 是否包含恶意软件」。两种解法：

```bash
# 命令行：拖进 /Applications 后执行
xattr -dr com.apple.quarantine "/Applications/Fxxking Work.app"
```

或者走图形界面：双击被拦后，到「系统设置 → 隐私与安全性」，下滑找到那条拦截记录，点「仍要打开」。

用 U 盘之类的本地介质拷贝则不会有隔离属性，可以直接运行。

### 三、发一个 GitHub Release

`.github/workflows/release.yml` 负责这件事：推一个 `v` 开头的 tag，CI 就在 macOS runner 上跑断言、校验各语言文案、构建通用二进制、打包，然后连同 SHA-256 一起发布。

```bash
git tag v1.0.1 && git push origin v1.0.1
```

Release 说明取自 `.github/release-notes.md`，改这个文件就能改所有后续版本的说明。在 Actions 页面手动触发（workflow_dispatch）则只构建、把产物传成 artifact，不会发版，适合验证流水线。

### 四、正式签名并公证（要给不认识的人用就得这样）

需要 Apple Developer Program 会员资格（每年 99 美元）。有了 Developer ID 证书之后：

```bash
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: 你的名字 (TEAMID)" "dist/Fxxking Work.app"
ditto -c -k --sequesterRsrc --keepParent "dist/Fxxking Work.app" upload.zip
xcrun notarytool submit upload.zip --apple-id <你的账号> --team-id <TEAMID> --wait
xcrun stapler staple "dist/Fxxking Work.app"
```

公证并 staple 之后，任何 Mac 双击都不会有提示。注意 `--options runtime`（Hardened Runtime）是公证的前提条件。

## 摸鱼战报

锁屏离开工位，回来解锁时会收到一条系统通知，告诉你这段时间公司照付了多少精神损失费。可以在「设置 → 显示」里关掉。

只算真正计薪的部分：午休锁屏是 0，下班后锁屏是 0，周五下班锁到周一早上也只算周五那一小截和周一那一小截。锁屏跨月的话，两个月各按自己的工作日数折算日薪，因为日薪是月薪除以当月工作日数，二月和三月并不一样。计薪时间不足一分钟的不提示，免得锁屏几十秒就被打扰一次。

实现上有几个值得记一笔的点。macOS 没有公开的锁屏事件接口，用的是 `com.apple.screenIsLocked` 和 `com.apple.screenIsUnlocked` 两个分布式通知，它们没有出现在任何头文件里，但长期稳定，是事实标准。沙盒应用收不到分布式通知，本应用没开沙盒所以不受影响。

通知只在事件发生那一刻投递，如果应用是在屏幕已经锁着的时候启动的就什么都收不到，所以初始化时会再用 `CGSessionCopyCurrentDictionary()` 查一次当前状态兜底——锁屏时字典里才会出现 `CGSSessionScreenIsLocked` 这个键。这种情况下锁屏的真实时刻已经无从得知，代码从「现在」开始计时，宁可少报也不凭空多报。

提示走系统通知，但面板里同时留一张卡片。系统通知可能因为没授权、开着专注模式而发不出去，那时候卡片就是兜底，功能不会因此静默失效。

卡片整张都是关闭按钮，点哪儿都行。右上角的叉留着当"可关闭"的记号，但它只是画上去的，真正接管点击的是外面那个按钮——对一个看完就该消失的提示来说，没必要要求用户去命中一个 14pt 见方的小目标。

## 界面语言

内置英语、简体中文、法语、俄语、西班牙语，也就是联合国六种官方语言里除阿拉伯语之外的五种。阿拉伯语需要 RTL 布局，等界面在 LTR 语言下站稳了再说。

源语言是英文，其余四种是它的翻译，缺失的条目会自动回退到英文而不是显示成空白。

语言和地区是两件事，改语言不会动地区。中国用户把界面切成英文之后，金额仍然按本地习惯显示成 `¥1,234.50` 而不是 `CN¥1,234.50`，星期从周一还是周日开始、用 12 还是 24 小时制也都跟着系统走。实现上只替换 `Locale` 的语言码和字形，其余成分原样保留——整个换掉 `languageComponents` 会把地区一起冲掉，这是个很容易踩的坑。

翻译文件在 `Resources/<语言>.lproj/` 下：

- `Localizable.strings` 存普通条目，key 是语义化的（`menu.fact.remaining`）而不是英文原文，这样两处相同的英文可以在别的语言里分开翻译
- `Localizable.stringsdict` 存带数量的条目

复数是这里唯一真正棘手的部分，各语言的类别数量不一样：中文只有 `other`；英语、法语、西班牙语是 `one` / `other`，但分界线不同（法语的 0 算单数，西班牙语的不算）；俄语要四档，`one` 管 1/21/101，`few` 管 2–4/22–24，`many` 管 0 和 5–20 以及 11–14 这类例外。少写一档不会报错，只会在某个数量区间悄悄退化成别的形式，所以 `check-localization.py` 会按语言核对类别是否齐全。

这两种文件运行时由 CFBundle 直接读取，不需要编译，所以手工组装的 `.app` 也能用上完整的本地化，包括复数规则。

要加一门语言：建 `Resources/xx.lproj/`，复制两个文件翻译，在 `AppLanguage` 里加一个 case，再把该语言需要的复数类别登记进 `check-localization.py` 的 `REQUIRED_PLURAL_CATEGORIES`。构建脚本会自动把所有 `.lproj` 打进 bundle。

## 钱是怎么算的

一切从**月薪**出发，年薪会先除以「一年发几个月」换算成月薪。

```
本月工作日 N   = 当月满足「每周上班日」且不是假日的天数（调休上班日算进来）
日薪           = 月薪 / N
每日计薪秒数 S = (下班 - 上班 - 午休) × 60
秒薪           = 日薪 / S
```

- **今日进度** = 今天已经过去的计薪秒数 / S，午休那段不累加，下班后封顶 100%（加班不加钱）
- **本月进度** = (本月已完整过去的工作日 × 日薪 + 今日已赚) / 月薪，月内最后一个工作日下班时正好 100%
- **本年进度** = (已过整月 × 月薪 + 本月已赚) / (月薪 × 12)，年度金额按这个比例乘以年薪，所以 13 薪的年终奖也是随进度慢慢到账的

休息日的日额度为 0，不产生收入，但已经赚到的月度和年度金额不会回退。

## 关于假日数据

数据来自 [github.com/wrfly/holidays](https://github.com/wrfly/holidays)，225 个国家和地区、2024–2027 年，每个国家每年一个 CSV：

```
https://raw.githubusercontent.com/wrfly/holidays/refs/heads/main/CN/2026.csv
```

应用拉取当年和次年两份，缓存在 `~/Library/Application Support/Fxxking_Work/holidays/`，一年一个文件。某一年还没有数据（例如 2028）会返回 404，按「这一年没有」跳过而不是整体失败。

### 缓存为什么还需要校验

直觉上法定假日定了就不会变，缓存下来永久有效就行。但应用请求的是**当年和次年**，从不请求过去的年份，而次年的数据往往是不完整的：写这段时的 `CN/2026.csv` 有 27 行、其中 6 行带 `Compensated by`，`CN/2027.csv` 只有 18 行、**一行调休都没有**。中国的放假安排由国务院办公厅在前一年 11 月左右才公布，在那之前数据源里只能先把节日日期占上。

如果把次年数据当成最终版永久缓存，官方公布之后应用就再也拿不到那批调休日，整个 2027 年的补班周六都会被算成休息日，工资和进度全错。此外法定假日本身也会临时增减——英国 2022 年女王葬礼提前十天才宣布放假，美国 2021 年新增 Juneteenth 时法案签署距首次放假只有两天。

所以缓存分两种情况：

- **已经过去的年份**：官方安排定死了，本地有副本就直接用，一个请求都不发。
- **当年和次年**：带 `If-None-Match` 做条件请求。内容没变时 GitHub 返回 `304`、响应体 0 字节，所以每次启动都校验一遍的代价可以忽略，数据一更新马上就能拿到。

设置里的「刷新」按钮走 `force`，不带 ETag 直接全量重取。

过滤「包含地方性假日」是解析时做的，不影响缓存，所以切换那个开关不会重新下载。

假期是完整的连休段而不只是首日——中国 2026 年是 24 天，春节 2/16–23、国庆 10/1–7 都是整段。

### 哪些算放假

CSV 的 `type` 列有十种取值，另外还有空值，按三类处理：

| 类别 | `type` | 是否算放假 |
| --- | --- | --- |
| 全国 | `National` / `Public` / `Federal` / `Bank` / `Statutory` / `Official Holiday`，以及**空值** | 算 |
| 局部 | `Regional Holiday`（只在某些地区）、`Government Holiday`（只有公务员） | 跟着「包含地方性假日」开关 |
| 不放假 | `Not A Public Holiday` | 不算 |

**空值必须按全国性假日处理**：有 2040 行、涉及 35 个国家（伊朗、波兰、芬兰、希腊、马耳他等）的 `type` 整列为空，而那些行写的是 New Year's Day、Christmas Day 这类正经法定假日。当成"不是假期"的话，这些国家会一天假都没有。同理，未知的新取值也默认按全国性处理。

局部假日默认不算：印度 2026 年全国假日 4 天，算上地方性的有 140 天，全收会得出"你几乎不用上班"的结论。

### 调休补班怎么来的

`comments` 列里的 `Compensated by …` 给出了被挪成上班日的那一天，中国式调休因此不用再手工录入。这些日子会在设置里以「来自数据源」标出，可以整体关掉。

解析上有两个坑：

**写法不统一。** 数据集里至少出现过 `Sat Feb 14`、`Sat. Dec 30`、`Sat, Jan. 10`、`Sat. 23 May`（日在月前）、`Sat 25 April`（月份全称）、`Sat Sept 2`（四字母缩写）、`Aug 3`（不写星期几）、`Sat Dec 29 2024`（带年份）等形式，所以是把 token 拆开各认各的，而不是套固定格式。

**备注里通常不写年份**，而补班日可能落在假期的上一年（阿塞拜疆 2024-01-04 的假由 2023-12-30 补班）。做法是默认取同一年，只有当同年的那一天离假期超过半年时，才认为是跨年引用，改用星期几到相邻年份里挑。

星期几只能这样用，**不能拿来做硬校验**：中国 2024 年写的是 `Sat. Feb 4`，而 2 月 4 日其实是周日——日期是对的，星期几标错了。若严格校验，这两天正确的调休日反而会被丢掉。

### 优先级与手动补丁

判定某天上不上班，从高到低：

1. 手动填的「调休上班日」→ 上班
2. 手动填的「额外休息日」（年假、公司假期）→ 休息
3. 数据源的法定假日 → 休息
4. 数据源的调休补班 → 上班
5. 每周上班日设置

所选地区在数据源里没有条目时，界面会明确提示，此时假日全靠手动维护。

## 开发

```bash
./Scripts/run-checks.sh          # 跑核心逻辑的断言（172 项）
python3 Scripts/check-localization.py  # 比对代码用到的 key 和各语言资源
./Scripts/build-app.sh           # 只构建，不安装
./Scripts/build-app.sh --zip     # 额外产出可分发的压缩包
./Scripts/format.sh              # 按 .swift-format 整理代码
./Scripts/format.sh --check      # 只检查格式，不改动
```

`Checks/main.swift` 是一组不依赖 XCTest 的断言，覆盖计薪时长、工作日判定、调休优先级、日月年进度、13 薪换算、除零边界、CSV 解析（引号、转义、CRLF、列序无关）、假期类型映射、各种写法的调休备注、配置的向后兼容解码，以及界面语言与地区的隔离。

`check-localization.py` 单独存在是因为漏一个 key 不会让编译失败，只会让界面上冒出一串 `menu.fact.remaining`。它会报告源语言缺失的 key（视为错误）、其他语言未翻译的条目（视为待办）、没被引用的死资源，以及复数类别不全的条目。注意它只能识别字面量形式的 `Loc.t("...")`，用变量拼 key 会让它看不见。

代码在 Swift 6 语言模式下编译，严格并发检查零警告。日期键和货币格式化都不使用 `DateFormatter` / `NumberFormatter` 的共享缓存，因此没有全局可变状态。

算钱的部分不知道当前是什么语言：`WorkStatus.dayOff` 存的是 `DayOffReason` 枚举而不是拼好的句子，翻译发生在展示层，所以用户中途切换语言时状态文字会跟着变，断言也不必和某种语言绑定。

### 构建为什么不走 swift build

仓库里有一份标准的 `Package.swift`，`swift build` 可以正常工作。但只装了 Command Line Tools 的机器上，SwiftPM 可能因为 `PackageDescription.swiftmodule` 和 `libPackageDescription.dylib` 来自不同版本而无法解析任何清单，链接期报 `Undefined symbols: PackageDescription.Package.__allocating_init`。遇到这种情况装一个官方工具链即可：

```bash
brew install swiftly && swiftly init --assume-yes
```

`Scripts/build-app.sh` 不依赖 SwiftPM，它直接调用 `swiftc`（带 `-swift-version 6`）再手工组装 `.app`，所以两种环境下都能用，顺带产出通用二进制。

### 代码结构

```
Sources/Fxxking_Work/
  Fxxking_WorkApp.swift        MenuBarExtra + Settings 两个 Scene
  Models/
    Configuration.swift        全部配置项，宽松解码保证向后兼容
    SettingsStore.swift        UserDefaults 持久化
    EarningsTicker.swift       1 秒定时器，驱动菜单栏标题
    CountryCatalog.swift       国家和货币列表，货币从 Locale 反推
    PublicHoliday.swift
  Services/
    HolidayService.swift       拉取、缓存、离线回退
    GitHubHolidaysSource.swift CSV 解析、全国/地方性过滤、调休日期推断
    WorkCalendar.swift         工作日判定与统计
    EarningsEngine.swift       按天预计算，取快照是纯算术；也负责算任意区间的收入
    ScreenLockMonitor.swift    锁屏与解锁事件，附带 CGSession 状态兜底
    AwayNotifier.swift         解锁后的系统通知，发不出去就静默放弃
  Views/
    MenuContentView.swift      菜单栏弹窗
    SettingsView.swift         四个设置分页
  Support/
    Formatters.swift           金额、百分比、时长、时间点，全部带 locale
    Localization.swift         AppLanguage 与字符串查找，语言切换在这里
    DisplayNames.swift         枚举的展示名和吐槽文案，模型层因此不碰翻译
Resources/
  AppIcon.png                  1024 图标母版，各尺寸与 .icns 在构建时生成
  en.lproj/                    源语言
  zh-Hans.lproj/  fr.lproj/  ru.lproj/  es.lproj/
```

### 图标

仓库里只存 `Resources/AppIcon.png` 一张 1024×1024 母版，`build-app.sh` 用系统自带的 `sips` 和 `iconutil` 现场生成十个尺寸和 `AppIcon.icns`，所以不用把一堆尺寸的 PNG 提交进版本库。

换图标就替换这张母版，注意两点：内容要按 macOS 的网格放在 824×824 的圆角方形里、四周留 100px 透明边给系统投影用；四角必须是透明而不是白色，否则装到系统里会看到一个白方块。图案要挑轮廓厚实的，访达列表和「登录项」里只有 16×16，细长的形状到那个尺寸就糊成一团了。

菜单栏图标是另一回事，用的是 SF Symbol（`dollarsign.circle.fill`，在 `Fxxking_WorkApp.swift` 里），不走 `.icns`。系统符号会自动跟文字基线对齐、随菜单栏字号缩放、并适配深浅色和着色模式，换成自制图片这些都得自己处理。弹窗里的木鱼（`MenuContentView.swift` 中的 `MuyuView`）每 0.8 秒敲一记。

木鱼本体走图片素材。团鱼形木鱼的辨识特征——昂首缩尾的轮廓、头部正前方横开的鱼口、尾部盘绕的那一圈——用矢量图形拼到 44pt 见方全会糊成一坨，试过一版，出来像个笑脸土豆。素材加载用 `NSImage(named:)` 而不是 `Image("Muyu")`：后者只认资源目录（asset catalog），而这个 bundle 是构建脚本手工拼的，素材是散装 PNG，得走 AppKit 那条查找路径。和应用图标一样，仓库里只存一张母版 `Resources/Muyu.png`，构建时用 `sips` 缩一次。这里没按 `@2x` 约定拆两张：视图里总是显式给 `frame`，`NSImage` 的固有尺寸用不上，只要位图分辨率够高、缩放时是在降采样就行。拆两张反而会要求脚本里的点数跟着视图的 `frame` 走，改个大小得两头对齐。

木鱼多大由 `muyuZoom` 一个常量决定。内部所有坐标都按 68×76 的画布算好再统一缩放，所以调大小不用重算落槌点、抬槌高度和声波位置，它们之间的相对关系不会散；木槌光标也跟着这个数走。

木槌要独立升降，仍然是矢量画的，只做垂直运动——从正上方落在背部斜坡上，那是传统上真正敲击的部位。落点选在横向 60% 处：那儿的轮廓顶端离素材上沿只有 1.7pt，既避开了尾部的花纹，又省下抬槌需要的净空。柄稍稍右倾 13°，笔直的细杆加正圆的头看着像温度计，斜一点才像有只手在上头握着；倾斜以槌头底端为轴，所以敲击点不会跟着偏。

落槌用余弦缓入，起手慢、快碰到木鱼时才提速，是"敲"不是"砸"；抬槌占满周期剩下的部分，中间不留静止时间，动作才不显得赶。首尾都停在最高处，循环处接得上。

只有在计薪时才自动敲。午休、上班前、下班后、休息日和法定假日都停手，槌子悬在半空不动——没在赚钱，木鱼没道理自己响。判断直接用 `WorkStatus.isEarning`，和状态栏那颗绿点是同一个来源，不会出现一个说在赚钱另一个还在敲的矛盾。

鼠标移上去可以自己敲，这个不受计薪状态限制——想在假期敲两下积功德也随你。指针会变成一把木槌，同时自动敲击停下、画面里那根槌淡出——槌子到你手里了，留着就成了两根。点一下敲一记，木鱼压扁、声波荡开，和自动敲击共用同一条曲线：无论自动还是手动，动效都由"距上一记多久"驱动，只是这个时刻一个来自时钟、一个来自点击。移开鼠标就恢复自动。

光标图不是单独的素材，是把界面里那根木槌用 `ImageRenderer` 离屏渲染出来的，只渲染一次然后一直复用，手里这根和自动敲那根永远长得一样。热点钉在槌头底端的敲击点上，指哪儿敲哪儿。两处容易踩的地方：`ImageRenderer` 给出的 `NSImage` 尺寸按像素算，不改回点数的话 Retina 上光标会大一倍；`NSCursor.push()` 和 `pop()` 必须配对，弹窗要是在指针停在木鱼上时关掉，`onHover(false)` 不保证会来，所以 `onDisappear` 里还得再兜一次底，否则木槌光标会赖在屏幕上跟着鼠标跑。

它自带一个 30 帧的 `TimelineView(.animation)`，没有复用外层那 0.1 秒的节奏——落槌只有三分之一秒，10 帧下整个下落过程只剩三帧，看着是瞬移而不是敲。系统开了"减弱动态效果"就定格在举槌的姿势。TimelineView 只在弹窗可见时驱动，关掉即停。

`EarningsEngine` 只在配置、假日数据或日期变化时重建，之后每次 `snapshot(at:)` 都是常数时间的算术，所以每秒刷新也不费电。
