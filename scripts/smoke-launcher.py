#!/usr/bin/env python3
"""Exercise the signed app's native controls using a synthetic corpus without desktop input."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import plistlib
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
from threading import Thread
from time import sleep
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "target/Lumen.app/Contents"
APP = BUNDLE / "MacOS/Lumen"

class GuiTranslationFixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        source = request["messages"][1]["content"]
        root = self.server.root
        if "You have no live sources" in request["messages"][0]["content"]:
            self.reply_qa(request, source, root)
            return
        self.server.requests.append((self.path, request))
        (root / "translation-request-started").touch()
        assert self.headers["Authorization"] == "Bearer synthetic-smoke-key"
        denied = source == "模拟错误"
        slow = {"取消翻译": "slow-escape", "改字前": "slow-edit"}.get(source)
        if slow:
            (root / f"{slow}-started").touch()
            sleep(1.2)
        replies = {
            "今天下午三点开会": "Meeting at three this afternoon.",
            "it is fine": "没问题。",
            "你好": "Ciao!",
            "see you tomorrow": "明天见。",
        }
        body = json.dumps({"choices": [{"message": {
            "content": replies.get(source, "Late reply")
        }, "finish_reason": "stop"}]}).encode()
        try:
            self.send_response(401 if denied else 200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        if slow:
            (root / f"{slow}-replied").touch()

    def reply_qa(self, request, source, root):
        assert self.headers["Authorization"] == "Bearer synthetic-smoke-key"
        assert self.path == "/translated/v1/chat/completions"
        assert set(request) == {"model", "messages", "stream"}
        assert len(request["messages"]) == 2 and request["messages"][1]["role"] == "user"
        self.server.qa_requests.append(source)
        (root / "qa-request").touch()
        slow = source == "synthetic slow"
        if slow:
            (root / "qa-slow").touch()
            sleep(1.4)
        answer = ("日本語の回答と中文示例です。内容用于验证滚动和换行。\n" * 25
                  if source == "長い回答" else "Late answer" if slow else "Current answer")
        body = json.dumps({"choices": [{"message": {"content": answer}, "finish_reason": "stop"}]}).encode()
        try:
            self.send_response(401 if source == "synthetic error" else 200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        if slow:
            (root / "qa-late").touch()


def verify_gui_translation(root, language):
    with ThreadingHTTPServer(("127.0.0.1", 0), GuiTranslationFixture) as server:
        server.root = root
        server.requests = []
        server.qa_requests = []
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            (root / "translation-endpoint").write_text(f"http://127.0.0.1:{server.server_port}")
            run(root, language)
            expected = [
                ("今天下午三点开会", "Simplified Chinese into English"),
                ("it is fine", "English into Simplified Chinese"),
                ("你好", "translate into Italian"),
                ("模拟错误", "Simplified Chinese into English"),
                ("取消翻译", "Simplified Chinese into English"),
                ("改字前", "Simplified Chinese into English"),
                ("see you tomorrow", "English into Simplified Chinese"),
            ]
            assert len(server.requests) == len(expected), server.requests
            assert server.qa_requests == ["長い回答", "synthetic error", "synthetic slow", "newer question"]
            for (path, request), (source, direction) in zip(server.requests, expected):
                assert path == "/translated/v1/chat/completions"
                assert request["model"] == "sandbox-model"
                assert direction in request["messages"][0]["content"]
                assert request["messages"][1]["content"] == source
        finally:
            server.shutdown()
            worker.join()


FIXTURE_ENGINE = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import time

work = Path(__file__).resolve().parent
engine = str(work / "native-engine")
db, database, action, *args = sys.argv[1:]


def wait_for(marker):
    end = time.monotonic() + 12
    while not (work / marker).exists():
        if time.monotonic() >= end:
            sys.exit(f"timed out waiting for {marker}")
        time.sleep(0.02)


def gate(name):
    (work / (name + "-started")).touch()
    wait_for("finish-" + name)


def progress(phase, entries, elapsed, **optional):
    line = (json.dumps(dict(event="progress", phase=phase, entries=entries,
                            elapsed_ms=elapsed, **optional)) + chr(10)).encode()
    middle = len(line) // 2
    os.write(2, line[:middle])
    time.sleep(0.01)
    os.write(2, line[middle:])


def save_document_stamps():
    documents = {}
    for path in (work / "corpus").rglob("*"):
        if path.suffix not in (".txt", ".md") or not path.is_file():
            continue
        stat = path.stat()
        mtime = divmod(stat.st_mtime_ns, 10**9)
        ctime = divmod(stat.st_ctime_ns, 10**9)
        fields = (stat.st_dev % 2**64, stat.st_ino, stat.st_size, *mtime, *ctime)
        documents[str(path)] = {"stamp": ":".join(map(str, fields)), "text": path.read_text()}
    temporary = work / "document-stamps.tmp"
    temporary.write_text(json.dumps(documents))
    temporary.replace(work / "document-stamps.json")


def indexed_documents():
    return json.loads((work / "document-stamps.json").read_text())


def query_hits(args):
    output = subprocess.check_output([engine, db, database, "query", *args])
    hits = json.loads(output)
    documents = indexed_documents()
    for hit in hits:
        if hit.get("snippet") is not None and hit["path"] in documents:
            hit["document_stamp"] = documents[hit["path"]]["stamp"]
    return hits


volume_uuid = "01234567-89ab-cdef-0123-456789abcdef"
volume_mount = "/Volumes/Lumen-Synthetic"
volume_catalog = work / "volume-indexed"
volume_connected = not (work / "volume-disconnected").exists()
if action == "volumes":
    registered = volume_catalog.exists()
    rows = [dict(uuid=volume_uuid, path=volume_mount, available=volume_connected,
                 indexed=registered and volume_connected, needs_refresh=registered and not volume_connected)]
    print(json.dumps(rows if registered or volume_connected else []))
    sys.exit(0)
if action == "index-volume":
    assert args == ["--progress", "--uuid", volume_uuid, "--", volume_mount]
    assert volume_connected
    progress("scanning", 17, 750)
    volume_catalog.touch()
    print(json.dumps({"items": 17}))
    sys.exit(0)
if action == "forget-volume":
    assert args == ["--", volume_uuid]
    volume_catalog.unlink()
    print(json.dumps({"removed": True}))
    sys.exit(0)

if action == "index":
    if "--progress" in args:
        args.remove("--progress")
        progress("preparing", 0, 0)
        if not (work / "index-args.json").exists():
            for _ in range(40):
                print("progress pipe fixture " + "x" * 2048, file=sys.stderr)
            progress("scanning", 17, 750)
            gate("cold-progress")
        elif "--documents" in args:
            progress("scanning", 18, 3000, estimated_total=25, eta_seconds=12)
    if "--documents" in args and not (work / "finish-documents").exists():
        gate("documents")
    if "--deny" in args and (work / "reject-scope").exists():
        gate("scope")
        sys.exit("fixture refused the scope before committing it")
    output = subprocess.check_output([engine, db, database, action, *args])
    save_document_stamps()
    (work / "index-args.json").write_text(json.dumps(args))
    progress("done", 20, 3500)
    sys.stdout.buffer.write(output)
    sys.exit(0)

if action == "watch":
    if "--help" in args:
        print("  --progress  Report JSON lines on stderr")
        sys.exit(0)
    assert args == ["--bundled-pdf-helper", "--progress"], "watch must use the saved scope and current app helper"
    with (work / "watch-launches").open("a") as handle:
        handle.write("start\\n")
    if (work / "hold-startup-watch").exists():
        gate("startup-watch")
    print(json.dumps({"event": "ready"}), flush=True)
    while True:
        if (work / "fail-watch").exists():
            sys.exit("controlled watcher failure")
        marker = work / "update-watch"
        if marker.exists():
            marker.unlink()
            progress("scanning", 6, 800)
            hold = work / "hold-watch-progress"
            if hold.exists():
                hold.unlink()
                gate("watch-progress")
            scope = json.loads((work / "index-args.json").read_text())
            subprocess.check_call([engine, db, database, "index", *scope], stdout=subprocess.DEVNULL)
            save_document_stamps()
            progress("done", 8, 1000)
            print(json.dumps({"event": "updated"}), flush=True)
        time.sleep(0.02)

def check_gemma_options(options):
    assert len(options) == 2 and options[0] == "--gemma-home", options
    assert Path(options[1]).resolve() == work / "missing-gemma", options


if action == "status":
    status = json.loads(subprocess.check_output([engine, db, database, action, *args]))
    documents = "--documents" in json.loads((work / "index-args.json").read_text())
    limited = (work / "gemma-cap").exists()
    pending = documents and (limited or (work / "gemma-pending").exists() or not (work / "finish-embedding-4").exists())
    status["gemma"] = dict(documents_enabled=documents,
                           embedded_chunks=43000 if limited else 2 if (work / "finish-embedding-3").exists()
                           else 1 if (work / "finish-embedding-1").exists() else 0,
                           skipped_chunks=0, pending=pending, limited=limited, chunk_limit=43000)
    if (work / "legacy-bge-consent").exists():
        status["embedded_chunks"] = 2
    print(json.dumps(status))
    sys.exit(0)

if action == "model-status":
    verify = "--verify" in args
    assert args[:-2] == ["--gemma", *(["--verify"] if verify else [])], args
    check_gemma_options(args[-2:])
    present = (work / "gemma-present").exists()
    unverified = not present and (work / "gemma-unverified").exists()
    diagnostic = None if present or unverified else "Gemma resource directory is missing: /Users/synthetic-account/private"
    if present and verify and not (work / "finish-model-check").exists():
        gate("model-check")
    print(json.dumps({"available": present or unverified, "verified": present and verify, "diagnostic": diagnostic}))
    sys.exit(0)

if action == "embed":
    assert args[:-2] == ["--gemma", "--max", "32"], args
    check_gemma_options(args[-2:])
    launches = work / "embeddings-started"
    batch = len(launches.read_text().splitlines()) + 1 if launches.exists() else 1
    with launches.open("a") as handle:
        handle.write(f"{batch}\\n")
    assert batch <= 7, "unexpected extra semantic batch"
    gate(f"embedding-{batch}")
    if batch == 6:
        sys.exit("Gemma resource directory is missing")
    indexed = 0 if batch in (2, 5) else 1
    skipped = 2 if batch == 2 else 0
    print(json.dumps({"new_embeddings": indexed, "skipped_chunks": skipped, "has_more": batch != 4}))
    sys.exit(0)


def related_hits(term):
    if term == "outdated semantic request":
        gate("stale-semantic")
    elif term == "health examination" and not (work / "finish-semantic-enrichment").exists():
        gate("semantic-enrichment")
    if term not in ("health examination", "outdated semantic request"):
        return []
    documents = indexed_documents()
    hits = []
    for name in ("health examination roster.txt", "notes.md", "notes.md", "related-one.md",
                 "related-two.md", "related-three.md"):
        path = work / "corpus" / name
        document = documents[str(path)]
        hits.append({"path": str(path), "name": path.name, "kind": "file", "availability": "local",
                     "matched_by": "semantic_candidate", "snippet": document["text"],
                     "document_stamp": document["stamp"]})
    return hits


if action == "semantic-serve":
    check_gemma_options(args)
    with (work / "semantic-serve-launches").open("a") as handle:
        handle.write("start\\n")
    for line in sys.stdin:
        req = json.loads(line)
        assert req["mode"] == "semantic" and req["limit"] == 12
        if (work / "gemma-cap").exists():
            (work / "capped-gemma-query-started").touch()
        print(json.dumps({"id": req["id"], "hits": related_hits(req["query"])}), flush=True)
    sys.exit(0)

if action in ("query", "validate-hit"):
    sys.exit("launcher unexpectedly spawned a standalone lexical query or hit validator")


def validated(hit):
    assert set(hit) <= {"path", "kind", "availability", "document_stamp"}, hit
    path = Path(hit["path"])
    assert path.is_absolute()
    stamp = hit.get("document_stamp")
    if path.name == "鹿鸣.md":
        assert (hit["kind"], hit["availability"], stamp) == ("file", "local", None)
        (work / "han-validation-started").touch()
    if path.name == "body-match.md":
        assert (hit["kind"], hit["availability"], stamp) == ("file", "local", indexed_documents()[str(path)]["stamp"])
        (work / "body-validation-started").touch()
    if path.name == "related-one.md":
        (work / "semantic-batch-validated").touch()
    if path.name == "cloudledger.txt" and (work / "hold-cloud-reveal").exists() and not (work / "finish-cloud-reveal").exists():
        assert (hit["kind"], hit["availability"], stamp) == ("file", "provider_metadata_only", None)
        gate("cloud-reveal")
    args = ["--kind", hit["kind"], "--availability", hit["availability"]]
    if stamp is not None:
        args += ["--document-stamp", stamp]
    return json.loads(subprocess.check_output([engine, db, database, "validate-hit", *args, "--", str(path)]))["valid"]


def search_request(req):
    hits = query_hits(["--mode", req["mode"], "--limit", str(req["limit"]), "--", req["query"]])
    if req["mode"] == "text":
        term = req["query"]
        if term == "鹿鸣":
            if (work / "hold-han-refresh-body").exists() and not (work / "finish-han-refresh-body").exists():
                gate("han-refresh-body")
            elif not (work / "finish-han-body").exists():
                gate("han-body")
        if term == "protected-neighbor" and (work / "settings-scenario").exists():
            (work / "metadata-only-body-started").touch()
        if term == "archive" and (work / "hold-archive-text").exists() and not (work / "finish-archive-text").exists():
            gate("archive-text")
        if term == "privateneedle" and (work / "hold-scope-search").exists():
            gate("scope-search")
        if term == "before render original":
            assert len(hits) == 1 and hits[0].get("document_stamp")
            gate("before-render")
        if term == "missing stamp original":
            assert len(hits) == 1 and hits[0].pop("document_stamp")
    return hits

if action == "serve":
    for line in sys.stdin:
        req = json.loads(line)
        if req.get("op") == "validate":
            assert set(req) == {"id", "op", "hits"}, req
            valid = [validated(hit) for hit in req["hits"]]
            print(json.dumps({"id": req["id"], "valid": valid}), flush=True)
            continue
        assert set(req) == {"id", "query", "mode", "limit", "check_access"} and req["check_access"] is False, req
        assert req["mode"] in ("name", "text"), req
        if req["mode"] == "name" and req["query"] == "obsolete" and not (work / "finish-obsolete").exists():
            gate("obsolete")
        if req["mode"] == "name" and req["query"] == "waiting old name" and not (work / "finish-pre-han-name").exists():
            gate("pre-han-name")
        if req["mode"] == "name" and req["query"] == "late lexical delivery" and not (work / "finish-late-name").exists():
            gate("late-name")
        if req["query"] == "external-volume-fixture":
            hits = []
            if volume_catalog.exists() and not (work / "volume-disconnected").exists():
                name = "external-volume-fixture.txt"
                hits.append(dict(path=volume_mount + "/" + name, name=name, kind="file",
                                 availability="local", matched_by="name"))
            print(json.dumps({"id": req["id"], "hits": hits}), flush=True)
            continue
        try:
            hits = search_request(req)
            reply = {"id": req["id"], "hits": hits}
        except subprocess.CalledProcessError as error:
            reply = {"id": req["id"], "error": str(error)}
        print(json.dumps(reply), flush=True)
    sys.exit(0)

os.execv(engine, [engine, db, database, action, *args])
"""


def make_corpus(root):
    corpus = root / "corpus"
    corpus.mkdir()
    samples = {
        "archive-one.txt": "Synthetic ledger.",
        "archive-two.txt": "Synthetic backup.",
        "notes.md": "The archive appears only in the body of this document.",
        "health examination roster.txt": "A direct title hit and duplicate related candidate.",
        "health examination sample.txt": "Another direct title hit.",
        "related-one.md": "A related source about preventative care.",
        "related-two.md": "A related source about clinical care.",
        "related-three.md": "An extra related source beyond the limit.",
        "content-safety-source.md": "A safety original paragraph for a replacement test.",
        "before-render.md": "A before render original paragraph for a stale reply test.",
        "missing-stamp.md": "A missing stamp original paragraph for a missing stamp test.",
        "obsolete.txt": "Superseded synthetic response.",
        "鹿鸣.md": "A filename match.",
        "local-field-notes.md": "这一条正文提到了鹿鸣。",
        "late lexical delivery.md": "A name reply held by the fixture.",
        "body-before-name.md": "A late lexical delivery once produced this note.",
        "open-safety.txt": "Stale action fixture.",
        "preview-safety.txt": "Stale Quick Look fixture.",
        "Excluded/privateneedle.txt": "Synthetic excluded path.",
        "OneDrive - Synthetic/cloudledger.txt": "Synthetic provider path.",
        "青山月报.md": "合成测试样本。",
    }
    for name, content in samples.items():
        file = corpus / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content, encoding="utf-8")


def install_fixture(root):
    script = root / "fixture-engine"
    script.write_text(FIXTURE_ENGINE, encoding="utf-8")
    script.chmod(0o700)
    resources = BUNDLE / "Resources"
    (root / "native-engine").symlink_to(resources / "lumen")
    (root / "LumenPdfExtractor").symlink_to(resources / "LumenPdfExtractor")
    return script


def run(root, language, gemma_home=None):
    environment = os.environ.copy()
    environment.pop("LUMEN_GEMMA_TEST_HOME", None)
    if gemma_home is not None:
        environment["LUMEN_GEMMA_TEST_HOME"] = str(gemma_home)
    subprocess.run([str(APP), "--gui-smoke", str(root), language], check=True, env=environment,
                   timeout=150 if gemma_home is not None else 45)


def write_preview_png(path, size, color, accent=None):
    def png_chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    def row(y):
        inner = size // 4 <= y < size * 3 // 4
        return b"\x00" + b"".join(bytes(accent if accent and inner and size // 4 <= x < size * 3 // 4 else color)
                                  for x in range(size))

    rows = b"".join(row(y) for y in range(size))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" +
                     png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
                     png_chunk(b"IDAT", zlib.compress(rows)) + png_chunk(b"IEND", b""))


def make_action_probe(root):
    application = root / "Applications/Lumen Action Probe.app/Contents"
    executable = application / "MacOS/probe"
    executable.parent.mkdir(parents=True)
    with (application / "Info.plist").open("wb") as handle:
        plistlib.dump({
            "CFBundleExecutable": "probe",
            "CFBundleIdentifier": "io.github.surfire.lumen.smoke." + root.name,
            "CFBundleName": "Lumen Action Probe",
            "CFBundlePackageType": "APPL",
            "LSBackgroundOnly": True,
            "CFBundleIconFile": "Probe.png",
        }, handle)
    icon = application / "Resources/Probe.png"
    icon.parent.mkdir()
    write_preview_png(icon, 64, (224, 38, 179, 255))
    source = root / "probe.c"
    # The child can write only this synthetic test marker and then exits on its own.
    source.write_text("#include <stdio.h>\n#include <unistd.h>\n"
                      "int main(void) { FILE *out = fopen(" + json.dumps(str(root / "app-started")) +
                      ", \"w\"); if (!out) return 1; fclose(out); sleep(1); return 0; }\n", encoding="utf-8")
    subprocess.run(["xcrun", "clang", str(source), "-o", str(executable)], check=True, timeout=20)
    subprocess.run(["codesign", "--force", "--sign", "-", str(application.parent)], check=True, timeout=15)
    for index in (1, 2):
        twin = root / f"Applications/Group {index}/Twin {index}.app/Contents"
        (twin / "MacOS").mkdir(parents=True)
        shutil.copyfile(executable, twin / "MacOS/probe")
        (twin / "MacOS/probe").chmod(0o700)
        with (twin / "Info.plist").open("wb") as handle:
            metadata = {
                "CFBundleExecutable": "probe",
                "CFBundleIdentifier": f"io.github.surfire.lumen.twin{index}." + root.name,
                "CFBundleDisplayName": "Twin Preview",
                "CFBundlePackageType": "APPL",
            }
            if index == 1:
                borrowed = twin / "Resources/Borrowed.png"
                borrowed.parent.mkdir()
                borrowed.symlink_to(icon)
                metadata["CFBundleIconFile"] = borrowed.name
            plistlib.dump(metadata, handle)
    for name, identifier in (("WeChat Fixture", "com.tencent.xinwechat"),
                             ("WX", "io.github.surfire.lumen.smoke.wx." + root.name)):
        extra = root / f"Applications/{name}.app/Contents"
        extra.mkdir(parents=True)
        with (extra / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"}, handle)



def make_page_pdf(path):
    pages = [b"First page: coastal inventory record", b"Second page: zircon calibration certificate"]
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    for i, line in enumerate(pages):
        content = b"BT /F1 16 Tf 50 730 Td (" + line + b") Tj ET\n"
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {5 + 2*i} 0 R >>".encode())
        objects.append(f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"endstream")
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(pdf))
        pdf += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref = len(pdf)
    pdf += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    for offset in offsets[1:]:
        pdf += f"{offset:010d} 00000 n \n".encode()
    pdf += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    path.write_bytes(pdf)


def verify_content_pipeline(snapshots=None):
    with tempfile.TemporaryDirectory(prefix="lumen-content-gui-") as tmp:
        root = Path(tmp).resolve()
        corpus = root / "corpus"
        chosen = corpus / "Chosen"
        denied = chosen / "Denied"
        denied.mkdir(parents=True)
        (root / "content-scenario").touch()
        if snapshots:
            (root / "capture-preview").touch()
        make_page_pdf(chosen / "report.pdf")
        write_preview_png(chosen / "preview-fixture-a.png", 32, (200, 85, 40, 255))
        write_preview_png(chosen / "preview-fixture-b.png", 32, (27, 102, 152, 255), (235, 192, 93, 255))
        managed = corpus / "Dropbox"
        managed.mkdir()
        write_preview_png(managed / "cloud-preview-known.png", 32, (136, 36, 155, 255))
        (chosen / "notes.md").write_text("Synthetic included note.", encoding="utf-8")
        (denied / "secret.md").write_text("Synthetic excluded note.", encoding="utf-8")
        (corpus / "outside-report.md").write_text("outsideexclusivebody", encoding="utf-8")
        subprocess.run([str(BUNDLE / "Resources/lumen"), "--db", str(root / "index.sqlite"),
                        "index", "--root", str(corpus), "--deny", str(denied), "--separate-content"],
                       check=True, timeout=15, stdout=subprocess.DEVNULL)
        run(root, "en")
        if snapshots:
            snapshots.mkdir(parents=True, exist_ok=True)
            for image in root.glob("lumen-inline-*.png"):
                shutil.copyfile(image, snapshots / image.name)


def verify_image_search(fixtures, projector, gemma_home, snapshots):
    with tempfile.TemporaryDirectory(prefix="lumen-image-gui-") as tmp:
        root = Path(tmp).resolve()
        corpus = root / "corpus"
        chosen = corpus / "Chosen"
        chosen.mkdir(parents=True)
        for name in ("7e3d.png", "93a2.png", "a48f.png", "db1c.png"):
            shutil.copyfile(fixtures / name, chosen / name)
        (corpus / "sentinel-local-note.txt").write_text("Synthetic name search.", encoding="utf-8")
        (root / "projector-path").write_text(str(projector.resolve()), encoding="utf-8")
        (root / "image-scenario").touch()
        if snapshots:
            (root / "capture-preview").touch()
        subprocess.run([str(BUNDLE / "Resources/lumen"), "--db", str(root / "index.sqlite"),
                        "index", "--root", str(corpus), "--separate-content"],
                       check=True, timeout=15, stdout=subprocess.DEVNULL)
        run(root, "zh", gemma_home=gemma_home)
        if snapshots:
            snapshots.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / "lumen-image-search-preview.png", snapshots / "lumen-image-search-preview.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch-engine", type=Path, help="Also test an integrated lumen binary with persisted watch scopes")
    parser.add_argument("--real-gemma", type=Path,
                        help="Also verify the signed GUI with pinned offline Gemma resources in this directory")
    parser.add_argument("--content-only", action="store_true", help="Only verify selected content folders and native PDF page opening")
    parser.add_argument("--query-syntax", action="store_true", help="Also verify multiword and bare-extension queries in the unified field")
    parser.add_argument("--external-volumes", action="store_true", help="Run only the synthetic external volume panel scenario")
    parser.add_argument("--image-fixtures", type=Path, help="Directory of opaque-filename image fixtures")
    parser.add_argument("--image-projector", type=Path, help="Pinned local vision projector (requires --real-gemma)")
    parser.add_argument("--snapshots", type=Path, help="Save offscreen PNGs to this directory")
    args = parser.parse_args()
    if args.watch_engine and not args.watch_engine.is_file():
        parser.error("--watch-engine must point to a lumen binary")
    if args.real_gemma and not args.real_gemma.is_dir():
        parser.error("--real-gemma must point to a pinned Gemma resource directory")
    if not APP.is_file():
        raise SystemExit("Build the app first with scripts/build-app.sh")
    if args.image_projector or args.image_fixtures:
        if not args.real_gemma or not args.image_projector or not args.image_fixtures:
            parser.error("image smoke requires --image-fixtures, --image-projector and --real-gemma")
        verify_image_search(args.image_fixtures, args.image_projector, args.real_gemma.resolve(), args.snapshots)
        return
    if args.external_volumes:
        with tempfile.TemporaryDirectory(prefix="lumen-gui-volumes-") as tmp:
            root = Path(tmp).resolve()
            make_corpus(root)
            fixture = install_fixture(root)
            (root / "external-volume-scenario").touch()
            subprocess.run([str(fixture), "--db", str(root / "index.sqlite"),
                            "index", "--root", str(root / "corpus")],
                           check=True, timeout=15, capture_output=True)
            run(root, "en")
        return
    verify_content_pipeline(args.snapshots)
    if args.content_only:
        return
    with tempfile.TemporaryDirectory(prefix="lumen-gui-actions-") as tmp:
        root = Path(tmp).resolve()
        make_corpus(root)
        make_action_probe(root)
        (root / "corpus/Lumen Action Probe notes.txt").write_text("Synthetic unified search fixture.", encoding="utf-8")
        (root / "action-scenario").touch()
        (root / "quicklinks-scenario").touch()
        if args.query_syntax:
            fixtures = root / "corpus"
            for name in ("成都 卫健委.PPTX", "卫健委成都方案.pptx", "Other project.pptx",
                         "成都 卫健委.pptx.bak", "成都情况.txt"):
                (fixtures / name).write_text("Synthetic query fixture.", encoding="utf-8")
            (fixtures / "成都 卫健委目录.pptx").mkdir()
            (root / "syntax-scenario").touch()

        if args.snapshots:
            (root / "capture-icons").touch()
        verify_gui_translation(root, "zh")
        if args.snapshots:
            args.snapshots.mkdir(parents=True, exist_ok=True)
            for image in root.glob("lumen-*.png"):
                shutil.copyfile(image, args.snapshots / image.name)
    with tempfile.TemporaryDirectory(prefix="lumen-gui-") as tmp:
        root = Path(tmp)
        make_corpus(root)
        environment = os.environ.copy()
        environment.pop("LUMEN_GEMMA_TEST_HOME", None)
        subprocess.run([str(APP), "--verify-resident-startup", str(root), "en"], check=True, env=environment, timeout=10)
        run(root, "en")
        run(root, "zh")
    with tempfile.TemporaryDirectory(prefix="lumen-gui-") as tmp:
        root = Path(tmp)
        make_corpus(root)
        if args.snapshots:
            (root / "capture-snapshots").touch()
            design = root / "corpus/Design"
            design.mkdir()
            for name in ("Design brief.md", "Design notes.txt", "Design review.md", "Design spec.md",
                         "Design references.md", "Design accessibility.md", "Design decisions.md",
                         "Design prototype.md", "Design options.md"):
                (design / name).write_text("Synthetic design fixture.", encoding="utf-8")
        crowd = root / "corpus/Examples crowded needle fixtures"
        crowd.mkdir()
        for index in range(70):
            (crowd / f"item-{index:02}.txt").write_text("Weak path fixture.", encoding="utf-8")
        (root / "corpus/crowded needle spec.txt").write_text("Strong filename fixture.", encoding="utf-8")
        (root / "corpus/body-match.md").write_text("A crowded needle reference in the body.", encoding="utf-8")
        install_fixture(root)
        run(root, "zh")
        if args.snapshots:
            args.snapshots.mkdir(parents=True, exist_ok=True)
            for name in ("lumen-idle-light.png", "lumen-results-light.png", "lumen-results-dark.png"):
                shutil.copyfile(root / name, args.snapshots / name)
        run(root, "en")
    with tempfile.TemporaryDirectory(prefix="lumen-gui-auto-index-") as tmp:
        root = Path(tmp).resolve()
        make_corpus(root)
        install_fixture(root)
        (root / "automatic-index-scenario").touch()
        run(root, "en")
    with tempfile.TemporaryDirectory(prefix="lumen-gui-settings-") as tmp:
        root = Path(tmp).resolve()
        make_corpus(root)
        protected = root / "corpus/Scoped/Allowed Child"
        protected.mkdir(parents=True)
        (protected / "protected-neighbor.md").write_text("Synthetic scope test.", encoding="utf-8")
        fixture = install_fixture(root)
        (root / "settings-scenario").touch()
        if args.snapshots:
            (root / "capture-settings").touch()
        subprocess.run([str(fixture), "--db", str(root / "index.sqlite"), "index",
                        "--root", str(root / "corpus"), "--deny", str(root / "corpus/Excluded")],
                       check=True, timeout=15, capture_output=True)
        public_status = subprocess.check_output([str(BUNDLE / "Resources/lumen"), "--db",
                                                 str(root / "index.sqlite"), "status"], timeout=10)
        assert "scope" not in json.loads(public_status), "ordinary status exposed directory rules"
        run(root, "en")
        if args.snapshots:
            for image in root.glob("settings-*.png"):
                shutil.copyfile(image, args.snapshots / image.name)
    for documents in (True, False):
        with tempfile.TemporaryDirectory(prefix="lumen-gui-migrate-") as tmp:
            root = Path(tmp).resolve()
            make_corpus(root)
            fixture = install_fixture(root)
            for marker in ("legacy-bge-consent", "gemma-present", "finish-documents"):
                (root / marker).touch()
            subprocess.run([str(fixture), "--db", str(root / "index.sqlite"), "index",
                            "--root", str(root / "corpus"), *(["--documents"] if documents else [])],
                           check=True, timeout=15, capture_output=True)
            (root / "hold-startup-watch").touch()
            run(root, "en")
    if args.watch_engine:
        help_text = subprocess.check_output([str(args.watch_engine.resolve()), "watch", "--help"], text=True, timeout=10)
        with tempfile.TemporaryDirectory(prefix="lumen-gui-") as tmp:
            root = Path(tmp)
            make_corpus(root)
            (root / "watch-engine").symlink_to(args.watch_engine.resolve())
            if "--progress" in help_text:
                (root / "verify-engine-progress").touch()
            run(root, "en")
            (root / "verify-engine-progress").unlink(missing_ok=True)
            run(root, "zh")
        with tempfile.TemporaryDirectory(prefix="lumen-gui-") as tmp:
            root = Path(tmp).resolve()
            make_corpus(root)
            database = root / "index.sqlite"
            subprocess.run([str(BUNDLE / "Resources/lumen"), "--db", str(database),
                            "index", "--root", str(root / "corpus")],
                           check=True, timeout=15, stdout=subprocess.DEVNULL)
            with sqlite3.connect(database) as connection:
                connection.execute("DELETE FROM info WHERE key='scope'")
            (root / "legacy-expected").touch()
            (root / "watch-engine").symlink_to(args.watch_engine.resolve())
            run(root, "en")


    if args.real_gemma:
        with tempfile.TemporaryDirectory(prefix="lumen-gui-gemma-") as tmp:
            root = Path(tmp).resolve()
            corpus = root / "corpus"
            corpus.mkdir()
            (corpus / "entry-a.md").write_text("Orient the solar panel toward the midday sun.", encoding="utf-8")
            (corpus / "entry-b.md").write_text("给闹钟换上新的电池以后重新调准时间。", encoding="utf-8")
            (root / "actual-gemma").touch()
            subprocess.run([str(BUNDLE / "Resources/lumen"), "--db", str(root / "index.sqlite"),
                            "index", "--root", str(corpus), "--documents"], check=True,
                           timeout=15, stdout=subprocess.DEVNULL)
            run(root, "zh", gemma_home=args.real_gemma.resolve())


if __name__ == "__main__":
    main()
