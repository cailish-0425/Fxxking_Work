A macOS menu bar app that counts your salary as it accrues, second by second.
一个在菜单栏上按秒累计工资的 macOS 应用。

<!-- 每次发版记得更新这一节；下面的安装说明是长期不变的。 -->
## What's new in 1.1.0 / 1.1.0 更新内容

- **Slacking-off report.** Lock the screen, come back, and the app tells you how much
  the company paid you while you were away. Breaks, off-hours and non-workdays don't count.
  **摸鱼战报**：锁屏离开再回来，告诉你这段时间公司照付了多少钱。午休、下班时间和非工作日不计。
- **A wooden fish.** It gets struck once every 0.8 seconds while you're on the meter,
  and stops when you're not. Hover over it and the pointer becomes a mallet so you can
  strike it yourself.
  **敲木鱼**：计薪时每 0.8 秒被敲一记，不计薪就停手。鼠标移上去指针会变成木槌，可以自己敲。
- **An app icon**, and a more compact popover.
  加了**应用图标**，弹窗排版也更紧凑了。
- Holiday data is now cached per year — past years are frozen, the current and next year
  revalidate, because next year's makeup workdays are still provisional when first published.
  假日数据改为按年缓存：往年冻结，当年和次年会重新校验——次年的调休安排刚发布时还会变。

## Install / 安装

Requires **macOS 14 or later**. Universal binary, works on both Apple Silicon and Intel.
需要 **macOS 14 或更高版本**。通用二进制，Apple Silicon 和 Intel 都能用。

1. Download the `.zip` below and unzip it. / 下载下面的 `.zip` 并解压。
2. Drag `Fxxking Work.app` into `/Applications`. / 把 `Fxxking Work.app` 拖进「应用程序」。
3. Run this once — **it is required**: / 执行一次这条命令，**这步不能省**：

```bash
xattr -dr com.apple.quarantine "/Applications/Fxxking Work.app"
```

### Why that command? / 为什么要这一步？

This app is ad-hoc signed but **not notarized** — notarization requires a paid Apple
Developer account. macOS quarantines anything downloaded from the internet, so without
clearing that flag you'll get *"Apple could not verify this app is free of malware."*

应用做了 ad-hoc 临时签名，但**没有做公证**（公证需要付费的 Apple 开发者账号）。macOS 会给所有从
网上下载的文件打隔离标记，不清掉的话双击会提示「Apple 无法验证此 App 是否包含恶意软件」。

Prefer clicking? After the warning appears, go to **System Settings → Privacy & Security**,
scroll down and click **Open Anyway**.
不想敲命令的话：被拦截后打开「系统设置 → 隐私与安全性」，下滑点「仍要打开」。

Or build it yourself — locally built apps are never quarantined:
或者自己从源码构建，本机编译的产物不会被隔离：

```bash
cd Fxxking_Work && ./Scripts/build-app.sh --install
```

## First run / 首次使用

Click the menu bar item → **Settings…** to fill in your salary and working hours.
The interface follows your system language (English, 简体中文, Français, Русский, Español).

点菜单栏图标 → 「设置…」填写薪资和作息。界面语言默认跟随系统，也可以在「显示」页单独指定。

## SHA-256
