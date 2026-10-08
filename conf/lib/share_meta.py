#!/usr/bin/env python3
"""Xray 分享元数据 —— 节点的"分享侧身份", 与 Xray 配置分开存。

为什么分开
----------
分享链接需要的部分信息**不在** Xray 片段里:

  · REALITY 的 pbk (公钥) —— 片段里只有 privateKey, 公钥是推导出来的
  · VLESS 的 encryption   —— 服务端片段不写这个字段
  · 对外地址 / 显示名     —— 和内核配置无关

塞进片段也不行: Xray 的配置是严格 schema, 未知字段会让 `xray run -test`
直接失败。所以元数据走 sidecar, 片段保持内核能吃的干净格式。

这个文件就是"节点"和"分享"之间的边界。节点管理只管 conf/, 分享只管这里,
两边靠 tag 关联。
"""

import contextlib
import fcntl
import json
import os
import threading
import time

SCHEMA = 1

# 同进程内的并发保护。os.replace 是原子的, 但 save() 是 read-modify-write ——
# 两个线程各自 load 到旧值、各自改一个字段、先后 replace, 后一个会把前一个
# 的改动整个覆盖掉。实测表现是"刚改的 TTL 又变回去了", 而没有任何报错。
_THREAD_LOCK = threading.Lock()


@contextlib.contextmanager
def locked(meta_dir):
    """跨进程 + 同进程 两层锁。

    同进程那层必须是因为 flock 锁的是打开的文件描述符而不是进程: 同一进程
    里两个线程各自 open 同一个文件再 flock, 不会互相阻塞 (同一个 ofd)。
    两层都要, 少哪层都有并发窗口。
    """
    os.makedirs(meta_dir, exist_ok=True)
    with _THREAD_LOCK:
        lock_path = os.path.join(meta_dir, ".meta.lock")
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


# ---------------------------------------------------------------- 原子写
def _atomic_write(path, obj):
    """先写临时文件再 rename。

    直接写的话, 写到一半断电/被杀会留下半个 JSON —— 之后每次读都失败,
    表现是"分享全挂了", 而实际只是一个文件的写入被打断。
    """
    # 临时名必须每线程唯一。只用 pid 的话, 同一进程里的两个线程会算出同一个
    # 临时文件名, 于是互相 os.replace 对方的临时文件 —— 后一个 replace 拿到
    # FileNotFoundError, 直接抛到用户面前。实测 20 线程并发写就会触发。
    tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def meta_path(meta_dir, tag):
    return os.path.join(meta_dir, f"{tag}.json")


def load(meta_dir, tag):
    """读一个节点的分享元数据。文件不存在返回 None —— 那表示还没分享过。"""
    p = meta_path(meta_dir, tag)
    if not os.path.exists(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:  # noqa: BLE001
        # 坏文件不能拖垮整个列表, 但也不能假装它不存在 —— 返回 None 会让
        # "分享被撤销过" 和 "从没分享过" 变成同一件事, 于是撤销失效。
        return {"_broken": True, "tag": tag}


def save(meta_dir, tag, data):
    """写分享元数据。已有记录里未提供的字段保留 —— 分享的开关和次数不该
    被一次"改显示名"抹掉。"""
    with locked(meta_dir):
        return _save_locked(meta_dir, tag, data)


def _save_locked(meta_dir, tag, data):
    cur = load(meta_dir, tag) or {}
    if cur.get("_broken"):
        cur = {}
    cur.update({k: v for k, v in data.items() if v is not None})
    cur["schema"] = SCHEMA
    cur["tag"] = tag
    cur.setdefault("created_at", int(time.time()))
    cur["updated_at"] = int(time.time())
    _atomic_write(meta_path(meta_dir, tag), cur)
    return cur


def revoke(meta_dir, tag):
    """撤销分享。

    不是删文件 —— 删了就看不出"这个节点分享过又被撤了", 也没法恢复。
    置 enabled=False 并记下撤销时间。
    """
    with locked(meta_dir):
        cur = load(meta_dir, tag)
        if not cur or cur.get("_broken"):
            return False
        cur["enabled"] = False
        cur["revoked_at"] = int(time.time())
        _atomic_write(meta_path(meta_dir, tag), cur)
        return True


def purge(meta_dir, tag):
    """彻底删除 —— 节点本身被删掉时用。"""
    p = meta_path(meta_dir, tag)
    if os.path.exists(p):
        os.unlink(p)
        return True
    return False