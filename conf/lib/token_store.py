#!/usr/bin/env python3
"""分享令牌存储 —— 服务端和 CLI 共用同一个写入口。

## 为什么要单独一个文件

mihomo 和 sing-box 两边都有同一个缺陷: 服务端用 flock 包住
read-modify-write, 但面板 CLI 的 create/toggle/regen 直接裸写、不持锁。
两边同时改一个 token 时, 谁后写谁赢 —— 表现是"刚在面板点了停用, 服务端
又把它启用了", 而两边都没有报错。

所以令牌的所有写入必须走同一个入口。这里把锁和原子写收在一处, 服务端
和 share.sh 都调它, 从根上消掉竞态而不是靠约定。

## 并发为什么要两层锁

只用 threading.Lock: 多进程时(另一个脚本改令牌)不防竞态。
只用 flock: **flock 锁的是 open file description**, 同一进程内多个线程若
共享同一个 fd, 后者根本不会阻塞。mihomo 实测过 12 并发抢 1 次额度全部
放行, 超发 12 倍。

所以线程锁自己拿, 文件锁每次调用重新 open 一次 fd。
"""

import contextlib
import errno
import fcntl
import json
import os
import threading
import time

_thread_lock = threading.Lock()


@contextlib.contextmanager
def locked(share_dir):
    """两层锁: 进程内线程锁 + 跨进程文件锁。"""
    os.makedirs(share_dir, exist_ok=True)
    with _thread_lock:
        # 每次重新 open —— 见模块注释, 共享 fd 时 flock 不阻塞
        fd = os.open(os.path.join(share_dir, ".share.lock"),
                     os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def token_path(share_dir, token):
    return os.path.join(share_dir, "tokens", f"{token}.json")


def valid_token(token):
    """形状校验, 同时挡路径穿越。

    文件名是 token, 所以 token 里出现 ../ 或 / 就会让路径跳出 tokens/。
    """
    return bool(token) and all(c.isalnum() or c in "-_" for c in token)


def read(share_dir, token):
    p = token_path(share_dir, token)
    if not os.path.exists(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:  # noqa: BLE001
        # 坏文件返回带标记的 dict 而不是 None —— 否则"文件坏了"和
        # "令牌不存在"变成同一件事, 列表页会静默少一行。
        return {"_broken": True, "token": token}


def write(share_dir, token, meta):
    """原子写。tmp + fsync + rename。"""
    os.makedirs(os.path.join(share_dir, "tokens"), exist_ok=True)
    p = token_path(share_dir, token)
    tmp = f"{p}.tmp.{os.getpid()}"
    # token 字段始终以文件名为准 —— 文件名就是 token 的唯一真源,
    # 内容里的 token 字段写错了不该让列表页认不出这一行。
    meta = dict(meta)
    meta["token"] = token
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, p)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def update(share_dir, token, mutate, default=None):
    """锁内 read-modify-write。

    mutate 收到当前 meta(不存在时是 default) 并原地修改, 返回 False
    表示放弃写入。返回最终 meta, 或 None(令牌不存在且无 default)。

    这是**唯一**该改令牌的地方 —— 服务端的扣次和 CLI 的启停/改次数都走它。
    """
    with locked(share_dir):
        cur = read(share_dir, token)
        if cur is None:
            if default is None:
                return None
            cur = dict(default)
        elif cur.get("_broken"):
            cur = dict(default or {})
        if mutate(cur) is False:
            return cur
        cur["updated_at"] = int(time.time())
        write(share_dir, token, cur)
        return cur


def consume_once(share_dir, token):
    """扣一次额度, 返回 (是否允许, 原因)。

    判定和扣减必须原子 —— 拆成两步的话, 并发下会超发。
    调用方拿到 True 就**必须**用这个 meta 发响应; 拿到 False 不得发 body。
    """
    reason = {}

    def _mutate(m):
        if not m.get("enabled", True):
            reason["r"] = "disabled"
            return False
        now = int(time.time())
        exp = int(m.get("expires_at", 0))
        if exp and now > exp:
            reason["r"] = "expired"
            return False
        used = int(m.get("used_count", 0))
        maxu = int(m.get("max_uses", 0))
        if maxu and used >= maxu:
            reason["r"] = "used up"
            return False
        # 扣减放在确认要发 body 之后、真正保存之前 —— 但仍在本函数内原子完成。
        # 顺序: 判定 → 构造载荷(函数外) → 回到这里扣。
        # 见 share_server 里 build 与 consume 的调用次序说明。
        m["_pending"] = True
        return True

    # 第一步: 只判定, 不扣
    with locked(share_dir):
        cur = read(share_dir, token)
        if cur is None or cur.get("_broken"):
            return False, "not found"
        if not cur.get("enabled", True):
            return False, "disabled"
        now = int(time.time())
        exp = int(cur.get("expires_at", 0))
        if exp and now > exp:
            return False, "expired"
        used = int(cur.get("used_count", 0))
        maxu = int(cur.get("max_uses", 0))
        if maxu and used >= maxu:
            return False, "used up"

    # 第二步: 载荷构造成功后, 锁内扣减并重判(构造期间可能被别人用掉了)
    with locked(share_dir):
        cur = read(share_dir, token)
        if cur is None or cur.get("_broken"):
            return False, "not found"
        now = int(time.time())
        exp = int(cur.get("expires_at", 0))
        if exp and now > exp:
            return False, "expired"
        used = int(cur.get("used_count", 0))
        maxu = int(cur.get("max_uses", 0))
        if maxu and used >= maxu:
            return False, "used up"
        cur["used_count"] = used + 1
        cur["last_used_at"] = now
        cur.pop("_pending", None)
        write(share_dir, token, cur)
        return True, "ok"


def status_of(meta, now=None):
    """状态判定。列表页和服务端用同一个函数, 避免两处实现漂移。

    显式优先级: 停用 > 过期 > 用尽 > 有效。
    """
    now = int(now or time.time())
    if not meta.get("enabled", True):
        return "停用"
    exp = int(meta.get("expires_at", 0))
    if exp and now > exp:
        return "过期"
    used = int(meta.get("used_count", 0))
    maxu = int(meta.get("max_uses", 0))
    if maxu and used >= maxu:
        return "用尽"
    return "有效"


def list_all(share_dir):
    """列出全部令牌。坏文件也返回, 带 _broken 标记。

    一律用文件名回填 token —— 早期写入的记录里可能没有 token 字段,
    少了这行回填, 列表页就会出现一整行空白 (TOKEN 列是空的)。
    """
    import glob
    out = []
    for f in sorted(glob.glob(os.path.join(share_dir, "tokens", "*.json"))):
        tok = os.path.basename(f)[:-5]
        m = read(share_dir, tok)
        if m is None:
            m = {"_broken": True, "token": tok}
        else:
            m["token"] = tok
        out.append(m)
    return out