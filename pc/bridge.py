#!/usr/bin/env python3
# bridge.py v2 —— PC 侧 HTTP 桥
#   GET  /next      取一条待执行命令（取走即删）
#   POST /result    回传执行结果
#   GET  /hb        心跳
#   GET  /agent     下发最新代理脚本（自更新用）
#   GET  /ping      存活探测
#   GET  /say       设备留言
import http.server
import hashlib
import io
import os
import socketserver
import threading
import time
import urllib.parse
from datetime import date

import ramen

BASE = os.path.dirname(os.path.abspath(__file__))
SPOOL = os.path.join(BASE, "net")
OUT = os.path.join(SPOOL, "out")
CMD = os.path.join(SPOOL, "cmd.txt")
AGENT = os.path.join(SPOOL, "agent.sh")
BOOT = os.path.join(SPOOL, "boot.sh")
os.makedirs(OUT, exist_ok=True)

LOCK = threading.Lock()
RAMEN_LOCK = threading.Lock()
LIFE_LOCK = threading.Lock()
BADGE_CACHE = {}   # text -> png; click badge, tiny and bounded
LIFE_CACHE = {}
PORT = 8899


def ts():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def append(name, text):
    try:
        with open(os.path.join(SPOOL, name), "a", encoding="utf-8", errors="replace") as f:
            f.write(text + "\n")
    except Exception:
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        p = self.path
        if p.startswith("/hb"):
            return  # 心跳不记日志，避免日志爆掉
        append("access.log", "%s %s" % (ts(), p))

    def _send(self, body, code=200, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(p.query)

        if p.path.startswith("/tool/"):
            # 设备自取工具脚本，保持与 PC 侧一致
            name = os.path.basename(p.path[len("/tool/"):])
            fp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "kindle", "weatherdash-tools", name)
            body = b""
            try:
                with open(fp, "rb") as f:
                    body = f.read()
            except Exception:
                body = b""
            if body:
                append("tool.log", "%s served %s %dB" % (ts(), name, len(body)))
            self._send(body, 200 if body else 404)
            return

        if p.path == "/cat6/list":
            # 动作清单 + 每个动作的帧数与矩形（必须放在 /cat6/ 前缀判断之前）
            base = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "dist", "cat6", "anim.txt")
            body = b""
            try:
                with open(base, "rb") as f:
                    body = f.read()
            except Exception:
                body = b""
            self._send(body, 200 if body else 404)
            return

        if p.path.startswith("/cat6/"):
            # 猫动画资源：dist/cat5 下的帧图与清单
            rel = p.path[len("/cat6/"):]
            rel = rel.replace("..", "").lstrip("/")
            fp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "dist", "cat6", *rel.split("/"))
            body = b""
            try:
                with open(fp, "rb") as f:
                    body = f.read()
            except Exception:
                body = b""
            if body:
                append("tool.log", "%s cat6 %s %dB" % (ts(), rel, len(body)))
            self._send(body, 200 if body else 404)
            return


        if p.path == "/next":
            body = b""
            with LOCK:
                if os.path.exists(CMD):
                    try:
                        with open(CMD, "rb") as f:
                            body = f.read()
                        os.remove(CMD)
                    except Exception as e:
                        append("errors.log", "%s read cmd: %r" % (ts(), e))
            if body:
                append("cmd.log", "%s served %d bytes" % (ts(), len(body)))
            self._send(body)

        elif p.path == "/agent":
            body = b""
            try:
                if os.path.exists(AGENT):
                    with open(AGENT, "rb") as f:
                        body = f.read()
            except Exception as e:
                append("errors.log", "%s read agent: %r" % (ts(), e))
            self._send(body)

        elif p.path == "/boot":
            # 设备启动/唤醒时拉取的一次性配置脚本（时区、常亮、前光、轮播）
            body = b""
            try:
                if os.path.exists(BOOT):
                    with open(BOOT, "rb") as f:
                        body = f.read()
            except Exception as e:
                append("errors.log", "%s read boot: %r" % (ts(), e))
            if body:
                append("boot.log", "%s served %d bytes" % (ts(), len(body)))
            self._send(body)

        elif p.path == "/hb":
            b = (q.get("b") or ["?"])[0]
            ip = (q.get("ip") or ["?"])[0]
            ver = (q.get("v") or ["?"])[0]
            append("hb.log", "%s beat=%s ip=%s ver=%s" % (ts(), b, ip, ver))
            self._send("ok")

        elif p.path == "/ping":
            self._send("pong")

        elif p.path == "/say":
            m = (q.get("m") or [""])[0]
            append("device.log", "%s %s" % (ts(), m))
            self._send("ok")

        elif p.path == "/hash":
            # 返回当前 agent 脚本的 md5，设备用来判断是否需要更新
            try:
                with open(AGENT, "rb") as f:
                    h = hashlib.md5(f.read()).hexdigest()
            except Exception:
                h = "none"
            self._send(h)

        elif p.path == "/ramen":
            # 泡面计时器：按剩余秒数渲染并返回整页 PNG
            try:
                left = int((q.get("left") or ["0"])[0])
                total = int((q.get("total") or ["180"])[0])
            except ValueError:
                self._send("bad params", 400)
                return
            total = max(1, min(3600, total))
            left = max(-600, min(total + 600, left))
            try:
                with RAMEN_LOCK:
                    body = ramen.render(left, total)
                append("ramen.log", "%s left=%d total=%d %dB" % (ts(), left, total, len(body)))
                self._send(body, ctype="image/png")
            except Exception as e:
                append("errors.log", "%s ramen render: %r" % (ts(), e))
                self._send("render failed", 500)

        elif p.path == "/badge":
            # 点击角标：设备每点一下就要在屏幕上看到"第几次点击"的痕迹。
            # 设备侧没有字体渲染能力（5.16 的 fbink 参数不全，逐点 fork
            # 会拖慢点击），所以由 PC 画成小 PNG，设备只做一次贴图。
            try:
                text = (q.get("t") or ["1/4 #1"])[0][:24]
                import render_badge
                body = BADGE_CACHE.get(text)
                if body is None:
                    body = render_badge.render(text)
                    if len(BADGE_CACHE) > 64:
                        BADGE_CACHE.clear()
                    BADGE_CACHE[text] = body
                self._send(body, ctype="image/png")
            except Exception as e:
                append("errors.log", "%s badge render: %r" % (ts(), e))
                self._send("badge failed", 500)

        elif p.path == "/lifeweeks":
            # 人生周历：设备侧没有 Python，只能由 PC 渲染成 PNG 回传。
            # 同一自然日内复用缓存，跨天自动重算，成本可以忽略。
            try:
                import render_life
                day = (q.get("d") or [""])[0]
                today = date.fromisoformat(day) if day else date.today()
                with LIFE_LOCK:
                    key = today.isoformat()
                    if LIFE_CACHE.get("key") != key:
                        cfg = render_life.load_cfg()
                        img, st = render_life.render_life(cfg, today=today)
                        buf = io.BytesIO()
                        img.save(buf, format="PNG", optimize=True)
                        LIFE_CACHE["key"] = key
                        LIFE_CACHE["png"] = buf.getvalue()
                        LIFE_CACHE["stats"] = st
                        append("life.log", "%s rendered %s %dB elapsed=%d" % (
                            ts(), key, len(LIFE_CACHE["png"]), st["elapsed"]))
                    body = LIFE_CACHE["png"]
                self._send(body, ctype="image/png")
            except Exception as e:
                append("errors.log", "%s lifeweeks render: %r" % (ts(), e))
                self._send("render failed", 500)

        elif p.path == "/cat":
            # 猫咪页：和 lifeweeks 一样由 PC 供图，设备侧只负责上屏。
            #
            # ?part=base|open|close|meta|list   默认 base
            # ?pose=sit|sleep|groom2|stretch     默认 sit
            #
            # base  全屏基图（动作的第一帧）
            # open  微动补丁·A
            # close 微动补丁·B（sit/stretch 是闭眼，sleep 是呼吸，groom2 是舔爪）
            # meta  该动作的 meta.txt（给设备读坐标和节奏）
            # list  动作清单，逗号分隔
            try:
                part = (q.get("part") or ["base"])[0]
                pose = (q.get("pose") or ["sit"])[0]
                cat_root = os.path.join(BASE, "cat4")

                # 动作白名单：只用目录存在的，顺序固定，便于设备端轮播
                order = ["sit", "sleep", "groom2", "stretch"]
                poses = [x for x in order
                         if os.path.isdir(os.path.join(cat_root, x))]
                if not poses:
                    self._send("no poses", 404)
                    return

                if part == "list":
                    self._send(",".join(poses), ctype="text/plain; charset=utf-8")
                    return

                if pose not in poses:
                    pose = poses[0]

                mapping = {
                    "base": "base.png",
                    "open": "eye_open.png",
                    "close": "eye_close.png",
                    "meta": "meta.txt",
                }
                if part not in mapping:
                    self._send("bad part", 400)
                    return

                path = os.path.join(cat_root, pose, mapping[part])
                if not os.path.exists(path):
                    self._send("no image", 404)
                    return
                with open(path, "rb") as fp:
                    body = fp.read()
                if part == "meta":
                    self._send(body, ctype="text/plain; charset=utf-8")
                else:
                    self._send(body, ctype="image/png")
            except Exception as e:
                append("errors.log", "%s cat serve: %r" % (ts(), e))
                self._send("cat failed", 500)

        else:
            self._send("no such endpoint", 404)

    def do_POST(self):
        p = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(p.query)
        n = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(n) if n else b""

        if p.path == "/result":
            rc = (q.get("rc") or ["?"])[0]
            tag = (q.get("tag") or ["cmd"])[0]
            name = "r_%s_%s_%s.txt" % (time.strftime("%Y%m%d_%H%M%S"), tag, rc)
            path = os.path.join(OUT, name)
            try:
                with open(path, "wb") as f:
                    f.write(b"rc=%s tag=%s at=%s\n" % (rc.encode(), tag.encode(), ts().encode()))
                    f.write(data)
                append("result.log", "%s saved %s (%d bytes) rc=%s" % (ts(), name, len(data), rc))
            except Exception as e:
                append("errors.log", "%s write result: %r" % (ts(), e))
            self._send("ok")
        elif p.path == "/upload":
            # 设备上传文件（截图等）到 net/up/，便于 PC 侧直接查看屏幕
            name = os.path.basename((q.get("name") or ["upload.bin"])[0])
            updir = os.path.join(SPOOL, "up")
            try:
                if not os.path.isdir(updir):
                    os.makedirs(updir)
                path = os.path.join(updir, name)
                with open(path, "wb") as f:
                    f.write(data)
                append("upload.log", "%s saved %s (%d bytes)" % (ts(), name, len(data)))
                self._send("ok %d" % len(data))
            except Exception as e:
                append("errors.log", "%s upload: %r" % (ts(), e))
                self._send("upload failed", 500)
        else:
            self._send("no such endpoint", 404)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    append("server.log", "%s bridge v2 starting on 0.0.0.0:%d" % (ts(), PORT))
    with Server(("0.0.0.0", PORT), Handler) as httpd:
        append("server.log", "%s listening" % ts())
        httpd.serve_forever()
