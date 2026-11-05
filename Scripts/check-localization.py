#!/usr/bin/env python3
"""比对代码里用到的 key 和各语言资源里定义的 key。

漏掉一个 key 不会让编译失败，只会让界面上冒出一串 "menu.fact.remaining"，
所以这件事必须由脚本盯着。
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"
SOURCE_LANGUAGE = "en"

USAGE = re.compile(r'Loc\.t\(\s*"([^"]+)"')
STRINGS_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', re.MULTILINE)

# CLDR 要求的复数类别。漏一档不会报错，只会在某个数量区间悄悄退化成别的形式，
# 比如俄语漏了 few 就会把「2 дня」说成「2 дней」。
REQUIRED_PLURAL_CATEGORIES = {
    "en": {"one", "other"},
    "zh-Hans": {"other"},
    "fr": {"one", "other"},
    "ru": {"one", "few", "many", "other"},
    "es": {"one", "other"},
}


def keys_used() -> dict[str, set[Path]]:
    found: dict[str, set[Path]] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        for key in USAGE.findall(path.read_text(encoding="utf-8")):
            found.setdefault(key, set()).add(path.relative_to(ROOT))
    return found


def plural_problems(lproj: Path, language: str) -> list[str]:
    """检查 .stringsdict 里每条复数条目是否写全了该语言需要的类别。"""
    stringsdict = lproj / "Localizable.stringsdict"
    if not stringsdict.exists():
        return []

    required = REQUIRED_PLURAL_CATEGORIES.get(language)
    if required is None:
        return [f"没有为 {language} 登记复数类别，请补进 REQUIRED_PLURAL_CATEGORIES"]

    with stringsdict.open("rb") as handle:
        entries = plistlib.load(handle)

    problems: list[str] = []
    for key, entry in entries.items():
        for name, spec in entry.items():
            if not isinstance(spec, dict):
                continue
            if spec.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType":
                continue
            present = {k for k in spec if k not in {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}}
            if missing := required - present:
                problems.append(f"{key} 的变量 {name} 缺少复数类别 {', '.join(sorted(missing))}")
    return problems


def keys_defined(lproj: Path) -> set[str]:
    defined: set[str] = set()

    strings = lproj / "Localizable.strings"
    if strings.exists():
        defined |= set(STRINGS_ENTRY.findall(strings.read_text(encoding="utf-8")))

    stringsdict = lproj / "Localizable.stringsdict"
    if stringsdict.exists():
        with stringsdict.open("rb") as handle:
            defined |= set(plistlib.load(handle).keys())

    return defined


def main() -> int:
    used = keys_used()
    languages = sorted(p for p in RESOURCES.glob("*.lproj") if p.is_dir())
    if not languages:
        print("FAIL  Resources 下没有任何 .lproj")
        return 1

    failures = 0
    source_keys = keys_defined(RESOURCES / f"{SOURCE_LANGUAGE}.lproj")

    for lproj in languages:
        language = lproj.name.removesuffix(".lproj")
        defined = keys_defined(lproj)

        missing = sorted(set(used) - defined)
        # 只有源语言必须字字齐全，其他语言缺了会回退到英文，属于待翻译而非错误。
        if missing and language == SOURCE_LANGUAGE:
            failures += len(missing)
            for key in missing:
                where = ", ".join(str(p) for p in sorted(used[key]))
                print(f"FAIL  [{language}] 缺少 key {key!r} — 用在 {where}")
        elif missing:
            print(f"TODO  [{language}] 有 {len(missing)} 条未翻译，运行时回退到英文：{', '.join(missing)}")

        unused = sorted(defined - set(used))
        if unused:
            print(f"WARN  [{language}] 有 {len(unused)} 条资源没被引用：{', '.join(unused)}")

        extra = sorted(defined - source_keys)
        if extra and language != SOURCE_LANGUAGE:
            failures += len(extra)
            for key in extra:
                print(f"FAIL  [{language}] key {key!r} 在源语言 {SOURCE_LANGUAGE} 里不存在")

        for problem in plural_problems(lproj, language):
            failures += 1
            print(f"FAIL  [{language}] {problem}")

        print(f"      [{language}] 定义 {len(defined)} 条，覆盖 {len(set(used) & defined)}/{len(used)} 个使用点")

    if failures:
        print(f"\n{failures} 项本地化问题")
        return 1

    print(f"\n{len(used)} 个 key 在 {len(languages)} 种语言下全部就位")
    return 0


if __name__ == "__main__":
    sys.exit(main())
