#!/usr/bin/env python3
"""Exercise the native translation model through a synthetic loopback server."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
from threading import Thread
from time import sleep


ROOT = Path(__file__).resolve().parents[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.server.paths.append(self.path)
        if self.path == "/fixture/v1/models" and self.headers.get("Authorization") == "Bearer synthetic-test-key":
            self.reply(200, {"data": [{"id": "fixture-chat"}, {"id": "fixture-chat"}, {"id": ""}]})
        elif self.path == "/redirect/v1/models":
            self.send_response(307)
            self.send_header("Location", "/must-not-follow")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.reply(401, {"error": {"message": "Synthetic detail for redaction fixture."}})

    def do_POST(self):
        self.server.paths.append(self.path)
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        auth = self.headers.get("Authorization")
        messages = body.get("messages", [])
        if (len(messages) != 2 or messages[0]["role"] != "system"
                or "English into Simplified Chinese" not in messages[0]["content"]
                or messages[1] != {"role": "user", "content": "A synthetic sentence."}
                or set(body) != {"model", "messages", "stream"} or body["stream"]):
            self.reply(400, {})
            return
        cases = {
            "/fixture/v1/chat/completions": ("fixture-chat", "Bearer synthetic-test-key", "一句合成示例。"),
            "/changed/v1/chat/completions": ("fixture-chat", None, "未发送旧密钥。"),
            "/other/v1/chat/completions": ("other-chat", None, "另一个模型。"),
            "/slow/v1/chat/completions": ("fixture-chat", None, "response after cancel"),
        }
        if self.path not in cases:
            self.reply(404, {})
            return
        model, expected_auth, result = cases[self.path]
        if body["model"] != model or auth != expected_auth:
            self.reply(400, {})
            return
        if self.path == "/slow/v1/chat/completions":
            sleep(1)
        self.reply(200, {"choices": [{"message": {"content": result}, "finish_reason": "stop"}]})


def main():
    with tempfile.TemporaryDirectory(prefix="lumen-translation-smoke-") as work:
        app = Path(work) / "TranslationSmoke.app" / "Contents"
        exe = app / "MacOS" / "TranslationSmoke"
        exe.parent.mkdir(parents=True)
        with (app / "Info.plist").open("wb") as metadata:
            plistlib.dump({
                "CFBundleIdentifier": "io.github.surfire.lumen.translation-smoke",
                "CFBundleExecutable": "TranslationSmoke",
                "CFBundlePackageType": "APPL",
                "NSAppTransportSecurity": {"NSExceptionDomains": {
                    ip: {"NSExceptionAllowsInsecureHTTPLoads": True} for ip in ("127.0.0.1", "::1")
                }},
            }, metadata)
        sources = ["app/LumenCommandCatalog.swift", "app/LumenQuickAnswer.swift", "app/TranslationClient.swift", "app/TranslationModel.swift", "app/TranslationPanel.swift",
                   "scripts/translation-smoke.swift"]
        subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macosx14.0",
                        "-parse-as-library", *sources, "-o", str(exe)], cwd=ROOT, check=True, timeout=60)
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.paths = []
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                subprocess.run([exe, f"http://127.0.0.1:{server.server_port}"], check=True, timeout=15)
            finally:
                server.shutdown()
                worker.join()
            assert "/must-not-follow" not in server.paths
            assert server.paths.count("/fixture/v1/models") == 2
            assert server.paths[0] == "/fixture/v1/models"


if __name__ == "__main__":
    main()
