#!/usr/bin/env python3
"""Exercise the translation model and launcher streaming through synthetic loopback servers."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile
from threading import Thread
from time import monotonic, sleep


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
                or set(body) != {"model", "messages", "stream"} or body["stream"] is not True):
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
        finish_reason = {"/changed/v1/chat/completions": "length",
                         "/other/v1/chat/completions": "end_turn"}.get(self.path, "stop")
        self.reply(200, {"choices": [{"message": {"content": result}, "finish_reason": finish_reason}]})


class StreamingHandler(Handler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/stream/v1/chat/completions"
        assert set(request) == {"messages", "model", "stream"}
        assert request["model"] == "fixture-chat" and request["stream"] is True
        system, user = request["messages"]
        assert system["role"] == "system" and user["role"] == "user"
        verb = "qa" if "You have no live sources" in system["content"] else "tr"
        if verb == "tr":
            assert "English into Simplified Chinese" in system["content"]
        mode = user["content"]
        case = f"{verb}-{mode}"
        self.server.requests.append(case)
        if mode in ("json", "mislabeled"):
            body = b' \r\n {"choices":[{"message":{"content":"JSON fallback"},"finish_reason":"stop"}]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json" if mode == "json" else "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.end_headers()
        if mode == "bom":
            prefix = '\ufeffdata: {"choices":'
        else:
            if mode == "finish":
                # The BOM after a blank line is not a stream prefix; ignore this field.
                self.wfile.write(b'\r\n\xef\xbb\xbfdata: {"choices":[{"delta":{"content":"unexpected"}}]}\r\n\r\n')
            self.wfile.write(b': fixture heartbeat\r\ndata: {"choices":[]}\r\n\r\n')
            self.wfile.write(b'data: {"choices":\r\n')
            prefix = 'data: '
        first = (prefix + '[{"delta":{"content":"第一段 🦌"},"finish_reason":null}]}\r\n\r\n').encode()
        split = first.index("🦌".encode()) + 1
        self.wfile.write(first[:split])
        self.wfile.write(first[split:])
        root = self.server.root
        if mode in ("finish", "bom"):
            self.wait_for_marker(root / f"release-{case}")
            finish = "length" if verb == "tr" else None
            chunk = {"choices": [{"delta": {"content": " / second chunk"}, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            if verb == "qa":
                self.wfile.write(b"data: [DONE]\n\n")
            # Do not close the body until Swift confirms it handled the terminal event.
            self.wait_for_marker(root / f"finished-{case}")
        else:
            assert mode in ("cancel", "edit")
            self.connection.settimeout(2)
            try:
                assert self.connection.recv(1) == b"", "expected the client to close the SSE connection"
            except ConnectionResetError:
                pass
            (root / f"closed-{case}").touch()

    @staticmethod
    def wait_for_marker(path):
        deadline = monotonic() + 3
        while not path.exists() and monotonic() < deadline:
            sleep(0.01)
        assert path.exists(), f"client did not signal {path.name}"


def verify_streaming():
    launcher = runpy.run_path(str(ROOT / "scripts/smoke-launcher.py"))
    with tempfile.TemporaryDirectory(prefix="lumen-streaming-smoke-") as work:
        root = Path(work).resolve()
        (root / "corpus").mkdir()
        (root / "streaming-scenario").touch()
        with ThreadingHTTPServer(("127.0.0.1", 0), StreamingHandler) as server:
            server.root = root
            server.requests = []
            (root / "translation-endpoint").write_text(f"http://127.0.0.1:{server.server_port}")
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                launcher["run"](root, "en")
            finally:
                server.shutdown()
                worker.join()
            assert server.requests == [f"{verb}-{mode}" for verb in ("tr", "qa")
                                       for mode in ("finish", "bom", "cancel", "edit", "json", "mislabeled")], server.requests


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
    verify_streaming()
