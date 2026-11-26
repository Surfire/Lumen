#!/usr/bin/env python3
"""Headless smoke of the signed .app resources using an isolated synthetic corpus."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "target/Lumen.app"
RES = APP / "Contents/Resources"


def make_pdf(path):
    stream = b"BT /F1 12 Tf 72 700 Td (Independent PDF extraction evidence) Tj ET"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    content = b"%PDF-1.4\n"
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(content))
        content += b"%d 0 obj\n%s\nendobj\n" % (i, obj)
    start = len(content)
    content += b"xref\n0 %d\n0000000000 65535 f \n" % (len(offsets) + 1)
    content += b"".join(b"%010d 00000 n \n" % off for off in offsets)
    content += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(offsets) + 1, start)
    path.write_bytes(content)


def main():
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], check=True)
    for retired in ("LumenLocalEmbedding", "local-bge.py", "lumen-extensions"):
        assert not os.path.lexists(RES / retired), f"retired resource still bundled: {retired}"
    with tempfile.TemporaryDirectory(prefix="lumen-app-smoke-", dir="/tmp") as d:
        corpus = Path(d) / "corpus"
        corpus.mkdir()
        make_pdf(corpus / "example.pdf")
        subjects = {
            "closer.md": "The physician ordered a follow-up examination for the patient.",
            "other.md": "The rocket blasted off from the launchpad toward Jupiter.",
        }
        for file, content in subjects.items():
            (corpus / file).write_text(content, encoding="utf-8")
        argv = [str(RES / "lumen"), "--db", d + "/index.sqlite"]
        def run(*args):
            return json.loads(subprocess.check_output(argv + list(args), timeout=30))
        scan = run("index", "--root", str(corpus), "--documents", "--pdf-helper", str(RES / "LumenPdfExtractor"))
        assert scan["documents"] == 3 and scan["documents_not_read"] == 0, scan
        assert run("query", "PDF extraction", "--mode", "text")[0]["name"] == "example.pdf"
        protocol = subprocess.check_output(argv + ["serve"], input=b'{"id":42,"query":"PDF extraction","mode":"all"}\n', timeout=10)
        assert json.loads(protocol)["hits"][0]["name"] == "example.pdf"
        status = run("status", "--include-scope")
        assert status["documents"] == 3 and status["scope"]["documents"] is True, status
        assert len(status["scope"]["roots"]) == 1, status
        print(json.dumps({
            "headless_app_resources": "PASS",
            "documents": scan["documents"],
            "status_items": status["items"],
            "GUI_launched": False,
        }, indent=2))


if __name__ == "__main__":
    main()
