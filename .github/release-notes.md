A macOS menu bar app that counts your salary as it accrues, second by second.
一个在菜单栏上按秒累计工资的 macOS 应用。

<!-- 每次发版记得更新这一节；下面的安装说明是长期不变的。 -->
## What's new in 1.2.0 / 1.2.0 更新内容

- **Gross vs. net.** The gross mode keeps the original arithmetic. Net mode estimates
  take-home pay for mainland China (CNY) using the resident cumulative withholding method:
  pension, medical, unemployment, housing fund, tax, and what's left. It's an estimate from
  your own parameters, not a payslip.
  **税前 / 税后**：税前保持原有算法；税后按中国大陆工资薪金的累计预扣估算社保、公积金、个税和到手金额，属于按参数推算的估算，不是实际发放记录。
- **Editable social insurance.** Each of pension, medical, unemployment and housing fund has
  its own contribution **base**, which is either **auto** (taken from your salary within the
  regional floor and ceiling), **manual** (you type it, 0 included), or **not paid**. The
  medical item also has a separate fixed amount with the same three states. Personal **rates**
  are not tri-state: pension, medical and unemployment offer a reference rate (8% / 2% / 0.5%)
  plus a custom entry, and the housing fund offers regional presets (Beijing 5–12% in 1% steps,
  Shanghai 5 / 6 / 7%) plus custom. Changing region won't reset a rate you picked. Beijing and
  Shanghai carry official ranges; other cities use "custom".
  **社保参数可调**：养老、医保、失业、公积金的缴费基数可选自动沿用当前工资、手动填写（含 0）或不缴，医保固定额同样独立三态；个人比例用参考比例（8% / 2% / 0.5%）或住房公积金地区档位（北京 5–12%、上海 5/6/7%）加自定义，换地区不会重置已选比例；北京、上海为参考地区，其他城市选「自定义」。
- **Manual overtime.** Start and stop it yourself after hours; nothing is counted
  automatically. Paid overtime accrues second by second at 1×／2×／3× the pre-tax hourly rate
  and counts toward income. Unpaid overtime only shows the opportunity loss and never touches
  your pay or tax base.
  **手动加班计时**：下班后手动点开始／结束才计入；有偿按 1／2／3 倍税前时薪逐秒累计并计入收入，无偿只显示「赔了多少钱」，不动工资与税额。
- **Salary history.** Record a change with an effective date; days before it use the old
  salary, days after use the new one, and editing today no longer rewrites the past.
  **工资变更历史**：每条变更有生效日期，生效日前按旧工资、之后按新工资分段计薪，改今天不改过去。
- **Payday and pay period.** Set a cutoff day, a nominal payday and same-/next-month offset.
  The popover shows the next payday countdown and what you've earned in the current period.
  **发薪日与账期**：可设账期截止日、名义发薪日与当月／次月，主面板显示下次发薪倒计时和本账期已赚。
- **Privacy mode.** Amounts show as `••••` until you click them; click again to hide. No eye
  icon, no hover. Closing the window, switching apps, or restarting hides them again, and
  anything you revealed re-hides 30 seconds after you revealed it.
  **隐私模式**：金额默认显示为 `••••`，点击就地显示、再点隐藏，没有眼睛图标；关闭窗口、切换应用、重启即恢复隐藏，已显示的内容在点开 30 秒后自动恢复。
- **Light, dark, or follow the system.** The popover and settings window switch together and
  the choice survives a restart.
  **跟随系统／浅色／深色**：弹窗与设置窗口一起切换，重启保持。
- Holiday data is still cached per year — past years are frozen, the current and next year
  revalidate, because next year's makeup workdays are still provisional when first published.
  假日数据仍按年缓存：往年冻结，当年和次年会重新校验——次年的调休安排刚发布时还会变。

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

<!-- 下面这段不要手填：release.yml 发版时会 cat 本文件后自动追加下载 zip 的 checksum 代码块。
     本机构建的临时二进制 hash 不要写进来，这里保持只有标题即可。 -->
