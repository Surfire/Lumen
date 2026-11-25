use serde_json::Value;
use std::{
    ffi::{CStr, OsStr},
    fs,
    io::Write,
    os::unix::ffi::OsStrExt,
    path::PathBuf,
    process::{Command, Stdio},
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let mut template = *b"/tmp/lumen-test-XXXXXX\0";
        // mkdtemp mutates this writable C template and atomically creates a
        // private directory, even when tests start in the same clock tick.
        let path = unsafe { libc::mkdtemp(template.as_mut_ptr().cast()) };
        assert!(
            !path.is_null(),
            "mkdtemp: {}",
            std::io::Error::last_os_error()
        );
        let path = unsafe { CStr::from_ptr(path) }.to_bytes();
        let dir = PathBuf::from(OsStr::from_bytes(path));
        Self(dir)
    }
    fn cli(&self) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_lumen"));
        cmd.arg("--db").arg(self.0.join("test.sqlite"));
        cmd
    }
    fn run(&self, args: &[&str]) -> Value {
        let out = self.cli().args(args).output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

const WORD_NS: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

fn word_body(content: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="{WORD_NS}"><w:body>{content}<w:sectPr/></w:body></w:document>"#
    )
}

fn docx_fixture(path: &std::path::Path, xml: &str, target: &str, external: bool) {
    let file = fs::File::create(path).unwrap();
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    zip.start_file("[Content_Types].xml", options).unwrap();
    let part = target.strip_prefix('/').unwrap_or(target);
    let main = if external { "word/document.xml" } else { part };
    write!(zip, r#"<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Override PartName="/{main}" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>"#).unwrap();
    zip.start_file("_rels/.rels", options).unwrap();
    let mode = if external {
        r#" TargetMode="External""#
    } else {
        ""
    };
    write!(zip, r#"<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="{target}"{mode}/>
</Relationships>"#).unwrap();
    zip.start_file(main, options).unwrap();
    zip.write_all(xml.as_bytes()).unwrap();
    zip.finish().unwrap();
}

#[test]
fn docx_full_text_is_optional_and_respects_scope() {
    let f = Fixture::new();
    let root = f.0.join("scope");
    let provider = root.join("Library/CloudStorage/OneDrive-Test");
    let deny = root.join("denied");
    fs::create_dir_all(&provider).unwrap();
    fs::create_dir(&deny).unwrap();
    let document = word_body(
        r#"<w:p><w:r><w:t>Project</w:t></w:r><w:r><w:t xml:space="preserve"> brief &amp; notes</w:t></w:r></w:p>
      <w:tbl><w:tr><w:tc><w:p><w:r><w:t>进度说明</w:t></w:r></w:p></w:tc>
      <w:tc><w:p><w:r><w:t>第三季度研究计划</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
      <w:p><w:r><w:t>Section &#50;</w:t><w:br/><w:t>secondary entry</w:t></w:r></w:p>"#,
    );
    docx_fixture(
        &root.join("Quarterly Report.DOCX"),
        &document,
        "/parts/main.xml",
        false,
    );
    for (directory, marker) in [
        (&provider, "cloud text marker"),
        (&deny, "denied text marker"),
    ] {
        docx_fixture(
            &directory.join("restricted.docx"),
            &word_body(&format!("<w:p><w:r><w:t>{marker}</w:t></w:r></w:p>")),
            "word/document.xml",
            false,
        );
    }
    let r = root.to_str().unwrap();
    let d = deny.to_str().unwrap();
    assert_eq!(f.run(&["index", "--root", r, "--deny", d])["documents"], 0);
    assert_eq!(
        f.run(&["query", "quarterly report"])[0]["name"],
        "Quarterly Report.DOCX"
    );
    assert_eq!(
        f.run(&["query", "研究计划", "--mode", "text"]),
        serde_json::json!([])
    );

    let stats = f.run(&["index", "--root", r, "--deny", d, "--documents"]);
    assert_eq!(stats["documents"], 1);
    assert_eq!(stats["documents_not_read"], 1);
    for term in [
        "project brief & notes",
        "第三季度研究计划",
        "进度说明",
        "section 2",
        "secondary entry",
    ] {
        let hit = &f.run(&["query", term, "--mode", "text"])[0];
        assert_eq!(hit["name"], "Quarterly Report.DOCX", "{term}");
        assert!(hit.get("page").is_none());
    }
    for term in ["cloud text marker", "denied text marker"] {
        assert_eq!(
            f.run(&["query", term, "--mode", "text"]),
            serde_json::json!([])
        );
    }
    assert_eq!(
        f.run(&["query", "restricted.docx"])[0]["availability"],
        "provider_metadata_only"
    );
    assert_eq!(f.run(&["index", "--root", r, "--deny", d])["documents"], 0);
    assert_eq!(
        f.run(&["query", "研究计划", "--mode", "text"]),
        serde_json::json!([])
    );
}

#[test]
fn docx_rejects_dtd_external_targets_and_oversized_xml() {
    let f = Fixture::new();
    let root = f.0.join("scope");
    fs::create_dir(&root).unwrap();
    let document = word_body("<w:p><w:r><w:t>body should stay out</w:t></w:r></w:p>");
    let dtd = document.replace("<w:document", "<!DOCTYPE document []><w:document");
    docx_fixture(
        &root.join("with-dtd.docx"),
        &dtd,
        "word/document.xml",
        false,
    );
    docx_fixture(
        &root.join("external-target.docx"),
        &document,
        "https://example.invalid/document.xml",
        true,
    );
    let giant = document.replace("body should stay out", &"x".repeat(8 * 1024 * 1024));
    docx_fixture(
        &root.join("over-limit.docx"),
        &giant,
        "word/document.xml",
        false,
    );
    let r = root.to_str().unwrap();
    let stats = f.run(&["index", "--root", r, "--documents"]);
    assert_eq!(stats["documents"], 0);
    assert_eq!(stats["documents_not_read"], 3);
    assert_eq!(
        f.run(&["query", "body should stay out", "--mode", "text"]),
        serde_json::json!([])
    );
    for name in ["with-dtd.docx", "external-target.docx", "over-limit.docx"] {
        assert_eq!(f.run(&["query", name])[0]["name"], name);
    }
}

#[test]
fn native_entries_names_pinyin_and_chinese_full_text() {
    let f = Fixture::new();
    let root = f.0.join("松林月报");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("学术演示.md"), "这是科室合作分工方案及研究计划。").unwrap();
    fs::write(root.join("Équipe.txt"), "unicode normalization").unwrap();
    let r = root.to_str().unwrap();
    let scan = f.run(&["index", "--root", r, "--documents"]);
    assert_eq!(scan["items"], 3);
    assert_eq!(scan["documents"], 2);
    assert_eq!(
        f.run(&["query", "合作分工", "--mode", "text"])[0]["name"],
        "学术演示.md"
    );
    assert_eq!(
        f.run(&["query", "合作", "--mode", "text"])[0]["matched_by"],
        "text"
    );
    assert_eq!(f.run(&["query", "e\u{301}quipe"])[0]["name"], "Équipe.txt");
    #[cfg(target_os = "macos")]
    {
        assert_eq!(f.run(&["query", "slyb"])[0]["name"], "松林月报");
        assert_eq!(f.run(&["query", "xueshuyanshi"])[0]["name"], "学术演示.md");
    }
}

#[test]
fn deny_and_cloud_semantics_without_real_provider_access() {
    let f = Fixture::new();
    let root = f.0.join("root");
    let provider = root.join("Library/CloudStorage/OneDrive-Test");
    let deny = root.join("denied");
    fs::create_dir_all(&provider).unwrap();
    fs::create_dir(&deny).unwrap();
    fs::write(
        provider.join("air-only.md"),
        "THIS-CONTENT-MUST-NOT-BE-INDEXED",
    )
    .unwrap();
    fs::write(deny.join("excluded.txt"), "SHOULD-NOT-BE-READ").unwrap();
    fs::write(root.join("local.md"), "Content is opt-in.").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&deny, root.join("shortcut")).unwrap();
    let r = root.to_str().unwrap();
    let d = deny.to_str().unwrap();
    f.run(&[
        "index",
        "--root",
        r,
        "--documents",
        "--allow",
        r,
        "--deny",
        d,
    ]);
    assert_eq!(
        f.run(&["query", "air-only"])[0]["availability"],
        "provider_metadata_only"
    );
    for query in ["excluded", "shortcut"] {
        assert!(f.run(&["query", query]).as_array().unwrap().is_empty());
    }
    assert!(
        f.run(&[
            "query",
            "THIS-CONTENT-MUST-NOT-BE-INDEXED",
            "--mode",
            "text"
        ])
        .as_array()
        .unwrap()
        .is_empty()
    );
    assert_eq!(
        f.run(&["query", "Content is opt-in", "--mode", "text"])[0]["name"],
        "local.md"
    );
    f.run(&["index", "--root", r]);
    assert!(
        f.run(&["query", "Content is opt-in", "--mode", "text"])
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn explicit_rename_delete_reindex_and_native_launcher_transport() {
    let f = Fixture::new();
    let root = f.0.join("root");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("obsolete.txt"), "old").unwrap();
    let r = root.to_str().unwrap();
    f.run(&["index", "--root", r]);
    assert_eq!(f.run(&["query", "obsolete"])[0]["name"], "obsolete.txt");
    fs::rename(root.join("obsolete.txt"), root.join("current.txt")).unwrap();
    f.run(&["index", "--root", r]);
    assert!(f.run(&["query", "obsolete"]).as_array().unwrap().is_empty());
    let mut p = f
        .cli()
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut sin = p.stdin.take().unwrap();
    writeln!(sin, "{{\"id\":17,\"query\":\"current\",\"mode\":\"all\"}}").unwrap();
    writeln!(sin, "{{\"id\":18,\"query\":\"obsolete\"}}").unwrap();
    drop(sin);
    let out = p.wait_with_output().unwrap();
    let res: Vec<Value> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|r| serde_json::from_str(r).unwrap())
        .collect();
    assert_eq!(res[0]["id"], 17);
    assert_eq!(res[0]["hits"][0]["name"], "current.txt");
    assert!(res[1]["hits"].as_array().unwrap().is_empty());
}

#[test]
fn disk_name_order_migrates_existing_indexes_and_respects_scope() {
    let f = Fixture::new();
    let root = f.0.join("scope");
    let exact = root.join("market");
    let denied = root.join("denied");
    fs::create_dir_all(&exact).unwrap();
    fs::create_dir_all(&denied).unwrap();
    fs::write(exact.join("child"), "").unwrap();
    fs::write(denied.join("market-a"), "").unwrap();
    for name in ["market-b", "market-c", "xmarket"] {
        fs::write(root.join(name), "").unwrap();
    }

    let r = root.to_str().unwrap();
    f.run(&["index", "--root", r]);
    let query = || f.run(&["query", "market", "--limit", "3"]);
    let indexed = query();
    assert_eq!(indexed[0]["name"], "market");
    assert_eq!(indexed[1]["name"], "market-a");
    assert_eq!(indexed[2]["name"], "market-b");

    let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
    db.execute("DROP INDEX item_name_order", []).unwrap();
    assert_eq!(query(), indexed);

    f.run(&["index", "--root", r, "--deny", denied.to_str().unwrap()]);
    let migrated: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='item_name_order')",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(migrated);
    let narrowed = query();
    assert_eq!(narrowed[0]["name"], "market");
    assert_eq!(narrowed[1]["name"], "market-b");
    assert_eq!(narrowed[2]["name"], "market-c");
    let backed_by_fts = f.run(&["query", "market", "--limit", "6"]);
    assert_eq!(backed_by_fts[3]["name"], "xmarket");
    assert_eq!(backed_by_fts[4]["name"], "child");
    assert_eq!(backed_by_fts[4]["matched_by"], "path");
}

#[test]
fn two_han_disk_search_preserves_rank_suffixes_and_scope() {
    let f = Fixture::new();
    let root = f.0.join("scope");
    let exact = root.join("鹿鸣");
    let denied = root.join("denied");
    fs::create_dir_all(&exact).unwrap();
    fs::create_dir_all(&denied).unwrap();
    fs::write(exact.join("path-only.txt"), "").unwrap();
    fs::write(denied.join("隐藏鹿鸣"), "").unwrap();
    for name in ["鹿鸣前缀.txt", "新鹿鸣资料.txt", "尾鹿鸣"] {
        fs::write(root.join(name), "").unwrap();
    }
    let r = root.to_str().unwrap();
    f.run(&["index", "--root", r]);
    let query = || f.run(&["query", "--mode", "name", "--limit", "60", "--", "鹿鸣"]);
    let accelerated = query();
    let names = |result: &Value| {
        result
            .as_array()
            .unwrap()
            .iter()
            .map(|hit| hit["name"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        names(&accelerated),
        [
            "鹿鸣",
            "鹿鸣前缀.txt",
            "尾鹿鸣",
            "隐藏鹿鸣",
            "新鹿鸣资料.txt",
            "path-only.txt"
        ]
    );
    assert_eq!(accelerated[5]["matched_by"], "path");

    let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
    db.execute("DROP INDEX item_name_han_ending", []).unwrap();
    assert_eq!(query(), accelerated);
    f.run(&["index", "--root", r, "--deny", denied.to_str().unwrap()]);
    assert_eq!(
        names(&query()),
        [
            "鹿鸣",
            "鹿鸣前缀.txt",
            "尾鹿鸣",
            "新鹿鸣资料.txt",
            "path-only.txt"
        ]
    );

    // A retained FTS posting cannot make an unverified row visible.
    db.execute(
        "UPDATE item SET availability='unverified' WHERE display='新鹿鸣资料.txt'",
        [],
    )
    .unwrap();
    assert_eq!(
        names(&query()),
        ["鹿鸣", "鹿鸣前缀.txt", "尾鹿鸣", "path-only.txt"]
    );
}

#[test]
fn deny_invalid_database_without_touching_it() {
    let f = Fixture::new();
    let db = f.0.join("test.sqlite");
    fs::write(&db, "this file does not belong to Lumen").unwrap();
    let out = f
        .cli()
        .args(["index", "--root", f.0.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert_eq!(
        fs::read(&db).unwrap(),
        b"this file does not belong to Lumen"
    );
}

#[cfg(target_os = "macos")]
mod live {
    use super::*;
    use std::{
        io::{BufRead, BufReader},
        os::unix::fs::{MetadataExt, PermissionsExt, symlink},
        path::Path,
        process::{Child, ChildStdin},
        sync::mpsc::{self, Receiver},
        thread,
        time::{Duration, Instant},
    };

    struct Process {
        child: Child,
        output: Receiver<String>,
    }

    impl Process {
        fn launch(command: &mut Command) -> Self {
            let mut child = command.stdout(Stdio::piped()).spawn().unwrap();
            let stdout = child.stdout.take().unwrap();
            let (sender, output) = mpsc::channel();
            thread::spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if sender.send(line).is_err() {
                        break;
                    }
                }
            });
            Self { child, output }
        }

        fn json(&self) -> Value {
            let line = self.output.recv_timeout(Duration::from_secs(10)).unwrap();
            serde_json::from_str(&line).unwrap()
        }
    }

    impl Drop for Process {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    fn watch(f: &Fixture, args: &[&str]) -> Process {
        let process = Process::launch(f.cli().arg("watch").args(args).stdin(Stdio::null()));
        assert_eq!(process.json(), serde_json::json!({"event": "ready"}));
        process
    }

    struct Serve {
        process: Process,
        input: ChildStdin,
        id: u64,
    }

    impl Serve {
        fn new(f: &Fixture) -> Self {
            let mut process = Process::launch(f.cli().arg("serve").stdin(Stdio::piped()));
            let input = process.child.stdin.take().unwrap();
            Self {
                process,
                input,
                id: 0,
            }
        }

        fn hits(&mut self, term: &str, mode: &str) -> Value {
            self.id += 1;
            let request = serde_json::json!({"id": self.id, "query": term, "mode": mode});
            writeln!(self.input, "{request}").unwrap();
            let mut response = self.process.json();
            assert_eq!(response["id"], self.id);
            assert!(response["hits"].is_array(), "{response}");
            response["hits"].take()
        }

        fn names(&mut self, term: &str, mode: &str) -> Vec<String> {
            self.hits(term, mode)
                .as_array()
                .unwrap()
                .iter()
                .map(|hit| hit["name"].as_str().unwrap().to_owned())
                .collect()
        }

        fn wait(&mut self, term: &str, mode: &str, expected: &[&str]) {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let actual = self.names(term, mode);
                if actual == expected {
                    return;
                }
                assert!(
                    Instant::now() < deadline,
                    "{term:?}: expected {expected:?}, got {actual:?}"
                );
                thread::sleep(Duration::from_millis(20));
            }
        }
    }

    #[test]
    fn validates_only_the_current_scoped_hit_for_an_action() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let file = root.join("notes.txt");
        let folder = root.join("directory");
        fs::create_dir_all(&folder).unwrap();
        fs::write(&file, "document-backed action proof").unwrap();
        let r = root.to_str().unwrap();
        f.run(&["index", "--root", r, "--documents"]);
        let valid = |path: &Path, kind: &str, stamp: Option<&str>| {
            let mut args = vec!["validate-hit", "--kind", kind, "--availability", "local"];
            if let Some(stamp) = stamp {
                args.extend(["--document-stamp", stamp]);
            }
            args.extend(["--", path.to_str().unwrap()]);
            f.run(&args) == serde_json::json!({"valid":true})
        };
        let text = f.run(&["query", "--mode", "text", "action proof"]);
        let stamp = text[0]["document_stamp"].as_str().unwrap();
        assert!(valid(&file, "file", None));
        assert!(valid(&file, "file", Some(stamp)));
        assert!(valid(&folder, "directory", None));
        assert!(!valid(&file, "directory", None));
        assert!(!valid(&root.join("directory/../notes.txt"), "file", None));

        // A file can change before the watcher commits, and stale preview
        // stamps must fail even if the indexed path still exists.
        fs::write(&file, "replacement document").unwrap();
        assert!(!valid(&file, "file", Some(stamp)));
        fs::remove_file(&file).unwrap();
        assert!(!valid(&file, "file", None));
        let outside = f.0.join("outside.txt");
        fs::write(&outside, "outside scope").unwrap();
        symlink(&outside, &file).unwrap();
        assert!(!valid(&file, "file", None));
        assert!(!valid(&outside, "file", None));

        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute(
            "UPDATE item SET availability='unverified' WHERE display='directory'",
            [],
        )
        .unwrap();
        assert!(!valid(&folder, "directory", None));
        f.run(&[
            "index",
            "--root",
            r,
            "--deny",
            folder.to_str().unwrap(),
            "--documents",
        ]);
        assert!(!valid(&folder, "directory", None));
    }

    #[test]
    fn launcher_queries_require_all_words_and_filter_real_extensions() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let chengdu = root.join("成都");
        let excluded = root.join("excluded");
        fs::create_dir_all(&chengdu).unwrap();
        fs::create_dir_all(&excluded).unwrap();
        fs::create_dir(root.join("成都卫健委.pptx")).unwrap();
        for file in [
            "成都 卫健委.PPTX",
            "卫健委成都方案.pptx",
            "成都情况.pptx",
            "成都卫健委旧版.pptx",
            "成都卫健委.pptx.bak",
            "成都卫健委pptx.txt",
            "松林卫生Report.pptx",
            "鹿鸣",
        ] {
            fs::write(root.join(file), "").unwrap();
        }
        fs::write(chengdu.join("卫健委通知.pptx"), "").unwrap();
        fs::write(chengdu.join("鹿鸣资料.md"), "鹿鸣专刊").unwrap();
        fs::write(excluded.join("成都卫健委隐藏.pptx"), "").unwrap();
        fs::write(root.join("words.txt"), "卫健委关于新的 成都 公告").unwrap();
        fs::write(root.join("missing.txt"), "成都消息含有 pptx 这个词").unwrap();
        fs::write(root.join("letters.md"), "成都 卫健委，正文也写有 pptx").unwrap();
        let r = root.to_str().unwrap();
        f.run(&[
            "index",
            "--root",
            r,
            "--deny",
            excluded.to_str().unwrap(),
            "--documents",
        ]);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        // Excluded-by-availability FTS candidates must not reappear via either lane.
        db.execute(
            "UPDATE item SET availability='unverified' WHERE display='成都卫健委旧版.pptx'",
            [],
        )
        .unwrap();
        let mut serve = Serve::new(&f);

        let names = serve.names("成都　 卫健委   pptx", "name");
        assert_eq!(
            names,
            ["成都 卫健委.PPTX", "卫健委成都方案.pptx", "卫健委通知.pptx"]
        );
        assert_eq!(serve.names("卫健委 .PpTx 成都", "name"), names);
        let rank = serve.hits("成都 卫健委 .pptx", "name");
        assert_eq!(rank[0]["matched_by"], "name");
        assert_eq!(rank[2]["matched_by"], "path");
        assert_eq!(
            serve.names("\"成都 卫健委\" pptx", "name"),
            ["成都 卫健委.PPTX"]
        );
        assert_eq!(
            serve.names("成都 \"pptx\"", "name"),
            [
                "成都情况.pptx",
                "成都卫健委.pptx",
                "成都 卫健委.PPTX",
                "成都卫健委pptx.txt",
                "成都卫健委.pptx.bak",
                "卫健委成都方案.pptx",
                "卫健委通知.pptx"
            ]
        );
        assert_eq!(
            serve.names("ＳＯＮＧＬＩＮ report .pptx", "name"),
            ["松林卫生Report.pptx"]
        );
        assert_eq!(serve.names("鹿鸣", "name"), ["鹿鸣", "鹿鸣资料.md"]);
        assert_eq!(serve.names("鹿鸣 成都", "name"), ["鹿鸣资料.md"]);
        assert_eq!(serve.names("成都 鹿鸣", "name"), ["鹿鸣资料.md"]);
        assert!(serve.names("成都 pptx pdf", "all").is_empty());
        assert_eq!(serve.names("ＰＰＴＸ", "name").len(), 5);

        assert_eq!(serve.names("成都 卫健委 txt", "text"), ["words.txt"]);
        assert_eq!(serve.names("卫健委 .TXT 成都", "text"), ["words.txt"]);
        assert!(serve.names("\"成都 卫健委\" txt", "text").is_empty());
        assert_eq!(serve.names("“成都 卫健委” md", "text"), ["letters.md"]);
        assert_eq!(serve.names("成都 卫健委 \"pptx\"", "text"), ["letters.md"]);
        assert!(serve.names("成都 卫健委 pptx", "text").is_empty());
        assert_eq!(
            f.run(&["query", "--mode", "semantic", "成都 卫健委 pptx"]),
            serde_json::json!([])
        );
        assert!(serve.names("成都 卫健委 .pptx", "semantic").is_empty());
        db.execute(
            "UPDATE item SET availability='unverified' WHERE display='卫健委成都方案.pptx'",
            [],
        )
        .unwrap();
        assert_eq!(
            serve.names("成都 卫健委 pptx", "name"),
            ["成都 卫健委.PPTX", "卫健委通知.pptx"]
        );
    }

    #[test]
    fn running_serve_observes_committed_scope_and_name_updates() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let named = root.join("market");
        let denied = root.join("denied");
        fs::create_dir_all(&named).unwrap();
        fs::create_dir_all(&denied).unwrap();
        fs::write(root.join("market-a"), "").unwrap();
        fs::write(root.join("pre-market"), "").unwrap();
        fs::write(named.join("path-only"), "").unwrap();
        fs::write(denied.join("market-private"), "").unwrap();
        let r = root.to_str().unwrap();
        let deny = denied.to_str().unwrap();
        f.run(&["index", "--root", r]);

        let mut serve = Serve::new(&f);
        assert_eq!(
            serve.names("market", "name"),
            [
                "market",
                "market-a",
                "market-private",
                "pre-market",
                "path-only"
            ]
        );
        assert_eq!(serve.names("market/p", "name"), ["path-only"]);
        fs::rename(root.join("pre-market"), root.join("market-new")).unwrap();
        fs::remove_file(named.join("path-only")).unwrap();
        f.run(&["index", "--root", r, "--deny", deny]);
        assert_eq!(
            serve.names("market", "name"),
            ["market", "market-a", "market-new"]
        );
        assert!(serve.names("market/p", "name").is_empty());
        for _ in 0..3 {
            assert!(serve.names("market-private", "all").is_empty());
            assert!(serve.names("pre-market", "name").is_empty());
        }

        // A failed manual scan commits an unverified state for old rows.
        fs::rename(&root, f.0.join("renamed")).unwrap();
        let failed = f
            .cli()
            .args(["index", "--root", r, "--deny", deny])
            .output()
            .unwrap();
        assert!(!failed.status.success());
        assert!(serve.names("market", "all").is_empty());
    }

    fn executable(path: &Path, script: &str) {
        fs::write(path, script).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn bundled_pdf_upgrade_restamps_legacy_once_and_keeps_compatible_vectors() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let db = f.0.join("test.sqlite");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("review.pdf"), b"%PDF-synthetic input").unwrap();
        let copier = |name: &str| {
            let resources = f.0.join(name).join("Contents/Resources");
            fs::create_dir_all(&resources).unwrap();
            let engine = resources.join("lumen");
            fs::copy(env!("CARGO_BIN_EXE_lumen"), &engine).unwrap();
            (engine, resources.join("LumenPdfExtractor"))
        };
        let (first_engine, first_helper) = copier("Lumen Old.app");
        let (second_engine, second_helper) = copier("Lumen Current.app");
        let installs = [&first_helper, &second_helper];
        for helper in installs {
            executable(
                helper,
                "#!/bin/sh\ncat >/dev/null\n echo called >> \"$0.calls\"\nif [ \"$1\" = --pages-v1 ]; then printf '[{\"page\":1,\"text\":\"cedar archive review\"}]'; else printf 'cedar archive review\\n'; fi\n",
            );
        }
        let calls = |helper: &Path| {
            fs::read_to_string(helper.with_extension("calls")).map_or(0, |log| log.lines().count())
        };
        let root = root.to_str().unwrap();
        let docs = ["index", "--root", root, "--documents"];
        let first = first_helper.to_str().unwrap();
        assert_eq!(
            f.run(&[&docs[..], &["--pdf-helper", first]].concat())["documents"],
            1
        );
        assert_eq!(calls(&first_helper), 1);
        let vector_helper = f.0.join("vector-helper");
        executable(
            &vector_helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        assert_eq!(
            f.run(&["embed", "--helper", vector_helper.to_str().unwrap()])["new_embeddings"],
            1
        );
        let raw = rusqlite::Connection::open(&db).unwrap();
        let mut gemma_vector = vec![0_u8; 768 * 4];
        gemma_vector[..4].copy_from_slice(&1.0_f32.to_le_bytes());
        raw.execute(
            "INSERT INTO semantic_vector SELECT ?1,id,?2 FROM semantic_chunk",
            rusqlite::params![lumen::GEMMA_MODEL_ID, gemma_vector],
        )
        .unwrap();
        let counts = || {
            let status = f.run(&["status"]);
            (
                status["embedded_chunks"].as_u64().unwrap(),
                status["gemma"]["embedded_chunks"].as_u64().unwrap(),
            )
        };
        let stamp = || {
            raw.query_row("SELECT stamp FROM document_state", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap()
        };
        let saved = || {
            raw.query_row("SELECT value FROM info WHERE key='scope'", [], |r| {
                Ok(serde_json::from_str::<Value>(&r.get::<_, String>(0)?).unwrap())
            })
            .unwrap()
        };
        let legacy_stamp = stamp();
        assert!(legacy_stamp.contains("Lumen Old.app"));
        assert_eq!(
            saved()["pdf_helper"],
            fs::canonicalize(&first_helper).unwrap().to_str().unwrap()
        );
        assert_eq!(saved()["pdf_helper_policy"], "manual");
        drop(watch(&f, &[]));
        assert_eq!(calls(&first_helper), 1);

        // Simulate the original release's scope JSON, which did not say
        // whether a bundle-shaped helper came from the app or the CLI.
        raw.execute(
            "UPDATE info SET value=json_remove(value,'$.pdf_helper_policy') WHERE key='scope'",
            [],
        )
        .unwrap();
        let app = |engine: &Path| {
            let mut cmd = Command::new(engine);
            cmd.arg("--db").arg(&db);
            cmd
        };
        let rejected = || {
            let mut process =
                Process::launch(app(&second_engine).arg("watch").stderr(Stdio::piped()));
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if let Some(status) = process.child.try_wait().unwrap() {
                    assert!(!status.success());
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "watch accepted an unauthorized saved app helper"
                );
                thread::sleep(Duration::from_millis(10));
            }
            let error = std::io::read_to_string(process.child.stderr.take().unwrap()).unwrap();
            assert!(
                error.contains("saved scope uses an app PDF extractor"),
                "{error}"
            );
        };
        rejected();
        assert_eq!(stamp(), legacy_stamp);
        assert_eq!(calls(&first_helper), 1);
        assert_eq!(calls(&second_helper), 0);

        // The second installation may migrate the saved scope, but it may
        // only run its own helper. The same verified text preserves vectors.
        let watcher = Process::launch(app(&second_engine).args(["watch", "--bundled-pdf-helper"]));
        assert_eq!(watcher.json(), serde_json::json!({"event":"ready"}));
        drop(watcher);
        assert_eq!(calls(&first_helper), 1);
        assert_eq!(calls(&second_helper), 1);
        let managed_stamp = stamp();
        assert!(managed_stamp.ends_with(":lumen-pdf:pdfkit-text-v2"));
        assert_eq!(saved()["pdf_helper_policy"], "bundled");
        assert!(saved()["pdf_helper"].is_null());
        assert_eq!(counts(), (1, 1));
        rejected();

        // Different absolute path, inode and timestamps, same governed format.
        fs::File::open(&first_helper)
            .unwrap()
            .set_times(
                fs::FileTimes::new().set_modified(std::time::UNIX_EPOCH + Duration::from_secs(1)),
            )
            .unwrap();
        assert_ne!(
            fs::metadata(&first_helper).unwrap().mtime(),
            fs::metadata(&second_helper).unwrap().mtime()
        );
        assert_ne!(
            fs::metadata(&first_helper).unwrap().ino(),
            fs::metadata(&second_helper).unwrap().ino()
        );
        let refresh = |engine: &Path| {
            let output = app(engine)
                .args(docs)
                .arg("--bundled-pdf-helper")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        refresh(&first_engine);
        assert_eq!(stamp(), managed_stamp);
        assert_eq!(calls(&first_helper), 1);
        assert_eq!(counts(), (1, 1));

        // Simulate a persisted incompatible format and a new helper output.
        raw.execute(
            "UPDATE document_state SET stamp=replace(stamp,'pdfkit-text-v2','pdfkit-text-v1')",
            [],
        )
        .unwrap();
        executable(
            &second_helper,
            "#!/bin/sh\ncat >/dev/null\necho called >> \"$0.calls\"\nprintf '[{\"page\":1,\"text\":\"spruce revised passage\"}]'\n",
        );
        refresh(&second_engine);
        assert_eq!(calls(&second_helper), 2);
        assert_eq!(stamp(), managed_stamp);
        assert_eq!(counts(), (0, 0));
        assert_eq!(
            f.run(&["query", "cedar archive", "--mode", "text"]),
            serde_json::json!([])
        );
        assert_eq!(
            f.run(&["query", "spruce revised", "--mode", "text"])[0]["name"],
            "review.pdf"
        );

        // A leaf symlink back to the old app must not act as a bundled helper.
        fs::remove_file(&second_helper).unwrap();
        symlink(&first_helper, &second_helper).unwrap();
        let failed = app(&second_engine)
            .args(docs)
            .arg("--bundled-pdf-helper")
            .output()
            .unwrap();
        assert!(!failed.status.success());
        assert!(String::from_utf8_lossy(&failed.stderr).contains("executable regular file"));
        assert_eq!(calls(&first_helper), 1);
        assert_eq!(stamp(), managed_stamp);
    }

    fn index_progress(f: &Fixture, args: &[&str]) -> (Value, Vec<Value>) {
        let output = f
            .cli()
            .args(["index", "--progress"])
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        // Parse the entire stdout document, so an extra JSONL event fails.
        let summary = serde_json::from_slice(&output.stdout).unwrap();
        let events = String::from_utf8(output.stderr)
            .unwrap()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|event| event["event"] == "progress")
            .collect::<Vec<_>>();
        let mut phases = events
            .iter()
            .map(|event| event["phase"].as_str().unwrap())
            .collect::<Vec<_>>();
        phases.dedup();
        assert_eq!(phases, ["preparing", "scanning", "finalizing", "done"]);
        for pair in events.windows(2) {
            for key in ["entries", "elapsed_ms"] {
                assert!(pair[0][key].as_u64().unwrap() <= pair[1][key].as_u64().unwrap());
            }
        }
        (summary, events)
    }

    #[test]
    fn index_progress_keeps_stdout_atomic_and_estimates_only_a_matching_scope() {
        let f = Fixture::new();
        let root = f.0.join("root");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("fresh-report.txt"), "eligible").unwrap();
        fs::write(root.join(".hidden"), "excluded").unwrap();
        let r = root.to_str().unwrap();

        let (summary, cold) = index_progress(&f, &["--root", r]);
        assert_eq!(summary["items"], 2);
        assert!(
            cold.iter()
                .filter(|e| e["phase"] == "scanning")
                .all(|e| { e.get("estimated_total").is_none() && e.get("eta_seconds").is_none() })
        );
        assert_eq!(cold.last().unwrap()["entries"], 3);
        assert_eq!(cold.last().unwrap()["estimated_total"], 3);
        assert_eq!(cold.last().unwrap()["eta_seconds"], 0);
        assert_eq!(f.run(&["query", "report"])[0]["name"], "fresh-report.txt");

        let (_, refresh) = index_progress(&f, &["--root", r]);
        let estimate = refresh.iter().find(|e| e["phase"] == "scanning").unwrap();
        assert_eq!(estimate["estimated_total"], 3);
        assert_eq!(estimate["estimate_basis"], "previous_scan");

        let excluded = root.join("fresh-report.txt");
        let (_, changed) = index_progress(&f, &["--root", r, "--deny", excluded.to_str().unwrap()]);
        let scanning = changed.iter().find(|e| e["phase"] == "scanning").unwrap();
        assert!(scanning.get("estimated_total").is_none());
        assert!(f.run(&["query", "report"]).as_array().unwrap().is_empty());
    }

    #[test]
    fn index_progress_heartbeats_during_a_slow_document_without_a_precount() {
        let f = Fixture::new();
        let root = f.0.join("root");
        fs::create_dir(&root).unwrap();
        let document = root.join("slow.pdf");
        fs::write(&document, "first synthetic extracted text").unwrap();
        let helper = f.0.join("extractor");
        executable(&helper, "#!/bin/sh\ncat\nsleep 1\n");
        let args = [
            "--root",
            root.to_str().unwrap(),
            "--documents",
            "--pdf-helper",
            helper.to_str().unwrap(),
        ];

        let (_, cold) = index_progress(&f, &args);
        assert!(cold.iter().any(|event| {
            event["phase"] == "scanning"
                && event["elapsed_ms"].as_u64().unwrap() >= 200
                && event["entries"] == 1
                && event["entries_per_second"].is_number()
                && event.get("eta_seconds").is_none()
        }));
        fs::write(&document, "second synthetic extracted text").unwrap();
        let (_, refresh) = index_progress(&f, &args);
        assert!(refresh.iter().any(|event| {
            event["phase"] == "scanning"
                && event["eta_seconds"].is_number()
                && event["estimated_total"] == 2
                && event["estimate_basis"] == "previous_scan"
        }));
    }

    #[test]
    fn watcher_seeds_legacy_catalog_and_resumes_persisted_native_events() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let private = root.join("private");
        fs::create_dir_all(&private).unwrap();
        for name in ["to-rename.txt", "to-delete.txt"] {
            fs::write(root.join(name), name).unwrap();
        }
        fs::write(
            private.join("protected.txt"),
            "historical permissions evidence",
        )
        .unwrap();
        let r = root.to_str().unwrap();
        f.run(&["index", "--root", r, "--documents"]);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let get_info = |key: &str| -> Option<String> {
            use rusqlite::OptionalExtension;
            db.query_row("SELECT value FROM info WHERE key=?1", [key], |row| {
                row.get(0)
            })
            .optional()
            .unwrap()
        };
        assert!(get_info("watch_checkpoint_v1").is_none());
        let seed = watch(&f, &[]);
        let scan = get_info("scan").unwrap();
        let checkpoint = get_info("watch_checkpoint_v1").expect("native startup volume checkpoint");
        drop(seed);
        fs::rename(root.join("to-rename.txt"), root.join("renamed.txt")).unwrap();
        fs::remove_file(root.join("to-delete.txt")).unwrap();
        fs::write(root.join("new-file.txt"), "created offline").unwrap();
        fs::write(root.join("second-new-file.txt"), "created offline too").unwrap();
        thread::sleep(Duration::from_millis(650));

        let resumed = watch(&f, &[]);
        assert_eq!(
            get_info("scan").unwrap(),
            scan,
            "historical replay should not reconcile"
        );
        let current = get_info("watch_checkpoint_v1").unwrap();
        assert_ne!(current, checkpoint);
        let mut serve = Serve::new(&f);
        for query in ["to-rename", "to-delete"] {
            assert!(serve.names(query, "name").is_empty(), "{query}");
        }
        assert_eq!(serve.names("renamed", "name"), ["renamed.txt"]);
        assert_eq!(
            serve.names("second-new-file", "name"),
            ["second-new-file.txt"]
        );
        drop(resumed);

        // A future ID is invalid even when the boot, journal and scope match.
        let mut invalid: Value = serde_json::from_str(&current).unwrap();
        invalid[2] = serde_json::json!(u64::MAX);
        db.execute(
            "UPDATE info SET value=?1 WHERE key='watch_checkpoint_v1'",
            [invalid.to_string()],
        )
        .unwrap();
        let fallback = watch(&f, &[]);
        let refreshed = get_info("scan").unwrap();
        let refreshed: Value = serde_json::from_str(&refreshed).unwrap();
        let scan: Value = serde_json::from_str(&scan).unwrap();
        assert_ne!(refreshed["items"], scan["items"]);
        assert_ne!(
            get_info("watch_checkpoint_v1").unwrap(),
            invalid.to_string()
        );
        drop(fallback);

        if unsafe { libc::geteuid() } != 0 {
            struct RestoreMode<'a>(&'a Path);
            impl Drop for RestoreMode<'_> {
                fn drop(&mut self) {
                    let _ = fs::set_permissions(self.0, fs::Permissions::from_mode(0o700));
                }
            }
            let restore = RestoreMode(&private);
            fs::set_permissions(&private, fs::Permissions::from_mode(0o0)).unwrap();
            thread::sleep(Duration::from_millis(650));
            let closed = watch(&f, &[]);
            let denied_scan: Value = serde_json::from_str(&get_info("scan").unwrap()).unwrap();
            assert!(denied_scan["entries_unreadable"].as_u64().unwrap() > 0);
            assert!(serve.names("protected", "name").is_empty());
            assert!(serve.names("historical permissions", "text").is_empty());
            drop(closed);
            drop(restore);
        }

        let _restricted = watch(
            &f,
            &[
                "--root",
                r,
                "--deny",
                private.to_str().unwrap(),
                "--documents",
            ],
        );
        assert!(serve.names("protected", "all").is_empty());
        assert!(serve.names("historical permissions", "text").is_empty());
    }

    #[test]
    fn watch_progress_preserves_stdout_ready_and_following_updates() {
        let f = Fixture::new();
        let root = f.0.join("root");
        fs::create_dir(&root).unwrap();
        let mut watcher = Process::launch(
            f.cli()
                .args(["watch", "--progress", "--root", root.to_str().unwrap()])
                .stdin(Stdio::null())
                .stderr(Stdio::piped()),
        );
        let stderr = watcher.child.stderr.take().unwrap();
        let (send, receive) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if let Ok(event) = serde_json::from_str::<Value>(&line)
                    && send.send(event).is_err()
                {
                    break;
                }
            }
        });
        assert_eq!(watcher.json(), serde_json::json!({"event":"ready"}));
        assert_eq!(
            receive.recv_timeout(Duration::from_secs(5)).unwrap()["phase"],
            "preparing"
        );
        loop {
            let event = receive.recv_timeout(Duration::from_secs(5)).unwrap();
            if event["phase"] == "done" {
                break;
            }
        }
        fs::write(root.join("live-report.txt"), "updated").unwrap();
        assert_eq!(watcher.json(), serde_json::json!({"event":"updated"}));
        assert_eq!(
            f.run(&["query", "live-report"])[0]["name"],
            "live-report.txt"
        );
    }

    #[test]
    fn native_watch_keeps_serve_current_and_repairs_after_restart() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let projects = root.join("projects");
        let denied = projects.join("denied");
        let provider = root.join("Library/CloudStorage/OneDrive-Test");
        let tree = projects.join("orchard");
        let outside = f.0.join("outside");
        for dir in [&tree, &denied, &provider, &outside] {
            fs::create_dir_all(dir).unwrap();
        }
        let draft = projects.join("draft.md");
        fs::write(&draft, "obsolete body").unwrap();
        fs::write(projects.join("unaffected.txt"), "unaffected body").unwrap();
        fs::write(tree.join("nested-item.txt"), "tree label").unwrap();
        fs::write(projects.join("orchard-sibling.txt"), "other label").unwrap();
        let helper = f.0.join("model");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        let p = |path: &PathBuf| path.as_path().to_str().unwrap().to_owned();
        f.run(&[
            "index",
            "--root",
            &p(&root),
            "--allow",
            &p(&projects),
            "--allow",
            &p(&provider),
            "--deny",
            &p(&denied),
            "--documents",
        ]);
        assert_eq!(
            f.run(&["embed", "--helper", &p(&helper)])["new_embeddings"],
            4
        );

        let watcher = watch(&f, &[]);
        let mut serve = Serve::new(&f);
        assert_eq!(f.run(&["status"])["embeddings"], 4);
        assert_eq!(serve.names("obsolete body", "text"), ["draft.md"]);

        // Preserve mtime and byte length to exercise change detection via ctime.
        let modified = fs::metadata(&draft).unwrap().modified().unwrap();
        fs::write(&draft, "replaced body").unwrap();
        fs::File::open(&draft)
            .unwrap()
            .set_modified(modified)
            .unwrap();
        serve.wait("replaced body", "text", &["draft.md"]);
        assert_eq!(watcher.json(), serde_json::json!({"event":"updated"}));
        assert!(serve.names("obsolete body", "text").is_empty());
        assert_eq!(f.run(&["status"])["embeddings"], 3);
        assert!(
            f.run(&[
                "query",
                "any",
                "--mode",
                "semantic",
                "--helper",
                &p(&helper)
            ])
            .as_array()
            .unwrap()
            .iter()
            .all(|hit| hit["name"] != "draft.md")
        );

        fs::write(projects.join("created-on-watch.md"), "bright new body").unwrap();
        serve.wait("created-on-watch", "name", &["created-on-watch.md"]);
        serve.wait("bright new body", "text", &["created-on-watch.md"]);

        fs::rename(&tree, projects.join("moved-orchard")).unwrap();
        serve.wait("scope/projects/orchard/nested-item", "name", &[]);
        serve.wait("moved-orchard/nested-item", "name", &["nested-item.txt"]);
        assert_eq!(
            serve.names("orchard-sibling", "name"),
            ["orchard-sibling.txt"]
        );
        fs::rename(projects.join("moved-orchard"), denied.join("moved-orchard")).unwrap();
        serve.wait("nested-item", "name", &[]);
        assert!(serve.names("tree label", "text").is_empty());
        fs::rename(denied.join("moved-orchard"), projects.join("allowed-again")).unwrap();
        serve.wait("nested-item", "name", &["nested-item.txt"]);

        fs::write(
            provider.join("provider-visible.txt"),
            "provider body forbidden",
        )
        .unwrap();
        fs::write(denied.join("rule-excludes.txt"), "denied body forbidden").unwrap();
        fs::write(root.join("outside-allow.txt"), "outside body forbidden").unwrap();
        serve.wait("provider-visible", "name", &["provider-visible.txt"]);
        assert!(serve.names("forbidden", "text").is_empty());
        assert!(serve.names("rule-excludes", "name").is_empty());
        assert!(serve.names("outside-allow", "name").is_empty());

        fs::rename(projects.join("allowed-again"), outside.join("detached")).unwrap();
        symlink(outside.join("detached"), projects.join("allowed-again")).unwrap();
        serve.wait("nested-item", "name", &[]);
        assert!(serve.names("allowed-again", "name").is_empty());

        fs::remove_file(&draft).unwrap();
        serve.wait("draft.md", "name", &[]);
        assert!(serve.names("replaced body", "text").is_empty());

        drop(watcher);
        fs::remove_file(projects.join("created-on-watch.md")).unwrap();
        fs::write(
            projects.join("while-offline.md"),
            "this arrived while stopped",
        )
        .unwrap();
        let _watcher = watch(&f, &[]);
        assert_eq!(
            serve.names("arrived while stopped", "text"),
            ["while-offline.md"]
        );
        assert!(serve.names("created-on-watch", "name").is_empty());
        assert!(serve.names("bright new body", "text").is_empty());
        assert_eq!(serve.names("unaffected body", "text"), ["unaffected.txt"]);
    }

    #[test]
    fn watcher_rearms_after_the_root_moves_and_serializes_scope_writers() {
        let f = Fixture::new();
        let root = f.0.join("watched-root");
        let r = root.to_str().unwrap();
        fs::create_dir(&root).unwrap();
        fs::write(root.join("before.txt"), "old tree").unwrap();
        let _watcher = watch(&f, &["--root", r]);
        let mut serve = Serve::new(&f);

        for action in ["watch", "index"] {
            let duplicate = f.cli().args([action, "--root", r]).output().unwrap();
            assert!(!duplicate.status.success());
            assert!(String::from_utf8_lossy(&duplicate.stderr).contains("index writer lease"));
        }

        fs::rename(&root, f.0.join("was-root")).unwrap();
        serve.wait("before.txt", "name", &[]);
        fs::create_dir(&root).unwrap();
        fs::write(root.join("replacement.txt"), "new tree").unwrap();
        serve.wait("replacement.txt", "name", &["replacement.txt"]);
        fs::write(root.join("after-rearm.txt"), "new change").unwrap();
        serve.wait("after-rearm.txt", "name", &["after-rearm.txt"]);
    }

    #[test]
    fn legacy_settings_require_explicit_scope_and_preserve_the_database() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let r = root.to_str().unwrap();
        fs::create_dir(&root).unwrap();
        fs::write(root.join("existing.txt"), "legacy document").unwrap();
        f.run(&["index", "--root", r, "--documents"]);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute_batch("DELETE FROM info WHERE key='scope'; DROP TABLE document_state;")
            .unwrap();
        drop(db);

        let output = f.cli().arg("watch").output().unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("predates saved scope"));
        assert_eq!(
            f.run(&["query", "legacy document", "--mode", "text"])[0]["name"],
            "existing.txt"
        );
        let _watcher = watch(&f, &["--root", r, "--documents"]);
        assert_eq!(
            f.run(&["query", "legacy document", "--mode", "text"])[0]["name"],
            "existing.txt"
        );
    }
    #[test]
    fn watch_updates_queries_while_an_embedding_is_computing() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let draft = root.join("revision.txt");
        fs::write(&draft, "initial revision").unwrap();
        let watcher = watch(&f, &["--root", root.to_str().unwrap(), "--documents"]);
        let mut serve = Serve::new(&f);
        let helper = f.0.join("slow-helper");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\n: > \"$0.started\"\nwhile [ ! -f \"$0.release\" ]; do sleep 0.02; done\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        let embedding = Process::launch(f.cli().args([
            "embed",
            "--helper",
            helper.to_str().unwrap(),
            "--max",
            "1",
        ]));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !f.0.join("slow-helper.started").exists() {
            assert!(Instant::now() < deadline, "embedding helper never started");
            thread::sleep(Duration::from_millis(10));
        }
        fs::write(&draft, "new revision").unwrap();
        assert_eq!(watcher.json(), serde_json::json!({"event":"updated"}));
        assert_eq!(serve.names("new revision", "text"), ["revision.txt"]);
        assert!(serve.names("initial revision", "text").is_empty());
        fs::write(f.0.join("slow-helper.release"), "").unwrap();
        assert_eq!(embedding.json()["new_embeddings"], 0);
        assert_eq!(f.run(&["status"])["embeddings"], 0);
        assert_eq!(
            f.run(&["embed", "--helper", helper.to_str().unwrap()])["new_embeddings"],
            1
        );
    }

    #[test]
    fn watch_without_a_saved_scope_does_not_start_a_scan() {
        let f = Fixture::new();
        let output = f.cli().arg("watch").output().unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("no saved scope"));
        assert!(!f.0.join("test.sqlite").exists());
    }
    #[test]
    fn denied_aliases_and_symlink_ancestors_never_become_visible() {
        let f = Fixture::new();
        let root = f.0.join("CaseSensitiveSpelling");
        let root_alias = f.0.join("casesensitivespelling");
        fs::create_dir(&root).unwrap();
        let selected = if root_alias.is_dir() {
            &root_alias
        } else {
            &root
        };
        let deny_rule = selected.join("PRIVATE-ÉQUIPE");
        let _watcher = watch(
            &f,
            &[
                "--root",
                selected.to_str().unwrap(),
                "--deny",
                deny_rule.to_str().unwrap(),
                "--documents",
            ],
        );
        let mut serve = Serve::new(&f);
        let denied = root.join("private-e\u{301}quipe");
        fs::create_dir(&denied).unwrap();
        fs::write(denied.join("never-show.txt"), "private source marker").unwrap();
        let link = root.join("linked");
        symlink(&denied, &link).unwrap();
        fs::write(root.join("show-this.txt"), "visible source marker").unwrap();
        serve.wait("show-this", "name", &["show-this.txt"]);
        assert!(serve.names("never-show", "name").is_empty());
        assert!(serve.names("private source", "text").is_empty());
        assert!(serve.names("linked", "name").is_empty());

        let independent = Fixture::new();
        let child = link.join("child");
        fs::create_dir(&child).unwrap();
        fs::write(child.join("unreachable.txt"), "unreachable source marker").unwrap();
        let output = independent
            .cli()
            .args(["index", "--root", child.to_str().unwrap(), "--documents"])
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("could be enumerated"));
    }

    #[test]
    fn temporarily_unreadable_records_are_hidden_retained_and_restored() {
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("protected.txt"), "temporary permissions test").unwrap();
        let r = root.to_str().unwrap();
        let watcher = watch(&f, &["--root", r, "--documents"]);
        let mut serve = Serve::new(&f);
        assert_eq!(serve.names("protected", "name"), ["protected.txt"]);
        struct RestoreMode<'a>(&'a Path);
        impl Drop for RestoreMode<'_> {
            fn drop(&mut self) {
                let _ = fs::set_permissions(self.0, fs::Permissions::from_mode(0o700));
            }
        }
        let restore = RestoreMode(&root);
        fs::set_permissions(&root, fs::Permissions::from_mode(0o0)).unwrap();
        serve.wait("protected", "name", &[]);
        assert!(serve.names("temporary permissions", "text").is_empty());
        assert_eq!(f.run(&["status"])["unverified"], 2);
        drop(watcher);

        let refused = f
            .cli()
            .args(["index", "--root", r, "--documents"])
            .output()
            .unwrap();
        assert!(!refused.status.success());
        let raw = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        assert_eq!(
            raw.query_row("SELECT count(*) FROM document", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
        drop(raw);
        drop(restore);

        let _watcher = watch(&f, &[]);
        assert_eq!(
            serve.names("temporary permissions", "text"),
            ["protected.txt"]
        );
        assert_eq!(f.run(&["status"])["unverified"], 0);
    }

    #[test]
    fn a_narrowed_scope_retires_old_hits_before_document_extraction() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let denied = root.join("deny-now");
        fs::create_dir_all(&denied).unwrap();
        fs::write(denied.join("restricted.txt"), "previously visible content").unwrap();
        let r = root.to_str().unwrap();
        f.run(&["index", "--root", r, "--documents"]);
        let mut serve = Serve::new(&f);
        assert_eq!(
            serve.names("previously visible", "text"),
            ["restricted.txt"]
        );
        let helper = f.0.join("pdf-helper");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\n: > \"$0.started\"\ni=0\nwhile [ ! -f \"$0.release\" ] && [ \"$i\" -lt 300 ]; do i=$((i+1)); sleep 0.02; done\nprintf 'new document text'\n",
        );
        fs::write(root.join("new.pdf"), "synthetic helper accepts any input").unwrap();
        let watcher = Process::launch(
            f.cli()
                .args([
                    "watch",
                    "--root",
                    r,
                    "--documents",
                    "--deny",
                    denied.to_str().unwrap(),
                    "--pdf-helper",
                    helper.to_str().unwrap(),
                ])
                .stdin(Stdio::null()),
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        while !f.0.join("pdf-helper.started").exists() {
            assert!(Instant::now() < deadline, "PDF helper never started");
            thread::sleep(Duration::from_millis(10));
        }
        let names = serve.names("restricted", "name");
        let text = serve.names("previously visible", "text");
        fs::write(f.0.join("pdf-helper.release"), "").unwrap();
        assert!(names.is_empty());
        assert!(text.is_empty());
        assert_eq!(watcher.json(), serde_json::json!({"event":"ready"}));
        assert_eq!(serve.names("new document text", "text"), ["new.pdf"]);
    }
    #[test]
    fn alternate_spelling_root_updates_after_a_case_only_rename() {
        let f = Fixture::new();
        let root = f.0.join("CaseRoot");
        fs::create_dir(&root).unwrap();
        let alias = f.0.join("caseroot");
        if !alias.is_dir() {
            return;
        }
        let _watcher = watch(&f, &["--root", alias.to_str().unwrap()]);
        let mut serve = Serve::new(&f);
        fs::rename(&root, &alias).unwrap();
        fs::write(alias.join("changed-after-rename.txt"), "").unwrap();
        serve.wait(
            "changed-after-rename",
            "name",
            &["changed-after-rename.txt"],
        );
    }
    #[test]
    fn docx_body_refreshes_when_word_replaces_the_file() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let file = root.join("report.docx");
        docx_fixture(
            &file,
            &word_body("<w:p><w:r><w:t>earlier report marker</w:t></w:r></w:p>"),
            "word/document.xml",
            false,
        );
        let _watcher = watch(&f, &["--root", root.to_str().unwrap(), "--documents"]);
        let mut serve = Serve::new(&f);
        assert_eq!(serve.names("earlier report", "text"), ["report.docx"]);
        let replacement = root.join(".report-swap");
        docx_fixture(
            &replacement,
            &word_body("<w:p><w:r><w:t>revised report marker</w:t></w:r></w:p>"),
            "word/document.xml",
            false,
        );
        fs::rename(&replacement, &file).unwrap();
        serve.wait("revised report", "text", &["report.docx"]);
        assert!(serve.names("earlier report", "text").is_empty());
    }
    #[test]
    fn semantic_batches_return_original_late_english_and_chinese_docx_paragraphs() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let en = "The observatory tracked a newly discovered comet beyond Saturn.";
        let zh = "生态考察队记录了潮汐对湿地幼苗的影响。";
        let filler =
            "This preface describes ledger entries, schedules, and invoice totals. ".repeat(62);
        let document = word_body(&format!(
            "<w:p><w:r><w:t>{filler}</w:t></w:r></w:p>
             <w:p><w:r><w:t>{en}</w:t></w:r></w:p>
             <w:tbl><w:tr><w:tc><w:p><w:r><w:t>{zh}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>",
        ));
        docx_fixture(
            &root.join("reference.docx"),
            &document,
            "word/document.xml",
            false,
        );
        let helper = f.0.join("fixture-model");
        executable(
            &helper,
            r#"#!/bin/sh
body=$(cat)
case "$body" in
  *observatory*|*"distant orbit"*) printf '[1,0,0,0,0,0,0,0]' ;;
  *生态考察*|*红树林*) printf '[0,1,0,0,0,0,0,0]' ;;
  *) printf '[0,0,1,0,0,0,0,0]' ;;
esac
"#,
        );
        let m = helper.to_str().unwrap();
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        let initial = f.run(&["status"]);
        assert_eq!(initial["documents"], 1);
        assert_eq!(initial["embedded_chunks"], 0);

        assert_eq!(
            f.run(&["embed", "--helper", m, "--max", "1"])["new_embeddings"],
            1
        );
        assert_eq!(
            f.run(&[
                "query",
                "distant orbit",
                "--mode",
                "semantic",
                "--helper",
                m
            ]),
            serde_json::json!([])
        );
        let mut total = 1;
        for _ in 0..20 {
            let added = f.run(&["embed", "--helper", m, "--max", "2"])["new_embeddings"]
                .as_u64()
                .unwrap();
            assert!(added <= 2);
            total += added;
            if added == 0 {
                break;
            }
        }
        assert!(total > 6);
        assert_eq!(f.run(&["status"])["embeddings"], 1);
        assert_eq!(f.run(&["status"])["embedded_chunks"], total);
        for (query, original) in [("distant orbit", en), ("红树林", zh)] {
            let result = f.run(&["query", query, "--mode", "semantic", "--helper", m]);
            assert_eq!(result.as_array().unwrap().len(), 1);
            assert_eq!(result[0]["snippet"], original);
            assert_eq!(result[0]["name"], "reference.docx");
            assert_eq!(result[0]["matched_by"], "semantic");
            assert!(result[0].get("page").is_none());
        }
        let filler_hits = f.run(&["query", "invoice", "--mode", "semantic", "--helper", m]);
        assert_eq!(filler_hits.as_array().unwrap().len(), 1);
    }

    #[test]
    fn interrupted_batch_resumes_after_its_last_saved_chunk() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        fs::write(
            root.join("sections.txt"),
            "first section\n\nsecond section\n\nthird section",
        )
        .unwrap();
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        let helper = f.0.join("interruptible-model");
        executable(
            &helper,
            r#"#!/bin/sh
body=$(cat)
case "$body" in
  "second section")
    : > "$0.started"
    i=0
    while [ ! -f "$0.release" ] && [ "$i" -lt 250 ]; do i=$((i+1)); sleep 0.02; done ;;
esac
printf '[1,0,0,0,0,0,0,0]'
"#,
        );
        let model = helper.to_str().unwrap();
        let batch = Process::launch(f.cli().args(["embed", "--helper", model, "--max", "3"]));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !f.0.join("interruptible-model.started").exists() {
            assert!(Instant::now() < deadline, "second chunk never started");
            thread::sleep(Duration::from_millis(10));
        }
        let before = f.run(&["status"])["embedded_chunks"].clone();
        drop(batch);
        fs::write(f.0.join("interruptible-model.release"), "").unwrap();
        assert_eq!(before, 1);
        assert_eq!(
            f.run(&["embed", "--helper", model, "--max", "1"])["new_embeddings"],
            1
        );
        assert_eq!(
            f.run(&["embed", "--helper", model, "--max", "5"])["new_embeddings"],
            1
        );
        assert_eq!(f.run(&["status"])["embedded_chunks"], 3);
    }

    #[test]
    fn watch_discards_every_chunk_of_a_changed_document() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let document = root.join("changes.md");
        fs::write(
            &document,
            "first section\n\nold late marker\n\nthird section",
        )
        .unwrap();
        let watcher = watch(&f, &["--root", root.to_str().unwrap(), "--documents"]);
        let helper = f.0.join("revision-model");
        executable(
            &helper,
            r#"#!/bin/sh
body=$(cat)
case "$body" in
  *old*) printf '[1,0,0,0,0,0,0,0]' ;;
  *new*) printf '[0,1,0,0,0,0,0,0]' ;;
  *) printf '[0,0,1,0,0,0,0,0]' ;;
esac
"#,
        );
        let model = helper.to_str().unwrap();
        let query = |text| f.run(&["query", text, "--mode", "semantic", "--helper", model]);
        assert_eq!(f.run(&["embed", "--helper", model])["new_embeddings"], 3);
        assert_eq!(query("old")[0]["snippet"], "old late marker");

        fs::write(
            &document,
            "first section\n\nnew late marker\n\nthird section",
        )
        .unwrap();
        assert_eq!(watcher.json(), serde_json::json!({"event":"updated"}));
        assert_eq!(f.run(&["status"])["embedded_chunks"], 0);
        assert_eq!(query("old"), serde_json::json!([]));
        assert_eq!(query("new"), serde_json::json!([]));
        assert_eq!(f.run(&["embed", "--helper", model])["new_embeddings"], 3);
        assert_eq!(query("new")[0]["snippet"], "new late marker");
        assert_eq!(query("old"), serde_json::json!([]));
    }

    #[test]
    fn legacy_document_vectors_require_a_chunk_rebuild_but_full_text_survives() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("legacy.md"), "legacy document body").unwrap();
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        let path = f.0.join("test.sqlite");
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute_batch(
            "DROP TRIGGER semantic_document_inserted; DROP TRIGGER semantic_document_deleted;
             DROP TABLE semantic_chunk; DROP TABLE semantic_document; DROP TABLE semantic_state;
             INSERT INTO embedding SELECT id, zeroblob(32) FROM document;
             INSERT INTO info VALUES('model','legacy-prefix-model');",
        )
        .unwrap();
        drop(db);

        assert_eq!(f.run(&["status"])["embedded_chunks"], 0);
        assert_eq!(
            f.run(&["query", "legacy document", "--mode", "text"])[0]["name"],
            "legacy.md"
        );
        let helper = f.0.join("migration-model");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        let model = helper.to_str().unwrap();
        assert_eq!(f.run(&["embed", "--helper", model])["new_embeddings"], 1);
        assert_eq!(
            f.run(&["query", "legacy", "--mode", "semantic", "--helper", model])[0]["snippet"],
            "legacy document body"
        );
        let db = rusqlite::Connection::open(path).unwrap();
        assert_eq!(
            db.query_row("SELECT count(*) FROM embedding", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
    fn metadata_stamp(path: &Path) -> String {
        let metadata = fs::symlink_metadata(path).unwrap();
        format!(
            "{}:{}:{}:{}:{}:{}:{}",
            metadata.dev(),
            metadata.ino(),
            metadata.len(),
            metadata.mtime(),
            metadata.mtime_nsec(),
            metadata.ctime(),
            metadata.ctime_nsec()
        )
    }

    #[test]
    fn first_search_after_same_path_replacement_returns_the_indexed_document_stamp() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let document = root.join("report.md");
        let old = "旧稿 older paragraph";
        let new = "新稿 newer paragraph";
        assert_eq!(old.len(), new.len());
        fs::write(&document, old).unwrap();
        let r = root.to_str().unwrap();
        f.run(&["index", "--root", r, "--documents"]);
        let indexed_stamp = metadata_stamp(&document);

        let helper = f.0.join("stamp-helper");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        let model = helper.to_str().unwrap();
        f.run(&["embed", "--helper", model]);
        let semantic = || {
            f.run(&[
                "query",
                "paragraph",
                "--mode",
                "semantic",
                "--helper",
                model,
            ])
        };

        // Replace the inode before the first query, while preserving the path,
        // byte length and mtime. No watcher updates this fixture's database.
        let mtime = fs::metadata(&document).unwrap().modified().unwrap();
        let replacement = root.join("replacement");
        fs::write(&replacement, new).unwrap();
        fs::File::open(&replacement)
            .unwrap()
            .set_modified(mtime)
            .unwrap();
        fs::rename(&replacement, &document).unwrap();
        assert_eq!(fs::metadata(&document).unwrap().modified().unwrap(), mtime);
        let live_stamp = metadata_stamp(&document);
        assert_ne!(indexed_stamp, live_stamp);

        let mut serve = Serve::new(&f);
        for hits in [
            serve.hits("older paragraph", "text"),
            serve.hits("旧稿", "text"),
            semantic(),
        ] {
            assert_eq!(hits[0]["snippet"], old);
            assert_eq!(hits[0]["document_stamp"], indexed_stamp);
            assert_ne!(hits[0]["document_stamp"], live_stamp);
        }
        assert!(
            serve.hits("report.md", "name")[0]
                .get("document_stamp")
                .is_none()
        );

        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute_batch("DROP TABLE document_state").unwrap();
        for hits in [serve.hits("older paragraph", "text"), semantic()] {
            assert_eq!(hits[0]["snippet"], old);
            assert!(hits[0].get("document_stamp").is_none());
        }

        f.run(&["index", "--root", r, "--documents"]);
        f.run(&["embed", "--helper", model]);
        assert!(
            serve
                .hits("older paragraph", "text")
                .as_array()
                .unwrap()
                .is_empty()
        );
        for hits in [serve.hits("newer paragraph", "text"), semantic()] {
            assert_eq!(hits[0]["snippet"], new);
            assert_eq!(hits[0]["document_stamp"], live_stamp);
        }
    }

    #[test]
    fn explicit_bge_workers_get_roles_and_do_not_reuse_other_model_vectors() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        fs::write(
            root.join("bge.md"),
            "unrelated beginning\n\nmatched last paragraph",
        )
        .unwrap();
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        let legacy = f.0.join("legacy-helper");
        let adapter = f.0.join("bge-helper");
        let interpreter = f.0.join("test-interpreter");
        let model = f.0.join("model");
        fs::create_dir(&model).unwrap();

        let vector = |one| {
            serde_json::to_string(
                &(0..512)
                    .map(|index| u8::from(index == one))
                    .collect::<Vec<_>>(),
            )
            .unwrap()
        };
        executable(
            &legacy,
            &format!("#!/bin/sh\ncat >/dev/null\nprintf '%s' '{}'\n", vector(0)),
        );
        executable(
            &interpreter,
            "#!/bin/sh\n[ \"$1\" = -I ] || exit 2\nshift\nexec /bin/sh \"$@\"\n",
        );
        let worker = |fingerprint: char| {
            format!(
                r#"#!/bin/sh
printf '%s\n' '{{"protocol":1,"language":"zh","fingerprint":"{}","dimensions":512}}'
while IFS= read -r request; do
  case "$request" in
    *'"role":"passage"'*'matched last paragraph'*|*'"role":"query"'*'look for the ending'*)
      printf '%s\n' '{{"vector":{}}}' ;;
    *) printf '%s\n' '{{"vector":{}}}' ;;
  esac
done
"#,
                fingerprint.to_string().repeat(64),
                vector(0),
                vector(1)
            )
        };
        executable(&adapter, &worker('a'));

        let old_model = ["--language", "zh", "--helper", legacy.to_str().unwrap()];
        let bge = [
            "--helper",
            adapter.to_str().unwrap(),
            "--bge-python",
            interpreter.to_str().unwrap(),
            "--bge-model",
            model.to_str().unwrap(),
        ];
        assert_eq!(
            f.run(&[&["embed"][..], &old_model].concat())["new_embeddings"],
            2
        );
        let query = ["query", "look for the ending", "--mode", "semantic"];
        let rejected = |configuration: &[&str]| {
            let result = f.cli().args(query).args(configuration).output().unwrap();
            assert!(!result.status.success());
            assert!(String::from_utf8_lossy(&result.stderr).contains("model or language changed"));
        };
        rejected(&bge);

        assert_eq!(f.run(&[&["embed"][..], &bge].concat())["new_embeddings"], 2);
        let document = root.join("bge.md");
        let indexed_stamp = metadata_stamp(&document);
        let replacement = root.join("replacement");
        fs::write(&replacement, "replacement contents").unwrap();
        fs::rename(&replacement, &document).unwrap();
        let result = f.run(&[&query[..], &bge].concat());
        assert_eq!(result[0]["snippet"], "matched last paragraph");
        assert_eq!(result[0]["matched_by"], "semantic_candidate");
        assert_eq!(result[0]["document_stamp"], indexed_stamp);
        assert_ne!(result[0]["document_stamp"], metadata_stamp(&document));
        rejected(&old_model);

        executable(&adapter, &worker('b'));
        rejected(&bge);
    }
    #[test]
    fn unencodable_chunks_do_not_block_batches_or_retry_forever() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let file = root.join("sections.md");
        fs::write(&file, "unencodable section\n\nretrievable section").unwrap();
        let r = root.to_str().unwrap();
        f.run(&["index", "--root", r, "--documents"]);
        let helper = f.0.join("skip-helper");
        executable(
            &helper,
            r#"#!/bin/sh
text=$(cat)
if [ "$text" = "unencodable section" ]; then
  echo skipped >> "$0.calls"
  exit 3
fi
printf '[1,0,0,0,0,0,0,0]'
"#,
        );
        let embed = ["embed", "--helper", helper.to_str().unwrap(), "--max", "1"];
        let first = f.run(&embed);
        assert_eq!(
            first,
            serde_json::json!({"new_embeddings":1,"skipped_chunks":1,"has_more":false})
        );
        assert_eq!(
            f.run(&embed),
            serde_json::json!({"new_embeddings":0,"skipped_chunks":0,"has_more":false})
        );
        assert_eq!(
            fs::read_to_string(f.0.join("skip-helper.calls")).unwrap(),
            "skipped\n"
        );

        let raw = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        assert_eq!(
            raw.query_row("SELECT count(*) FROM semantic_skip", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        fs::write(&file, "replacement section").unwrap();
        f.run(&["index", "--root", r, "--documents"]);
        assert_eq!(
            raw.query_row("SELECT count(*) FROM semantic_skip", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(f.run(&embed)["new_embeddings"], 1);
    }
    #[test]
    fn missing_or_bad_gemma_leaves_name_and_text_search_independent() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let resources = f.0.join("model");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("ledger.md"), "The rare mineral dust was blue.").unwrap();
        let root = root.to_str().unwrap();
        let home = resources.to_str().unwrap();
        f.run(&["index", "--root", root]);
        let status = f.run(&["gemma-status", "--gemma-home", home, "--verify"]);
        assert_eq!(status["ready"], false);
        assert_eq!(status["coverage"]["documents_enabled"], false);
        let denied = f
            .cli()
            .args(["embed", "--gemma", "--gemma-home", home])
            .output()
            .unwrap();
        assert!(!denied.status.success());
        assert!(
            String::from_utf8_lossy(&denied.stderr).contains("explicit document indexing scope")
        );

        fs::create_dir_all(resources.join("runtime")).unwrap();
        fs::write(
            resources.join("embeddinggemma-2-Q8_0.gguf"),
            b"invalid model",
        )
        .unwrap();
        f.run(&["index", "--root", root, "--documents"]);
        let status = f.run(&["gemma-status", "--gemma-home", home, "--verify"]);
        assert_eq!(status["available"], false);
        assert_eq!(status["coverage"]["pending"], true);
        assert!(status["diagnostic"].as_str().unwrap().contains("asset"));
        let failed = f
            .cli()
            .args(["embed", "--gemma", "--gemma-home", home])
            .output()
            .unwrap();
        assert!(!failed.status.success());
        assert_eq!(f.run(&["query", "ledger.md"])[0]["name"], "ledger.md");
        assert_eq!(
            f.run(&["query", "mineral dust", "--mode", "text"])[0]["name"],
            "ledger.md"
        );
        assert_eq!(
            f.run(&["query", "mineral dust", "--mode", "all"])[0]["name"],
            "ledger.md"
        );
    }

    #[test]
    #[ignore = "requires pinned assets installed in LUMEN_GEMMA_TEST_HOME"]
    fn real_gemma_cli_preserves_legacy_bge_and_replaces_only_changed_document_vectors() {
        let resources =
            std::env::var("LUMEN_GEMMA_TEST_HOME").expect("install the pinned Gemma assets first");
        let home = resources.as_str();
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let en = "Orient the solar panel toward the midday sun.";
        let zh = "给闹钟换上新的电池以后重新调准时间。";
        let english_query = "How do I get the clock to run after its battery died?";
        let chinese_query = "怎样摆放太阳能板才能让它朝着正午阳光？";
        fs::write(root.join("a.md"), en).unwrap();
        fs::write(root.join("b.md"), zh).unwrap();
        let root_path = root.to_str().unwrap();
        let index = ["index", "--root", root_path, "--documents"];
        f.run(&index);

        let adapter = f.0.join("bge-worker");
        let interpreter = f.0.join("bge-runtime");
        executable(&interpreter, "#!/bin/sh\nshift\nexec /bin/sh \"$@\"\n");
        let vector = |one| {
            serde_json::to_string(
                &(0..512)
                    .map(|index| u8::from(index == one))
                    .collect::<Vec<_>>(),
            )
            .unwrap()
        };
        executable(
            &adapter,
            &format!(
                r#"#!/bin/sh
printf '%s\n' '{{"protocol":1,"language":"zh","fingerprint":"{}","dimensions":512}}'
while IFS= read -r request; do
    case "$request" in
        *'solar panel'*) printf '%s\n' '{{"vector":{}}}' ;;
        *) printf '%s\n' '{{"vector":{}}}' ;;
    esac
done
"#,
                "a".repeat(64),
                vector(0),
                vector(1)
            ),
        );
        let bge_args = [
            "--helper",
            adapter.to_str().unwrap(),
            "--bge-python",
            interpreter.to_str().unwrap(),
            "--bge-model",
            root_path,
        ];
        assert_eq!(
            f.run(&[&["embed"][..], &bge_args].concat())["new_embeddings"],
            2
        );
        let raw = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        raw.execute_batch(
            "DROP TRIGGER semantic_versioned_chunk_deleted;
                           DROP TABLE semantic_vector; DROP TABLE semantic_vector_count;",
        )
        .unwrap();
        let before = f.run(&["gemma-status", "--gemma-home", home]);
        assert_eq!(before["ready"], false);
        assert_eq!(before["coverage"]["pending"], true);
        let embed = ["embed", "--gemma", "--gemma-home", home, "--max", "1"];
        assert_eq!(
            f.run(&embed),
            serde_json::json!({"new_embeddings":1,"skipped_chunks":0,"has_more":true})
        );
        assert_eq!(
            f.run(&embed),
            serde_json::json!({"new_embeddings":1,"skipped_chunks":0,"has_more":false})
        );
        let ready = f.run(&["gemma-status", "--gemma-home", home, "--verify"]);
        assert_eq!(ready["ready"], true);
        assert_eq!(ready["coverage"]["embedded_chunks"], 2);
        let default = f.run(&[
            "query",
            chinese_query,
            "--mode",
            "semantic",
            "--gemma-home",
            home,
        ]);
        assert_eq!(default[0]["snippet"], en);
        let vector_sizes: i64 = raw
            .query_row(
                "SELECT count(*) FROM semantic_vector WHERE length(vector)=3072",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(vector_sizes, 2);

        let mut session = f
            .cli()
            .args(["semantic-serve", "--gemma-home", home])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut input = session.stdin.take().unwrap();
        for (id, query) in [chinese_query, english_query].into_iter().enumerate() {
            writeln!(
                input,
                "{}",
                serde_json::json!({"id":id,"query":query,"mode":"semantic","limit":3})
            )
            .unwrap();
        }
        drop(input);
        let output = session.wait_with_output().unwrap();
        assert!(output.status.success());
        let lines: Vec<Value> = BufReader::new(output.stdout.as_slice())
            .lines()
            .map(|line| serde_json::from_str(&line.unwrap()).unwrap())
            .collect();
        assert_eq!(lines.len(), 2);
        for (id, (reply, snippet)) in lines.into_iter().zip([en, zh]).enumerate() {
            assert_eq!(reply["id"], id);
            assert_eq!(reply["hits"][0]["snippet"], snippet);
            assert_eq!(reply["hits"][0]["matched_by"], "semantic_candidate");
            assert!(reply["hits"][0]["document_stamp"].is_string());
        }
        let bge_query = [
            &["query", "solar panel", "--mode", "semantic"][..],
            &bge_args,
        ]
        .concat();
        assert_eq!(f.run(&bge_query)[0]["snippet"], en);
        assert_eq!(f.run(&["status"])["embedded_chunks"], 2);

        fs::write(root.join("replace"), "A clay teapot should dry slowly.").unwrap();
        fs::rename(root.join("replace"), root.join("b.md")).unwrap();
        f.run(&index);
        let status = f.run(&["status"]);
        assert_eq!(status["gemma"]["embedded_chunks"], 1);
        assert_eq!(status["gemma"]["pending"], true);
        assert_eq!(status["embedded_chunks"], 1);
        let during = f.run(&["gemma-status", "--gemma-home", home, "--verify"]);
        assert_eq!(during["ready"], true);
        assert_eq!(during["coverage"]["pending"], true);
        let live = f.run(&[
            "query",
            chinese_query,
            "--mode",
            "semantic",
            "--gemma-home",
            home,
        ]);
        assert_eq!(live.as_array().unwrap().len(), 1);
        assert_eq!(live[0]["snippet"], en);
        assert_eq!(f.run(&bge_query)[0]["snippet"], en);
        assert_eq!(f.run(&embed)["new_embeddings"], 1);
        assert_eq!(
            f.run(&["gemma-status", "--gemma-home", home, "--verify"])["ready"],
            true
        );

        let corrupt = f.0.join("bad-runtime");
        let corrupt_runtime = corrupt.join("runtime");
        fs::create_dir_all(&corrupt_runtime).unwrap();
        let real = Path::new(home);
        let model_name = "embeddinggemma-2-Q8_0.gguf";
        if fs::hard_link(real.join(model_name), corrupt.join(model_name)).is_err() {
            fs::copy(real.join(model_name), corrupt.join(model_name)).unwrap();
        }
        for item in fs::read_dir(real.join("runtime")).unwrap() {
            let item = item.unwrap();
            fs::copy(item.path(), corrupt_runtime.join(item.file_name())).unwrap();
        }
        let altered = corrupt_runtime.join("llama-server");
        fs::OpenOptions::new()
            .write(true)
            .open(altered)
            .unwrap()
            .write_all(b"bad runtime")
            .unwrap();
        let bad = f.run(&[
            "gemma-status",
            "--gemma-home",
            corrupt.to_str().unwrap(),
            "--verify",
        ]);
        assert_eq!(bad["ready"], false);
        assert!(
            bad["diagnostic"]
                .as_str()
                .unwrap()
                .contains("failed SHA-256")
        );
        assert_eq!(f.run(&["query", "a.md"])[0]["name"], "a.md");

        f.run(&["index", "--root", root_path]);
        assert_eq!(f.run(&["status"])["gemma"]["embedded_chunks"], 0);
        assert_eq!(
            raw.query_row("SELECT count(*) FROM semantic_vector", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(f.run(&["query", "a.md"])[0]["name"], "a.md");
    }
    #[test]
    fn diagnose_reports_scoped_metadata_without_following_aliases_or_writing_the_index() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let allowed = root.join("allowed");
        let denied = allowed.join("Private");
        let provider = allowed.join("Library/CloudStorage/OneDrive-Test");
        fs::create_dir_all(&denied).unwrap();
        fs::create_dir_all(&provider).unwrap();
        let local = allowed.join("paper.md");
        let outside = root.join("private-neighbor.md");
        let cloud = provider.join("remote.md");
        for path in [&local, &outside, &cloud, &denied.join("blocked.md")] {
            fs::write(path, "Synthetic body must not appear in diagnostics").unwrap();
        }
        symlink(&denied, allowed.join("aliased-parent")).unwrap();
        symlink(&outside, allowed.join("aliased-file.md")).unwrap();
        let root = root.to_str().unwrap();
        let allow = allowed.to_str().unwrap();
        let deny = denied.to_str().unwrap();
        let args = ["index", "--root", root, "--allow", allow, "--deny", deny];
        f.run(&args);
        let explain = |path: &Path| f.run(&["diagnose", "--", path.to_str().unwrap()]);
        let blocked = |reason| serde_json::json!({"name":reason,"text":reason,"semantic":reason});
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let generation = || {
            db.query_row("PRAGMA data_version", [], |r| r.get::<_, i64>(0))
                .unwrap()
        };
        let before = generation();
        assert_eq!(
            explain(&local),
            serde_json::json!({"name":"indexed","text":"text_disabled","semantic":"text_disabled","availability":"local"})
        );
        assert_eq!(
            explain(&cloud),
            serde_json::json!({"name":"indexed","text":"cloud_name_only","semantic":"cloud_name_only","availability":"provider_metadata_only"})
        );
        assert_eq!(explain(&outside), blocked("outside_scope"));
        assert_eq!(
            explain(&allowed.join("PRIVATE/nonexistent.md")),
            blocked("excluded")
        );
        assert_eq!(
            explain(&allowed.join("aliased-parent/blocked.md")),
            blocked("symlink")
        );
        assert_eq!(
            explain(&allowed.join("aliased-file.md")),
            blocked("symlink")
        );
        assert_eq!(
            explain(&allowed.join("aliased-parent/../paper.md")),
            blocked("unknown")
        );
        assert_eq!(explain(&allowed.join("missing.md")), blocked("missing"));
        assert_eq!(explain(&allowed), blocked("not_file"));
        assert_eq!(generation(), before);

        let locked = allowed.join("locked");
        fs::create_dir(&locked).unwrap();
        let hidden = locked.join("hidden.md");
        fs::write(&hidden, "Synthetic unreadable path").unwrap();
        if unsafe { libc::geteuid() } != 0 {
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
            let actual = explain(&hidden);
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
            assert_eq!(actual, blocked("unreadable"));
        }
        db.execute("DELETE FROM info WHERE key='scope'", [])
            .unwrap();
        assert_eq!(explain(&local), blocked("scope_unknown"));
        let empty = Fixture::new();
        assert_eq!(
            empty.run(&["diagnose", "--", local.to_str().unwrap()]),
            blocked("index_unavailable")
        );
        assert!(!empty.0.join("test.sqlite").exists());
    }

    #[test]
    fn diagnose_distinguishes_current_text_and_gemma_from_pending_or_stale_rows() {
        let f = Fixture::new();
        let scope = f.0.join("scope");
        fs::create_dir(&scope).unwrap();
        let file = scope.join("paper.md");
        let pdf = scope.join("no-helper.pdf");
        let unsupported = scope.join("photo.jpg");
        for path in [&file, &pdf, &unsupported] {
            fs::write(path, "Synthetic secret text should never be emitted.").unwrap();
        }
        let args = ["index", "--root", scope.to_str().unwrap(), "--documents"];
        f.run(&args);
        let explain = |path: &Path| f.run(&["diagnose", "--", path.to_str().unwrap()]);
        assert_eq!(
            explain(&file),
            serde_json::json!({"name":"indexed","text":"indexed","semantic":"pending_gemma","availability":"local"})
        );
        assert_eq!(explain(&pdf)["text"], "pdf_helper_unconfigured");
        assert_eq!(explain(&unsupported)["text"], "unsupported");
        let late = scope.join("new.md");
        fs::write(&late, "added after the scan").unwrap();
        assert_eq!(explain(&late)["name"], "not_indexed");
        assert_eq!(explain(&late)["text"], "not_indexed");

        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let id: i64 = db
            .query_row("SELECT id FROM item WHERE display='paper.md'", [], |r| {
                r.get(0)
            })
            .unwrap();
        db.execute(
            "INSERT INTO semantic_chunk(document_id,start_byte,end_byte) VALUES(?1,0,10)",
            [id],
        )
        .unwrap();
        let chunk = db.last_insert_rowid();
        db.execute(
            "UPDATE semantic_document SET prepared=1 WHERE document_id=?1",
            [id],
        )
        .unwrap();
        db.execute(
            "INSERT INTO semantic_vector VALUES('prior-model',?1,zeroblob(3072))",
            [chunk],
        )
        .unwrap();
        assert_eq!(explain(&file)["semantic"], "pending_gemma");
        db.execute(
            "INSERT INTO semantic_vector_count VALUES(?1,43690)",
            [lumen::GEMMA_MODEL_ID],
        )
        .unwrap();
        assert_eq!(explain(&file)["semantic"], "gemma_limited");
        db.execute(
            "DELETE FROM semantic_vector_count WHERE model=?1",
            [lumen::GEMMA_MODEL_ID],
        )
        .unwrap();
        db.execute(
            "INSERT INTO semantic_vector VALUES(?1,?2,'invalid shape')",
            rusqlite::params![lumen::GEMMA_MODEL_ID, chunk],
        )
        .unwrap();
        assert_eq!(explain(&file)["semantic"], "unknown");
        let mut vector = vec![0_u8; 3072];
        vector[..4].copy_from_slice(&1.0_f32.to_le_bytes());
        db.execute(
            "UPDATE semantic_vector SET vector=?1 WHERE model=?2",
            rusqlite::params![vector, lumen::GEMMA_MODEL_ID],
        )
        .unwrap();
        assert_eq!(explain(&file)["semantic"], "indexed");
        db.execute(
            "UPDATE semantic_vector SET vector=NULL WHERE model=?1",
            [lumen::GEMMA_MODEL_ID],
        )
        .unwrap();
        assert_eq!(explain(&file)["semantic"], "gemma_skipped");

        db.execute(
            "UPDATE item SET availability='unverified' WHERE id=?1",
            [id],
        )
        .unwrap();
        assert_eq!(explain(&file)["name"], "unverified");
        assert_eq!(explain(&file)["text"], "unverified");
        db.execute("UPDATE item SET availability='local' WHERE id=?1", [id])
            .unwrap();
        let replacement = scope.join("replacement");
        fs::write(&replacement, "same path, new inode").unwrap();
        fs::rename(replacement, &file).unwrap();
        let stale = explain(&file);
        assert_eq!(stale["name"], "indexed");
        assert_eq!(stale["text"], "stale");
        assert_eq!(stale["semantic"], "stale");
    }
    #[test]
    fn separate_content_resumes_batches_and_narrows_without_retiring_names() {
        let f = Fixture::new();
        let scope = f.0.join("scope");
        let selected = scope.join("Selected");
        let ignored = selected.join("Denied");
        let cloud = selected.join("Library/CloudStorage/OneDrive-Test");
        let second = scope.join("Second");
        for directory in [&ignored, &cloud, &second] {
            fs::create_dir_all(directory).unwrap();
        }
        for (path, text) in [
            (selected.join("a.md"), "firstneedle scoped content"),
            (selected.join("b.md"), "secondneedle scoped content"),
            (ignored.join("hidden.md"), "hiddenneedle scoped content"),
            (cloud.join("stub.md"), "cloudneedle never indexed"),
            (second.join("c.md"), "thirdneedle second scope"),
        ] {
            fs::write(path, text).unwrap();
        }
        let root = scope.to_str().unwrap();
        let denied = ignored.to_str().unwrap();
        let selected = selected.to_str().unwrap();
        let second = second.to_str().unwrap();
        f.run(&[
            "index",
            "--root",
            root,
            "--deny",
            denied,
            "--separate-content",
        ]);
        let configured = f.run(&["content-scope", "--content-root", selected]);
        assert_eq!(configured["content"]["pending"], 2);
        assert_eq!(
            configured["scope"]["roots"],
            serde_json::json!([fs::canonicalize(root).unwrap()])
        );
        let mut search = Serve::new(&f);
        assert_eq!(search.names("c.md", "name"), ["c.md"]);
        assert!(search.names("firstneedle", "text").is_empty());
        assert_eq!(f.run(&["content", "--max", "1"])["pending"], 1);
        let partial = f.run(&["status"]);
        assert_eq!(partial["content"]["checked"], 1);
        assert_eq!(partial["documents"], 1);
        assert_eq!(search.names("c.md", "name"), ["c.md"]);
        assert_eq!(f.run(&["content", "--max", "1"])["pending"], 0);
        assert_eq!(search.names("firstneedle", "text"), ["a.md"]);
        assert!(search.names("hiddenneedle", "text").is_empty());
        assert!(search.names("cloudneedle", "text").is_empty());
        assert_eq!(search.names("stub.md", "name"), ["stub.md"]);
        assert!(search.names("thirdneedle", "text").is_empty());

        let helper = f.0.join("vector-helper");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        assert_eq!(
            f.run(&["embed", "--helper", helper.to_str().unwrap()])["new_embeddings"],
            2
        );
        let changed = f.run(&["content-scope", "--content-root", second]);
        assert_eq!(changed["embedded_chunks"], 0);
        assert_eq!(changed["content"]["pending"], 1);
        assert_eq!(changed["items"], configured["items"]);
        assert!(search.names("firstneedle", "text").is_empty());
        assert_eq!(search.names("a.md", "name"), ["a.md"]);
        f.run(&["content"]);
        assert_eq!(search.names("thirdneedle", "text"), ["c.md"]);
        let watcher = watch(&f, &[]);
        fs::write(
            Path::new(second).join("c.md"),
            "updatedneedle from a new version",
        )
        .unwrap();
        assert_eq!(watcher.json()["event"], "updated");
        assert!(search.names("thirdneedle", "text").is_empty());
        assert!(search.names("updatedneedle", "text").is_empty());
        assert_eq!(search.names("c.md", "name"), ["c.md"]);
        assert_eq!(f.run(&["content"])["indexed"], 1);
        assert_eq!(search.names("updatedneedle", "text"), ["c.md"]);
    }

    #[test]
    fn content_worker_releases_sqlite_writes_while_extractor_runs() {
        let f = Fixture::new();
        let scope = f.0.join("scope");
        fs::create_dir(&scope).unwrap();
        fs::write(scope.join("pending.pdf"), "%PDF-synthetic fixture").unwrap();
        let helper = f.0.join("slow-helper");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\ntouch \"$0.started\"\nfor iteration in $(seq 1 150); do [ -e \"$0.release\" ] && break; sleep 0.02; done\n[ -e \"$0.release\" ] || exit 1\nprintf 'backgroundtoken extracted'\n",
        );
        let root = scope.to_str().unwrap();
        f.run(&[
            "index",
            "--root",
            root,
            "--documents",
            "--content-root",
            root,
            "--pdf-helper",
            helper.to_str().unwrap(),
        ]);
        let watcher = watch(&f, &[]);
        let worker = Process::launch(f.cli().arg("content"));
        let deadline = Instant::now() + Duration::from_secs(2);
        while !helper.with_extension("started").exists() {
            assert!(Instant::now() < deadline, "extractor did not start");
            thread::sleep(Duration::from_millis(10));
        }
        let mut serve = Serve::new(&f);
        fs::write(scope.join("live.txt"), "newly listed name").unwrap();
        assert_eq!(watcher.json()["event"], "updated");
        assert_eq!(serve.names("live.txt", "name"), ["live.txt"]);
        assert_eq!(serve.names("pending.pdf", "name"), ["pending.pdf"]);
        assert!(serve.names("backgroundtoken", "text").is_empty());
        fs::write(helper.with_extension("release"), "").unwrap();
        assert_eq!(worker.json()["indexed"], 1);
        assert_eq!(serve.names("backgroundtoken", "text"), ["pending.pdf"]);
    }

    #[test]
    fn page_metadata_follows_a_same_page_lexical_match_or_semantic_chunk() {
        let f = Fixture::new();
        let scope = f.0.join("scope");
        let bundle = f.0.join("Local.app/Contents/Resources");
        fs::create_dir(&scope).unwrap();
        fs::create_dir_all(&bundle).unwrap();
        fs::write(scope.join("report.pdf"), "%PDF-synthetic protocol fixture").unwrap();
        let engine = bundle.join("lumen");
        fs::copy(env!("CARGO_BIN_EXE_lumen"), &engine).unwrap();
        executable(
            &bundle.join("LumenPdfExtractor"),
            r#"#!/bin/sh
[ "$1" = '--pages-v1' ] || exit 2
cat >/dev/null
printf '%s' '[{"page":1,"text":"northern inventory"},{"page":3,"text":"zircon calibrator"}]'
"#,
        );
        let call = |args: &[&str]| {
            let out = Command::new(&engine)
                .arg("--db")
                .arg(f.0.join("test.sqlite"))
                .args(args)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            serde_json::from_slice::<Value>(&out.stdout).unwrap()
        };
        let root = scope.to_str().unwrap();
        call(&[
            "index",
            "--root",
            root,
            "--content-root",
            root,
            "--bundled-pdf-helper",
        ]);
        assert_eq!(call(&["content"])["indexed"], 1);
        assert_eq!(
            call(&["query", "zircon", "--mode", "text"])[0]["pdf_page"],
            3
        );
        assert_eq!(
            call(&["query", "zircon calibrator", "--mode", "text"])[0]["pdf_page"],
            3
        );
        assert!(
            call(&["query", "northern zircon", "--mode", "text"])[0]
                .get("pdf_page")
                .is_none()
        );
        assert!(
            call(&["query", "report", "--mode", "name"])[0]
                .get("pdf_page")
                .is_none()
        );
        let helper = f.0.join("embed-helper");
        executable(
            &helper,
            "#!/bin/sh\ncase $(cat) in *zircon*) printf '[0,1,0,0,0,0,0,0]' ;; *) printf '[1,0,0,0,0,0,0,0]' ;; esac\n",
        );
        let helper = helper.to_str().unwrap();
        assert_eq!(call(&["embed", "--helper", helper])["new_embeddings"], 2);
        let related = call(&[
            "query",
            "zircon excerpt",
            "--mode",
            "semantic",
            "--helper",
            helper,
        ]);
        assert_eq!(related[0]["pdf_page"], 3);
        assert_eq!(related[0]["snippet"], "zircon calibrator");
    }
}
