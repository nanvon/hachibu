#!/usr/bin/env python3
"""把工作区文件的 mtime 恢复为 git 中最后修改该文件的提交时间。

GitHub Actions 的 checkout 会把所有文件写成当前时间，Xcode / SwiftPM 的
增量构建因此认为所有源码都变了，缓存里的编译产物等于作废。恢复 mtime 后，
未改动的文件与缓存构建时记录的时间一致，只重新编译本次真正改动的文件。
"""

from __future__ import annotations

import os
import subprocess


def git(*args: str, cwd: str) -> bytes:
    return subprocess.run(
        ["git", "-C", cwd, *args], check=True, capture_output=True
    ).stdout


def main() -> None:
    root = git("rev-parse", "--show-toplevel", cwd=os.getcwd()).decode().strip()
    tracked = {p for p in git("ls-files", "-z", cwd=root).split(b"\0") if p}

    # 一次 git log 从新到旧遍历，记录每个文件第一次出现时的提交时间。
    times: dict[bytes, int] = {}
    commit_time: int | None = None
    for token in git("log", "--format=%ct", "--name-only", "-z", "--no-renames", cwd=root).split(b"\0"):
        if not token:
            continue
        if token.isdigit() and len(token) >= 9:
            commit_time = int(token)
        elif commit_time is not None and token in tracked and token not in times:
            times[token] = commit_time

    # 合并提交、初始提交等少数文件在上面没有记录，逐个回退查询。
    for path in tracked - times.keys():
        out = git("log", "-1", "--format=%ct", "--", path.decode(), cwd=root).strip()
        if out:
            times[path] = int(out)

    for path, timestamp in times.items():
        full = os.path.join(root, path.decode())
        if os.path.exists(full):
            os.utime(full, (timestamp, timestamp))


if __name__ == "__main__":
    main()
