#!/usr/bin/env python3
"""Loopback HTTP bridge to a persistent Apple Translation framework worker."""
import argparse
import atexit
import json
import logging
from pathlib import Path
import select
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

BASE = Path(__file__).resolve().parent
MAX_BODY = 1024 * 1024
MAX_ROWS = 128
MAX_CHARACTERS = 100000


class Worker:
    def __init__(self, state_dir):
        self.lock = threading.Lock()
        self.process = None
        self.log = open(state_dir / "worker.log", "a", buffering=1)
        self.started = time.monotonic()
        self.metrics = {"requests": 0, "translated_rows": 0, "failed_requests": 0, "last_elapsed_ms": 0}
        atexit.register(self.close)

    def close(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None

    def read(self, timeout):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            raise TimeoutError("Apple 翻译引擎处理超时。")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("Apple 翻译引擎已退出。")
        return json.loads(line)

    def call(self, payload):
        with self.lock:
            try:
                if self.process is None or self.process.poll() is not None:
                    self.close()
                    self.process = subprocess.Popen(
                        [str(BASE / "translation-worker")],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=self.log, text=True, encoding="utf-8", bufsize=1,
                    )
                    initial = self.read(15)
                    if initial.get("ready") is not True:
                        raise RuntimeError("Apple 翻译引擎初始化失败。")
                self.process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
                self.process.stdin.flush()
                result = self.read(120)
                if payload.get("op") == "translate":
                    self.metrics["requests"] += 1
                    if "error" in result:
                        self.metrics["failed_requests"] += 1
                    else:
                        self.metrics["translated_rows"] += len(result["translations"])
                        self.metrics["last_elapsed_ms"] = result.get("elapsed_ms", 0)
                else:
                    result["metrics"] = dict(self.metrics)
                    result["uptime_seconds"] = int(time.monotonic() - self.started)
                return result
            except Exception:
                self.close()
                raise


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AppleTranslationBridge/1.0"
    slots = threading.BoundedSemaphore(8)

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def reply(self, status, value, content_type="application/json; charset=utf-8"):
        body = value.encode("utf-8") if isinstance(value, str) else json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Cache-Control", "no-store")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self.reply(204, "")

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/":
            self.reply(200, (BASE / "index.html").read_text(encoding="utf-8"), "text/html; charset=utf-8")
        elif path in ("/health", "/languages"):
            try:
                value = self.server.worker.call({"op": "health" if path == "/health" else "languages"})
                self.reply(200, value)
            except Exception as error:
                self.reply(503, {"ready": False, "error": {"code": "worker_unavailable", "message": str(error)}})
        else:
            self.reply(404, {"error": {"code": "not_found", "message": "接口不存在。"}})

    def do_POST(self):
        if urlsplit(self.path).path not in ("/imme", "/translate"):
            self.close_connection = True
            self.reply(404, {"error": {"code": "not_found", "message": "请使用 POST /imme。"}})
            return
        if self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            self.reply(400, {"error": {"code": "invalid_request", "message": "需要 Content-Length。"}})
            return
        if self.headers.get_content_type() != "application/json":
            self.close_connection = True
            self.reply(415, {"error": {"code": "invalid_request", "message": "请使用 application/json。"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                self.close_connection = True
                self.reply(413, {"error": {"code": "request_too_large", "message": "请求体须为 1 字节到 1 MB。"}})
                return
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError("请求体不完整。")
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError("请求体须为 JSON 对象。")
            rows = payload.get("text_list")
            target = payload.get("target_lang")
            source = payload.get("source_lang", "auto")
            if not isinstance(rows, list) or not rows or len(rows) > MAX_ROWS or not all(isinstance(item, str) for item in rows):
                raise ValueError("text_list 须包含 1 到 128 个字符串。")
            if sum(map(len, rows)) > MAX_CHARACTERS:
                raise ValueError("单次请求文本不能超过 100000 字符。")
            if not isinstance(target, str) or not target or target == "auto" or len(target) > 32:
                raise ValueError("需要有效的 target_lang。")
            if not isinstance(source, str) or not source or len(source) > 32:
                raise ValueError("需要有效的 source_lang，自动检测请使用 auto。")
        except (ValueError, UnicodeError, TimeoutError) as error:
            self.close_connection = True
            self.reply(400, {"error": {"code": "invalid_request", "message": str(error)}})
            return
        if not self.slots.acquire(blocking=False):
            self.reply(429, {"error": {"code": "busy", "message": "翻译请求较多，请稍后重试。"}})
            return
        try:
            value = self.server.worker.call({"op": "translate", "source_lang": source, "target_lang": target, "text_list": rows})
            code = value.get("error", {}).get("code")
            status = 200 if not code else (503 if code == "model_not_installed" else 422)
            self.reply(status, value)
        except Exception as error:
            logging.exception("Translation worker failed")
            self.reply(503, {"error": {"code": "worker_unavailable", "message": str(error)}})
        finally:
            self.slots.release()

    def log_message(self, fmt, *args):
        logging.info("%s %s", self.client_address[0], fmt % args)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=3210)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".local/state/apple-translation-bridge")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    args.state_dir.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.worker = Worker(args.state_dir)
    logging.info("Apple local translation listening on 127.0.0.1:%s", args.port)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        server.worker.close()


if __name__ == "__main__":
    main()
