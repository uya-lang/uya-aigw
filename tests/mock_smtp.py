#!/usr/bin/env python3
"""极简 SMTP 服务器，只给 tests/mail_e2e.sh 用。

覆盖 aigw 邮件投递实际会说的话：EHLO / AUTH LOGIN / AUTH PLAIN / MAIL / RCPT /
DATA / QUIT。收到的每封信写到 <out-dir>/msg-NNN.eml，认证到的用户名追加到
<out-dir>/auth.log（每行一条），会话命令流水写到 <out-dir>/cmd.log。

用法：
    python3 tests/mock_smtp.py --port-file /tmp/p --out-dir /tmp/mail [--delay-ms 3000]

`--delay-ms` 在**每条连接**上先睡这么久再发 220 问候语，用来验证「慢 SMTP 不会
拖住网关的事件循环」（每个连接一个线程，所以多条连接互不阻塞）。
"""
import argparse
import base64
import os
import socketserver
import sys
import threading
import time

ARGS = None
LOCK = threading.Lock()
COUNTER = {"n": 0}


def _log(name, line):
    with LOCK:
        with open(os.path.join(ARGS.out_dir, name), "a") as f:
            f.write(line.rstrip("\r\n") + "\n")


class Handler(socketserver.StreamRequestHandler):
    def _send(self, line):
        self.wfile.write(line.encode() + b"\r\n")
        self.wfile.flush()

    def _readline(self):
        line = self.rfile.readline()
        if not line:
            return None
        return line.decode("utf-8", "replace").rstrip("\r\n")

    def handle(self):
        _log("conn.log", "connect from %s" % (self.client_address,))
        if ARGS.delay_ms:
            time.sleep(ARGS.delay_ms / 1000.0)
        self._send("220 mock.invalid ESMTP ready")
        authed = False
        while True:
            line = self._readline()
            if line is None:
                return
            _log("cmd.log", line if not line.startswith("AUTH PLAIN ") else "AUTH PLAIN <b64>")
            up = line.upper()
            if up.startswith("EHLO") or up.startswith("HELO"):
                self.wfile.write(b"250-mock.invalid hello\r\n")
                self.wfile.write(b"250-AUTH LOGIN PLAIN\r\n")
                self.wfile.write(b"250-8BITMIME\r\n")
                self.wfile.write(b"250 SIZE 10485760\r\n")
                self.wfile.flush()
            elif up.startswith("AUTH LOGIN"):
                self._send("334 VXNlcm5hbWU6")            # "Username:"
                user_b64 = self._readline()
                if user_b64 is None:
                    return
                self._send("334 UGFzc3dvcmQ6")            # "Password:"
                pass_b64 = self._readline()
                if pass_b64 is None:
                    return
                try:
                    user = base64.b64decode(user_b64).decode("utf-8", "replace")
                except Exception:
                    user = "<bad-b64>"
                _log("auth.log", user)
                authed = True
                self._send("235 2.7.0 authentication successful")
            elif up.startswith("AUTH PLAIN"):
                parts = line.split(" ", 2)
                if len(parts) < 3:
                    self._send("334 ")
                    blob = self._readline()
                    if blob is None:
                        return
                else:
                    blob = parts[2]
                try:
                    raw = base64.b64decode(blob).split(b"\0")
                    user = raw[1].decode("utf-8", "replace") if len(raw) > 1 else "<bad>"
                except Exception:
                    user = "<bad-b64>"
                _log("auth.log", user)
                authed = True
                self._send("235 2.7.0 authentication successful")
            elif up.startswith("MAIL FROM"):
                self._send("250 2.1.0 ok")
            elif up.startswith("RCPT TO"):
                self._send("250 2.1.5 ok")
            elif up.startswith("DATA"):
                self._send("354 end with <CRLF>.<CRLF>")
                chunks = []
                while True:
                    raw = self.rfile.readline()
                    if not raw:
                        return
                    if raw in (b".\r\n", b".\n", b".\r"):
                        break
                    if raw.startswith(b".."):
                        raw = raw[1:]          # 点填充还原
                    chunks.append(raw)
                with LOCK:
                    COUNTER["n"] += 1
                    n = COUNTER["n"]
                path = os.path.join(ARGS.out_dir, "msg-%03d.eml" % n)
                with open(path, "wb") as f:
                    f.writelines(chunks)
                _log("data.log", "%d auth=%s size=%d" % (n, authed, sum(len(c) for c in chunks)))
                self._send("250 2.0.0 queued as %03d" % n)
            elif up.startswith("RSET") or up.startswith("NOOP"):
                self._send("250 2.0.0 ok")
            elif up.startswith("QUIT"):
                self._send("221 2.0.0 bye")
                return
            else:
                self._send("502 5.5.2 command not implemented")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--delay-ms", type=int, default=0)
    ARGS = ap.parse_args()
    os.makedirs(ARGS.out_dir, exist_ok=True)
    srv = Server(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    tmp = ARGS.port_file + ".tmp"
    with open(tmp, "w") as f:
        f.write("%d\n" % port)
    os.replace(tmp, ARGS.port_file)
    sys.stderr.write("mock_smtp: listening on 127.0.0.1:%d\n" % port)
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
