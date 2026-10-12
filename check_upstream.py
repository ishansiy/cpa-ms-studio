#!/usr/bin/env python3
"""检测三个上游的最新稳定版，若变化则更新 Dockerfile 的版本 ARG + sha256 + 注释。

分级自动更新策略（避免无脑全追引入破坏）：
  - CPA (CLIProxyAPI)：自动追 latest。发版极频繁（一天多版），v8 minor 向后兼容
    （OMC 文档：requires CPA v8.0.0+，早期 v8 拒新 root 段而历史别名两版都收，
    无需整文档迁移），核心网关 bugfix/安全更新价值最高。
  - OMC (Oh My CPA)：自动追，但仅 minor/patch，不跨 major（v0->v1 可能破坏）。
  - CodexComp：不自动更新（保持 Dockerfile 内版本）。它是经自定义 C ABI v1
    (dlopen) 加载的单 .so 插件，上游 2026-07 后停更，自动追收益低且 ABI 有耦合风险。

只依赖标准库 + GitHub 公开 API（releases/latest 端点），无需 token。

用法：
  python3 check_upstream.py            # 检测并更新 Dockerfile，有变更退出码 0，无变更退出码 10
  python3 check_upstream.py --dry-run  # 只报告，不改文件

退出码：0=有变更已更新 / 10=无变更 / 1=出错
"""
import argparse
import json
import os
import re
import sys
import urllib.request

DOCKERFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Dockerfile")

# 三个上游组件定义
COMPONENTS = {
    "CPA": {
        "repo": "router-for-me/CLIProxyAPI",
        "arg_version": "CPA_VERSION",
        "arg_sha": "CPA_SHA256",
        "asset": "CLIProxyAPI_{ver}_linux_amd64.tar.gz",  # {ver} 去 v 前缀
        "strip_v": True,
        "auto": "latest",
        "comment_marker": "#   CPA ",
    },
    "OMC": {
        "repo": "WizisCool/oh-my-cpa",
        "arg_version": "OMC_VERSION",
        "arg_sha": "OMC_SHA256",
        "asset": "oh-my-cpa_{ver}_linux_amd64.tar.gz",
        "strip_v": True,
        "auto": "minor",  # 不跨 major
        "comment_marker": "#   OMC ",
    },
    "CODEXCOMP": {
        "repo": "uf-hy/cpa-plugin-codexcomp",
        "arg_version": "CODEXCOMP_VERSION",
        "arg_sha": "CODEXCOMP_SHA256",
        "asset": "codexcomp_{ver}_linux_amd64.zip",
        "strip_v": True,
        "auto": "manual",  # 不自动更新
        "comment_marker": "#   插件 ",
    },
}


def gh_latest(repo):
    """返回 (tag_name, assets)。assets 是 [(name, browser_download_url)]。"""
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "cpa-ms-studio-updater"})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode())
    assets = [(a["name"], a["browser_download_url"]) for a in d.get("assets", [])]
    return d["tag_name"], assets


def sha256_of(url):
    req = urllib.request.Request(url, headers={"User-Agent": "cpa-ms-studio-updater"})
    import hashlib
    h = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=120) as r:
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def semver(tag):
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)", tag)
    return tuple(int(x) for x in m.groups()) if m else None


def should_update(comp, cur, new):
    if comp["auto"] == "manual":
        return False
    if cur == new:
        return False
    if comp["auto"] == "minor":
        cs, ns = semver(cur), semver(new)
        if cs and ns and ns[0] != cs[0]:
            return False  # 跨 major 不自动追
    return True


def current_version(text, arg):
    # Dockerfile 里是 "ARG <NAME>=<value>"，行首有 ARG 前缀
    m = re.search(rf"^ARG {arg}=(\S+)$", text, re.M)
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    text = open(DOCKERFILE, encoding="utf-8").read()
    changed = []
    report = []

    for name, comp in COMPONENTS.items():
        cur = current_version(text, comp["arg_version"])
        try:
            tag, assets = gh_latest(comp["repo"])
        except Exception as e:
            report.append(f"[{name}] 查询失败: {e}")
            continue
        new = tag
        do = should_update(comp, cur, new)
        report.append(f"[{name}] auto={comp['auto']} 当前={cur} 最新={new} -> {'更新' if do else '跳过'}")

        if not do:
            continue

        # 找 asset 并算 sha256
        asset_name = comp["asset"].format(ver=new[1:] if comp["strip_v"] else new)
        hit = [u for (n, u) in assets if n == asset_name]
        if not hit:
            report.append(f"[{name}] 找不到 asset {asset_name}，跳过")
            continue
        new_sha = sha256_of(hit[0])

        # 更新 ARG 行（行首有 ARG 前缀）
        text = re.sub(rf"^ARG {comp['arg_version']}=\S+$", f"ARG {comp['arg_version']}={new}",
                      text, flags=re.M)
        text = re.sub(rf"^ARG {comp['arg_sha']}=\S+$", f"ARG {comp['arg_sha']}={new_sha}",
                      text, flags=re.M)
        # 更新顶部注释块里的版本与 sha 记录
        if cur:
            text = re.sub(rf"({re.escape(comp['comment_marker'])}.*?releases/tag/){re.escape(cur)}",
                          rf"\g<1>{new}", text)
        changed.append(f"{name}: {cur} -> {new} (sha {new_sha[:12]}…)")

    for line in report:
        print(line)

    if not changed:
        print("无变更")
        return 10

    if args.dry_run:
        print("(dry-run，未写文件) 变更：")
        for c in changed:
            print("  ", c)
        return 0

    open(DOCKERFILE, "w", encoding="utf-8").write(text)
    print("已更新 Dockerfile：")
    for c in changed:
        print("  ", c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
