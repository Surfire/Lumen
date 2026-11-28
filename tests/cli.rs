use serde_json::Value;
use std::{
    ffi::{CStr, OsStr},
    fs,
    io::Write,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::PathBuf,
    process::{Command, Stdio},
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        Self::under(std::path::Path::new("/tmp"))
    }
    fn under(parent: &std::path::Path) -> Self {
        let mut template = parent.join("lumen-test-XXXXXX").into_os_string().into_vec();
        template.push(0);
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

#[test]
fn custom_root_indexes_project_material_but_not_development_noise() {
    let f = Fixture::new();
    let root = f.0.join("project");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("Cargo.toml"), "[package]\nname = \"probe\"\n").unwrap();
    for dir in [
        "node_modules",
        "target",
        "DerivedData",
        ".venv",
        "venv",
        "__pycache__",
        "Pods",
        ".gradle",
        ".cargo",
        ".rustup",
        ".npm",
        ".pnpm-store",
        ".yarn",
        ".next",
        ".nuxt",
        ".build",
        ".swiftpm",
        "bower_components",
        "CMakeFiles",
        "src",
    ] {
        let path = root.join(dir);
        fs::create_dir_all(&path).unwrap();
        fs::write(path.join("scope-probe.txt"), "").unwrap();
    }
    f.run(&["index", "--root", root.to_str().unwrap()]);
    let hits = f.run(&["query", "scope-probe"]);
    assert_eq!(hits.as_array().unwrap().len(), 1);
    assert!(
        hits[0]["path"]
            .as_str()
            .unwrap()
            .ends_with("/src/scope-probe.txt")
    );
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
    assert_eq!(stats["documents"], 2);
    assert_eq!(stats["documents_not_read"], 0);
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
    assert_eq!(
        f.run(&["query", "cloud text marker", "--mode", "text"])[0]["name"],
        "restricted.docx"
    );
    assert_eq!(
        f.run(&["query", "denied text marker", "--mode", "text"]),
        serde_json::json!([])
    );
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
    // Resident provider files (SF_DATALESS == 0) enjoy full text parity when documents are enabled.
    assert_eq!(
        f.run(&[
            "query",
            "THIS-CONTENT-MUST-NOT-BE-INDEXED",
            "--mode",
            "text"
        ])[0]["name"],
        "air-only.md"
    );
    assert!(
        f.run(&["query", "SHOULD-NOT-BE-READ", "--mode", "text"])
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
fn serve_bounds_frames_and_recovers_from_malformed_requests() {
    let f = Fixture::new();
    let root = f.0.join("scope");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("frame.txt"), "").unwrap();
    f.run(&["index", "--root", root.to_str().unwrap()]);
    let run = |bytes: &[u8]| {
        let mut child = f
            .cli()
            .arg("serve")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(bytes).unwrap();
        child.wait_with_output().unwrap()
    };
    let mut boundary = br#"{"id":1,"op":"search","query":"frame"}"#.to_vec();
    boundary.resize(16 * 1024 - 1, b' ');
    boundary.extend_from_slice(b"\ninvalid\n{\"id\":2,\"op\":\"bogus\",\"query\":\"frame\"}\n{\"id\":3,\"op\":\"validate\",\"hits\":[]}\n{\"id\":4,\"query\":\"frame\"}\n");
    let output = run(&boundary);
    assert!(output.status.success(), "{:?}", output);
    let replies: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(replies.len(), 5);
    assert_eq!(replies[0]["hits"][0]["name"], "frame.txt");
    assert!(replies[1]["error"].is_string());
    assert!(replies[2]["error"].is_string());
    assert_eq!(replies[3], serde_json::json!({"id":3,"valid":[]}));
    assert_eq!(replies[4]["hits"][0]["name"], "frame.txt");
    for frame in [
        vec![b' '; 16 * 1024 + 1],
        b"{\"id\":1,\"query\":\"frame\"}".to_vec(),
    ] {
        let output = run(&frame);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("invalid serve request frame"));
    }
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
            Self::launch(f, &[])
        }

        fn launch(f: &Fixture, args: &[&str]) -> Self {
            let mut process =
                Process::launch(f.cli().arg("serve").args(args).stdin(Stdio::piped()));
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
    fn unified_serve_search_override_and_ordered_validation_share_a_session() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let path = root.join("session-note.txt");
        fs::write(&path, "session searchable body").unwrap();
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        let mut serve = Serve::launch(&f, &["--check-access"]);
        let request = |serve: &mut Serve, value: Value| {
            writeln!(serve.input, "{value}").unwrap();
            let reply = serve.process.json();
            assert_eq!(reply["id"], value["id"]);
            reply
        };
        let text = request(
            &mut serve,
            serde_json::json!({
                "id":1,"op":"search","query":"session searchable body","mode":"text"
            }),
        );
        assert_eq!(text["hits"][0]["name"], "session-note.txt");
        assert!(text["hits"][0]["document_stamp"].is_string());
        let hit = text["hits"][0].clone();
        let invalid = serde_json::json!({"path":path,"kind":"directory","availability":"local"});
        let mut untyped = hit.clone();
        untyped.as_object_mut().unwrap().remove("matched_by");
        let valid = request(
            &mut serve,
            serde_json::json!({
                "id":2,"op":"validate","hits":[hit,invalid,untyped]
            }),
        );
        assert_eq!(valid, serde_json::json!({"id":2,"valid":[true,false,true]}));
        fs::remove_file(&path).unwrap();
        assert_eq!(
            request(
                &mut serve,
                serde_json::json!({
                    "id":3,"op":"validate","hits":[hit]
                })
            ),
            serde_json::json!({"id":3,"valid":[false]})
        );
        assert!(
            request(
                &mut serve,
                serde_json::json!({
                    "id":4,"query":"session-note","mode":"name"
                })
            )["hits"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            request(
                &mut serve,
                serde_json::json!({
                    "id":5,"query":"session-note","mode":"name","check_access":false
                })
            )["hits"][0]["name"],
            "session-note.txt"
        );
        // The already-running reader must observe the next committed catalog.
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        assert!(
            request(
                &mut serve,
                serde_json::json!({
                    "id":6,"op":"search","query":"session-note","check_access":false
                })
            )["hits"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        fs::write(&path, "replacement text").unwrap();
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        assert_eq!(
            request(
                &mut serve,
                serde_json::json!({
                    "id":7,"op":"validate","hits":[hit]
                })
            )["valid"],
            serde_json::json!([false])
        );
        assert_eq!(
            request(
                &mut serve,
                serde_json::json!({
                    "id":8,"op":"validate","hits":[]
                })
            ),
            serde_json::json!({"id":8,"valid":[]})
        );
        let mut unchecked = Serve::new(&f);
        fs::remove_file(&path).unwrap();
        assert!(
            request(
                &mut unchecked,
                serde_json::json!({
                    "id":9,"query":"session-note","check_access":true
                })
            )["hits"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn contextual_pinyin_searches_new_and_existing_catalog_rows() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let chengdu = "成都卫生Health.PDF";
        let changsha = "长沙银行纪要.md";
        for file in [chengdu, changsha, "chengdou-sample.txt", "鹿鸣"] {
            fs::write(root.join(file), "").unwrap();
        }
        f.run(&["index", "--root", root.to_str().unwrap()]);
        let mut db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let mut serve = Serve::new(&f);
        let verify = |serve: &mut Serve| {
            for (query, expected) in [
                ("chengdu", chengdu),
                ("CD", chengdu),
                ("chengdu health pdf", chengdu),
                ("changshayinhang", changsha),
                ("CS", changsha),
                ("鹿鸣", "鹿鸣"),
            ] {
                assert_eq!(serve.names(query, "name"), [expected], "{query}");
            }
        };
        verify(&mut serve);

        let tx = db.transaction().unwrap();
        for (display, new_full, new_initials, old_full, old_initials) in [
            (
                chengdu,
                "chengdu",
                "cd",
                "chengdouweishenghealthpdf",
                "cdwshpdf",
            ),
            (
                changsha,
                "changshayinhang",
                "csyh",
                "zhangshayinxingjiyaomd",
                "zsyxjym",
            ),
        ] {
            let (id, name, full, initials, path): (i64, String, String, String, String) = tx
                .query_row(
                    "SELECT id,name,full,initials,searchable_path FROM item WHERE display=?1",
                    [display],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                        ))
                    },
                )
                .unwrap();
            assert!(full.starts_with(new_full), "{full}");
            assert!(initials.starts_with(new_initials), "{initials}");
            tx.execute(
                "INSERT INTO name_fts(name_fts,rowid,name,full,initials,searchable_path)
                 VALUES('delete',?1,?2,?3,?4,?5)",
                rusqlite::params![id, name, full, initials, path],
            )
            .unwrap();
            tx.execute(
                "UPDATE item SET full=?2,initials=?3 WHERE id=?1",
                rusqlite::params![id, old_full, old_initials],
            )
            .unwrap();
            tx.execute(
                "INSERT INTO name_fts(rowid,name,full,initials,searchable_path) VALUES(?1,?2,?3,?4,?5)",
                rusqlite::params![id, name, old_full, old_initials, path],
            )
            .unwrap();
        }
        tx.commit().unwrap();
        verify(&mut serve);
        let stored: String = db
            .query_row("SELECT full FROM item WHERE display=?1", [chengdu], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(stored, "chengdouweishenghealthpdf");
    }

    #[test]
    fn launcher_hides_unregistered_external_rows_and_rejects_implicit_scans() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("external-fixture-local.txt"), "").unwrap();
        f.run(&["index", "--root", root.to_str().unwrap()]);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let legacy = "/Volumes/Lumen-Synthetic-External/external-fixture.txt";
        db.execute(
            "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
             VALUES(?1,'external-fixture.txt','file','local','external-fixture.txt','','',?1)",
            [legacy],
        )
        .unwrap();
        db.execute(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
             SELECT id,name,full,initials,searchable_path FROM item WHERE path=?1",
            [legacy],
        )
        .unwrap();
        let mut serve = Serve::new(&f);
        assert_eq!(
            serve.names("external-fixture", "name"),
            ["external-fixture-local.txt"],
        );
        assert_eq!(
            f.run(&[
                "validate-hit",
                "--kind",
                "file",
                "--availability",
                "local",
                "--",
                legacy
            ]),
            serde_json::json!({"valid": false}),
        );
        for command in ["index", "watch"] {
            let rejected = f
                .cli()
                .args([command, "--root", "/Volumes/Lumen-Synthetic-External"])
                .output()
                .unwrap();
            assert!(!rejected.status.success());
            assert!(String::from_utf8_lossy(&rejected.stderr).contains("index-volume"));
        }
        let rejected = f
            .cli()
            .args(["index-volume", "--"])
            .arg(root)
            .output()
            .unwrap();
        assert!(!rejected.status.success());
        assert!(String::from_utf8_lossy(&rejected.stderr).contains("mount point"));
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
        // A 1-level symlink validates for name-only hits, never for document stamps.
        assert!(valid(&file, "file", None));
        assert!(!valid(&file, "file", Some(stamp)));
        assert!(!valid(&outside, "file", None));
        // A 2-level chained symlink is rejected.
        let chain = root.join("chained.txt");
        symlink(&file, &chain).unwrap();
        assert!(!valid(&chain, "file", None));

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
        assert_eq!(serve.names(".ＰＰＴＸ", "name").len(), 5);
        assert_eq!(
            serve.names("ext:pptx", "name"),
            serve.names(".pptx", "name")
        );
        assert!(
            serve
                .names("ＰＰＴＸ", "name")
                .contains(&"成都卫健委pptx.txt".to_owned())
        );
        let mut text_matches = serve.names("pptx", "text");
        text_matches.sort_unstable();
        assert_eq!(text_matches, ["letters.md", "missing.txt"]);

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
    fn legacy_pdf_extraction_does_not_lock_out_background_writers() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("legacy.pdf"), "%PDF-synthetic fixture").unwrap();
        let helper = f.0.join("legacy-extractor");
        executable(
            &helper,
            r#"#!/bin/sh
: > "$0.started"
i=0
while [ ! -f "$0.release" ] && [ "$i" -lt 250 ]; do i=$((i+1)); sleep 0.02; done
printf 'legacy indexed body'
"#,
        );
        let mut scanner = Process::launch(f.cli().args([
            "index",
            "--root",
            root.to_str().unwrap(),
            "--documents",
            "--pdf-helper",
            helper.to_str().unwrap(),
        ]));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !helper.with_extension("started").exists() {
            assert!(Instant::now() < deadline, "legacy extractor did not start");
            thread::sleep(Duration::from_millis(10));
        }
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.busy_timeout(Duration::ZERO).unwrap();
        let write = db.execute("INSERT INTO info VALUES('write_probe','background')", []);
        fs::write(helper.with_extension("release"), "").unwrap();
        assert_eq!(
            write.unwrap(),
            1,
            "a background write must not wait for PDF extraction"
        );
        assert!(scanner.child.wait().unwrap().success());
        assert_eq!(f.run(&["status"])["documents"], 1);
    }

    #[test]
    fn unreadable_legacy_body_stays_hidden_between_write_batches() {
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let f = Fixture::new();
        let root = f.0.join("scope");
        let later = f.0.join("later");
        for dir in [&root, &later] {
            fs::create_dir(dir).unwrap();
        }
        let secret = root.join("record.md");
        fs::write(&secret, "unreadable legacy prose").unwrap();
        let helper = f.0.join("extractor");
        executable(
            &helper,
            r#"#!/bin/sh
: > "$0.started"
while [ ! -f "$0.release" ]; do sleep 0.02; done
printf 'second batch text'
"#,
        );
        let args = [
            "index",
            "--root",
            root.to_str().unwrap(),
            "--root",
            later.to_str().unwrap(),
            "--documents",
            "--pdf-helper",
            helper.to_str().unwrap(),
        ];
        f.run(&args);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute_batch(
            "UPDATE item SET availability='unverified' WHERE display='record.md';
             DELETE FROM document_state;",
        )
        .unwrap();
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o000)).unwrap();
        assert!(fs::read_dir(&root).unwrap().next().unwrap().is_ok());
        assert_eq!(
            fs::File::open(&secret).unwrap_err().kind(),
            std::io::ErrorKind::PermissionDenied
        );
        // Finish a batch after the denial before pausing at a later root.
        let flush_root = f.0.join("flush");
        fs::create_dir(&flush_root).unwrap();
        fs::write(flush_root.join("flush.md"), "flush marker prose").unwrap();
        fs::write(later.join("pause.pdf"), "%PDF-synthetic").unwrap();
        let mut scanner = Process::launch(
            f.cli()
                .args(&args[..3])
                .args(["--root", flush_root.to_str().unwrap()])
                .args(&args[3..]),
        );
        wait_for_path(&helper.with_extension("started"));
        let mut serve = Serve::new(&f);
        assert_eq!(serve.names("flush marker prose", "text"), ["flush.md"]);
        assert!(serve.names("unreadable legacy prose", "text").is_empty());
        fs::write(helper.with_extension("release"), "").unwrap();
        assert!(scanner.child.wait().unwrap().success());
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600)).unwrap();
        f.run(&args);
        assert_eq!(
            serve.names("unreadable legacy prose", "text"),
            ["record.md"]
        );
    }

    fn wait_for_path(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(
                Instant::now() < deadline,
                "never reached {}",
                path.display()
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn upgraded_scope_removes_old_exclusions_before_cached_start() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let dev = root.join("node_modules");
        let package = root.join("Editor.app/Contents");
        for dir in [&dev, &package] {
            fs::create_dir_all(dir).unwrap();
            fs::write(dir.join("retired-scope.txt"), "").unwrap();
        }
        fs::write(root.join("retained-scope.txt"), "").unwrap();
        f.run(&[
            "index",
            "--root",
            root.to_str().unwrap(),
            "--root",
            dev.to_str().unwrap(),
            "--root",
            package.to_str().unwrap(),
        ]);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let info = |key| -> String {
            db.query_row("SELECT value FROM info WHERE key=?", [key], |r| r.get(0))
                .unwrap()
        };
        let mut checkpoint: Value = serde_json::from_str(&info("watch_checkpoint_v1")).unwrap();
        checkpoint[1]["roots"].as_array_mut().unwrap().truncate(1);
        db.execute(
            "UPDATE info SET value=? WHERE key='scope'",
            [checkpoint[1].to_string()],
        )
        .unwrap();
        db.execute(
            "INSERT INTO info(key,value) VALUES('watch_checkpoint_v1',?)",
            [checkpoint.to_string()],
        )
        .unwrap();
        db.execute_batch(
            "PRAGMA user_version=2; DELETE FROM info WHERE key IN ('scope_policy_v3','scope_policy_v4','scope_policy_v5');",
        )
        .unwrap();
        let prior_scan = info("scan");
        let mut serve = Serve::new(&f);
        assert_eq!(serve.names("retired-scope", "name").len(), 2);

        let watcher = Process::launch(f.cli().args(["watch", "--cached-start"]));
        assert_eq!(watcher.json()["event"], "cached");
        assert!(serve.names("retired-scope", "name").is_empty());
        assert_eq!(watcher.json()["event"], "ready");
        assert_ne!(
            info("scan"),
            prior_scan,
            "the pre-upgrade journal must not authorize replay"
        );
        assert_eq!(
            serve.names("retained-scope", "name"),
            ["retained-scope.txt"]
        );
        let excluded: i64 = db
            .query_row(
                "SELECT count(*) FROM item WHERE display='retired-scope.txt'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(excluded, 0);
    }

    #[test]
    fn cached_start_removes_traversal_only_rows_from_an_unchanged_scope() {
        let f = Fixture::new();
        let home = fs::canonicalize(&f.0).unwrap().join("home");
        let library = home.join("Library");
        let child = library.join("CloudStorage");
        fs::create_dir_all(&child).unwrap();
        fs::write(child.join("retained-cloud-file.txt"), "").unwrap();
        let library_path = library.to_str().unwrap();
        assert!(
            f.cli()
                .env("HOME", &home)
                .args(["index", "--root", library_path])
                .output()
                .unwrap()
                .status
                .success()
        );
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let library_present = || -> bool {
            db.query_row(
                "SELECT EXISTS(SELECT 1 FROM item WHERE path=?)",
                [library_path],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert!(!library_present(), "the walker must only traverse Library");
        db.execute(
            "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
             VALUES(?1,'Library','directory','local','library','','',?1)",
            [library_path],
        )
        .unwrap();
        db.execute(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
             SELECT id,name,full,initials,searchable_path FROM item WHERE path=?1",
            [library_path],
        )
        .unwrap();
        // Simulate a catalog already reconciled by the previous policy.
        db.execute_batch(
            "DELETE FROM info WHERE key IN ('scope_policy_v4','scope_policy_v5','watch_checkpoint_v1');
             INSERT OR REPLACE INTO info VALUES('scope_policy_v3','true');",
        )
        .unwrap();
        let mut serve = Serve::new(&f);
        assert!(
            serve
                .names("library", "name")
                .iter()
                .any(|name| name == "Library")
        );

        let mut command = f.cli();
        command.env("HOME", &home).args(["watch", "--cached-start"]);
        let (marker, release) = pause_lstat(&f, &mut command, &child, 1);
        let watcher = Process::launch(&mut command);
        assert_eq!(watcher.json()["event"], "cached");
        wait_for_path(&marker);
        assert!(
            !library_present(),
            "restrict_scope must purge Library before Cached"
        );
        assert!(
            !serve
                .names("library", "name")
                .iter()
                .any(|name| name == "Library")
        );
        assert_eq!(
            serve.names("retained-cloud-file", "name"),
            ["retained-cloud-file.txt"]
        );
        fs::write(release, "").unwrap();
        assert_eq!(watcher.json()["event"], "ready");
    }

    #[test]
    fn package_subtree_event_revisits_a_directly_nested_explicit_root() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let app = root.join("Editor.app");
        let nested = app.join("Contents");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("explicit-note.md"), "indexed explicit prose").unwrap();
        fs::write(app.join("implicit-note.md"), "opaque to the outer root").unwrap();
        let watcher = watch(
            &f,
            &[
                "--root",
                root.to_str().unwrap(),
                "--root",
                nested.to_str().unwrap(),
                "--documents",
            ],
        );
        let mut serve = Serve::new(&f);
        assert_eq!(
            serve.names("indexed explicit prose", "text"),
            ["explicit-note.md"]
        );
        assert!(serve.names("implicit-note", "name").is_empty());
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute(
            "UPDATE item SET availability='unverified' WHERE display='explicit-note.md'",
            [],
        )
        .unwrap();
        fs::set_permissions(&app, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(watcher.json()["event"], "updated");
        assert_eq!(
            serve.names("indexed explicit prose", "text"),
            ["explicit-note.md"]
        );
    }

    #[test]
    fn explicit_root_overrides_system_defaults_but_not_privacy_rules() {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap());
        let f = Fixture::under(&home.join("Library"));
        let root = f.0.join("projects");
        for dir in [
            "src",
            "Keychains",
            "Cookies",
            "Caches",
            ".private",
            "explicit-deny",
        ] {
            let dir = root.join(dir);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("system-root-probe.md"), "selected project body").unwrap();
        }
        assert!(!lumen::Scope::default().allows(&root));
        assert!(
            lumen::Scope {
                roots: vec!["/opt/projects".into()],
                ..Default::default()
            }
            .allows(Path::new("/opt/projects/src"))
        );
        f.run(&[
            "index",
            "--root",
            root.to_str().unwrap(),
            "--documents",
            "--deny",
            root.join("explicit-deny").to_str().unwrap(),
        ]);
        let mut serve = Serve::new(&f);
        let hits = serve.hits("system-root-probe", "name");
        assert_eq!(hits.as_array().unwrap().len(), 1);
        assert!(
            hits[0]["path"]
                .as_str()
                .unwrap()
                .ends_with("/src/system-root-probe.md")
        );
        assert_eq!(
            serve.names("selected project body", "text"),
            ["system-root-probe.md"]
        );
    }

    #[test]
    fn cached_start_checks_results_before_historical_changes_finish() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let private = root.join("private");
        fs::create_dir_all(&private).unwrap();
        let moved = root.join("old-record.md");
        let denied = private.join("protected-record.md");
        fs::write(&moved, "old indexed body").unwrap();
        fs::write(&denied, "private cached prose").unwrap();
        let stable = root.join("stable-record.md");
        fs::write(&stable, "original cached prose").unwrap();
        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let saved_scan = || {
            db.query_row("SELECT value FROM info WHERE key='scan'", [], |row| {
                row.get::<_, String>(0)
            })
            .unwrap()
        };
        let first_scan = saved_scan();
        let mut checked = Serve::launch(&f, &["--check-access"]);
        assert_eq!(
            checked.names("original cached prose", "text"),
            ["stable-record.md"]
        );
        fs::rename(moved, root.join("new-record.md")).unwrap();
        let replacement = root.join("replacement");
        fs::write(&replacement, "replacement document prose").unwrap();
        fs::rename(replacement, &stable).unwrap();
        assert!(checked.names("old-record", "name").is_empty());
        assert!(checked.names("original cached prose", "text").is_empty());
        assert_eq!(checked.names("stable-record", "name"), ["stable-record.md"]);

        if unsafe { libc::geteuid() } != 0 {
            // The directory is searchable by exact path, but not enumerable.
            fs::set_permissions(&private, fs::Permissions::from_mode(0o100)).unwrap();
            let names = checked.names("protected-record", "name");
            let text = checked.names("private cached prose", "text");
            fs::set_permissions(&private, fs::Permissions::from_mode(0o700)).unwrap();
            assert!(names.is_empty());
            assert!(text.is_empty());
        }
        thread::sleep(Duration::from_millis(650));
        let watcher = Process::launch(
            f.cli()
                .args(["watch", "--cached-start"])
                .stdin(Stdio::null()),
        );
        assert_eq!(watcher.json()["event"], "cached");
        assert_eq!(watcher.json()["event"], "ready");
        assert_eq!(saved_scan(), first_scan);
        assert_eq!(checked.names("new-record", "name"), ["new-record.md"]);
        assert_eq!(
            checked.names("replacement document prose", "text"),
            ["stable-record.md"]
        );
    }

    #[test]
    fn cached_start_keeps_resident_provider_documents_verified() {
        let f = Fixture::new();
        let provider = f.0.join("Library/CloudStorage/OneDrive-Fixture");
        let selected = provider.join("Selected");
        fs::create_dir_all(&selected).unwrap();
        fs::write(selected.join("resident.md"), "cachedresidentneedle").unwrap();
        fs::write(provider.join("outside.md"), "outsidecloudneedle").unwrap();
        f.run(&[
            "index",
            "--root",
            provider.to_str().unwrap(),
            "--content-root",
            selected.to_str().unwrap(),
        ]);
        assert_eq!(f.run(&["content"])["indexed"], 1);

        let mut watcher = Process::launch(
            f.cli()
                .args(["watch", "--cached-start", "--progress"])
                .stderr(Stdio::piped()),
        );
        assert_eq!(watcher.json()["event"], "cached");
        assert_eq!(watcher.json()["event"], "ready");
        watcher.child.kill().unwrap();
        let stderr = std::io::read_to_string(watcher.child.stderr.take().unwrap()).unwrap();
        assert!(stderr.contains("lumen watch: recovered"), "{stderr}");

        let mut checked = Serve::launch(&f, &["--check-access"]);
        let hits = checked.hits("cachedresidentneedle", "text");
        assert_eq!(hits[0]["name"], "resident.md");
        assert_eq!(hits[0]["availability"], "provider_metadata_only");
        assert!(checked.names("outsidecloudneedle", "text").is_empty());
        assert_eq!(checked.names("outside.md", "name"), ["outside.md"]);
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
        assert!(get_info("watch_checkpoint_v1").is_some());
        // A catalog from before manual scans seeded the watch needs one repair.
        db.execute("DELETE FROM info WHERE key='watch_checkpoint_v1'", [])
            .unwrap();
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

        let mut prior_boot: Value =
            serde_json::from_str(&get_info("watch_checkpoint_v1").unwrap()).unwrap();
        prior_boot[0]["boot"] = serde_json::json!("synthetic-prior-boot-session");
        db.execute(
            "UPDATE info SET value=?1 WHERE key='watch_checkpoint_v1'",
            [prior_boot.to_string()],
        )
        .unwrap();
        fs::write(root.join("after-reboot.txt"), "synthetic reboot catch-up").unwrap();
        let reboot = watch(&f, &[]);
        assert_eq!(serve.names("after-reboot", "name"), ["after-reboot.txt"]);
        let renewed: Value =
            serde_json::from_str(&get_info("watch_checkpoint_v1").unwrap()).unwrap();
        assert_ne!(renewed[0]["boot"], prior_boot[0]["boot"]);
        drop(reboot);

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

        // Edit content so size/mtime change triggers incremental re-indexing.
        fs::write(&draft, "replaced body text").unwrap();
        serve.wait("replaced body text", "text", &["draft.md"]);
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
            "provider body resident",
        )
        .unwrap();
        fs::write(denied.join("rule-excludes.txt"), "denied body forbidden").unwrap();
        fs::write(root.join("outside-allow.txt"), "outside body forbidden").unwrap();
        serve.wait("provider-visible", "name", &["provider-visible.txt"]);
        serve.wait("provider body resident", "text", &["provider-visible.txt"]);
        assert!(serve.names("forbidden", "text").is_empty());
        assert!(serve.names("rule-excludes", "name").is_empty());
        assert!(serve.names("outside-allow", "name").is_empty());

        fs::rename(projects.join("allowed-again"), outside.join("detached")).unwrap();
        symlink(outside.join("detached"), projects.join("allowed-again")).unwrap();
        serve.wait("nested-item", "name", &[]);
        assert_eq!(serve.names("allowed-again", "name"), ["allowed-again"]);

        fs::remove_file(&draft).unwrap();
        serve.wait("draft.md", "name", &[]);
        assert!(serve.names("replaced body text", "text").is_empty());

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
    fn watch_exits_and_releases_writer_lease_when_stdout_pipe_closes() {
        let f = Fixture::new();
        let root = f.0.join("watched-orphan-check");
        let r = root.to_str().unwrap();
        fs::create_dir(&root).unwrap();
        fs::write(root.join("note.txt"), "hello").unwrap();

        let mut first = f
            .cli()
            .arg("watch")
            .args(["--root", r])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdout = first.stdout.take().unwrap();
        let mut reader = BufReader::new(stdout);
        let mut ready = String::new();
        reader.read_line(&mut ready).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&ready).unwrap(),
            serde_json::json!({"event": "ready"})
        );

        let duplicate = f.cli().args(["watch", "--root", r]).output().unwrap();
        assert!(!duplicate.status.success());
        assert!(String::from_utf8_lossy(&duplicate.stderr).contains("index writer lease"));

        drop(reader);
        let deadline = Instant::now() + Duration::from_secs(3);
        let status = loop {
            if let Some(status) = first.try_wait().unwrap() {
                break Some(status);
            }
            if Instant::now() >= deadline {
                break None;
            }
            thread::sleep(Duration::from_millis(20));
        };
        let Some(status) = status else {
            let _ = first.kill();
            let _ = first.wait();
            panic!("watch did not exit after stdout pipe closed");
        };
        assert!(status.success(), "unexpected exit status: {status}");

        let _second = watch(&f, &["--root", r]);
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
        db.execute_batch(
            "PRAGMA user_version=1; DELETE FROM info WHERE key='scope'; DROP TABLE document_state;",
        )
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
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM semantic_chunk WHERE length(vector)=16",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            total as i64
        );
        // Leave the same document with both formats, as after an incremental upgrade.
        let old_en: Vec<_> = [1.0_f32, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
            .into_iter()
            .flat_map(f32::to_le_bytes)
            .collect();
        assert_eq!(db.execute("UPDATE semantic_chunk SET vector=?1 WHERE id=(
            SELECT c.id FROM semantic_chunk c JOIN document d ON d.id=c.document_id
            WHERE substr(CAST(d.body AS BLOB),c.start_byte+1,c.end_byte-c.start_byte)=CAST(?2 AS BLOB))",
            rusqlite::params![old_en, en]).unwrap(), 1);
        for (query, original) in [("distant orbit", en), ("红树林", zh)] {
            let result = f.run(&["query", query, "--mode", "semantic", "--helper", m]);
            assert_eq!(result.as_array().unwrap().len(), 1);
            assert_eq!(result[0]["snippet"], original);
            assert_eq!(result[0]["name"], "reference.docx");
            assert_eq!(result[0]["matched_by"], "semantic");
            assert!(result[0].get("page").is_none());
        }
        let all_hits = f.run(&["query", "distant orbit", "--mode", "all", "--helper", m]);
        assert_eq!(all_hits.as_array().unwrap().len(), 1);
        assert_eq!(all_hits[0]["name"], "reference.docx");
        assert_eq!(all_hits[0]["matched_by"], "semantic");
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
            "PRAGMA user_version=1;
             DROP TRIGGER semantic_document_inserted; DROP TRIGGER semantic_document_deleted;
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
            "{}:{}:{}:{}:{}",
            metadata.dev(),
            metadata.ino(),
            metadata.len(),
            metadata.mtime(),
            metadata.mtime_nsec(),
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
        db.execute_batch("PRAGMA user_version=1; DROP TABLE document_state")
            .unwrap();
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

        let helper = f.0.join("legacy-helper");
        executable(
            &helper,
            r#"#!/bin/sh
body=$(cat)
case "$body" in
  *'solar panel'*) printf '[1,0,0,0,0,0,0,0]' ;;
  *) printf '[0,1,0,0,0,0,0,0]' ;;
esac
"#,
        );
        let legacy_args = ["--helper", helper.to_str().unwrap()];
        assert_eq!(
            f.run(&[&["embed"][..], &legacy_args].concat())["new_embeddings"],
            2
        );
        let raw = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        raw.execute_batch(
            "PRAGMA user_version=1;
             DROP TRIGGER semantic_versioned_chunk_deleted;
             DROP TRIGGER IF EXISTS gemma_pending_chunk_deleted;
             DROP TRIGGER IF EXISTS gemma_pending_chunk_inserted;
             DROP TABLE IF EXISTS gemma_pending_chunk;
             DELETE FROM info WHERE key='gemma_pending_model';
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
                "SELECT count(*) FROM semantic_vector WHERE length(vector)=1536",
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
        let legacy_query = [
            &["query", "solar panel", "--mode", "semantic"][..],
            &legacy_args,
        ]
        .concat();
        assert_eq!(f.run(&legacy_query)[0]["snippet"], en);
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
        assert_eq!(f.run(&legacy_query)[0]["snippet"], en);
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
        symlink(
            allowed.join("aliased-file.md"),
            allowed.join("chained-file.md"),
        )
        .unwrap();
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
            serde_json::json!({"name":"indexed","text":"text_disabled","semantic":"text_disabled","availability":"provider_metadata_only"})
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
            serde_json::json!({"name":"indexed","text":"symlink","semantic":"symlink","availability":"local"})
        );
        assert_eq!(
            explain(&allowed.join("chained-file.md")),
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
        let dynamic_limit = lumen::gemma_coverage(&db).unwrap().chunk_limit;
        db.execute(
            "INSERT INTO semantic_vector_count VALUES(?1,?2)",
            rusqlite::params![lumen::GEMMA_MODEL_ID, dynamic_limit],
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
    fn bundled_vision_ocr_is_opt_in_and_validated_separately_from_image_search() {
        let f = Fixture::new();
        let resources = f.0.join("Fixture.app/Contents/Resources");
        let root = f.0.join("scope");
        let selected = root.join("selected");
        let provider = root.join("Library/CloudStorage/OneDrive-Fixture");
        fs::create_dir_all(&resources).unwrap();
        fs::create_dir_all(&provider).unwrap();
        fs::create_dir_all(&selected).unwrap();
        let engine = resources.join("lumen");
        fs::copy(env!("CARGO_BIN_EXE_lumen"), &engine).unwrap();
        let helper = resources.join("LumenImageOcrExtractor");
        let checked = |output: std::process::Output| {
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            output.stdout
        };
        checked(
            Command::new("/usr/bin/xcrun")
                .args(["swiftc", "-swift-version", "5", "-target"])
                .arg(format!("{}-apple-macosx14.0", std::env::consts::ARCH))
                .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("app/ExtractImageOcr.swift"))
                .arg("-o")
                .arg(&helper)
                .output()
                .unwrap(),
        );
        let png = f.0.join("fixture.png");
        checked(Command::new("/usr/bin/xcrun").args(["swift", "-e", r#"
import AppKit
let image = NSImage(size: NSSize(width: 800, height: 240), flipped: false) { rect in
    NSColor.white.setFill()
    rect.fill()
    ("Quartz Calibration" as NSString).draw(at: NSPoint(x: 40, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black])
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
"#]).arg(&png).output().unwrap());
        let image = selected.join("scan.HEIC");
        checked(
            Command::new("/usr/bin/sips")
                .args(["-s", "format", "heic"])
                .arg(&png)
                .arg("--out")
                .arg(&image)
                .output()
                .unwrap(),
        );
        for excluded in [provider.join("cloud.png"), root.join("outside.png")] {
            fs::copy(&png, excluded).unwrap();
        }
        std::os::unix::fs::symlink(&png, selected.join("symlink.png")).unwrap();
        let oversized = selected.join("oversized.png");
        fs::copy(&png, &oversized).unwrap();
        fs::OpenOptions::new()
            .write(true)
            .open(oversized)
            .unwrap()
            .set_len(12 * 1024 * 1024 + 1)
            .unwrap();
        let root = root.to_str().unwrap();
        let selected = selected.to_str().unwrap();
        let run = |args: &[&str]| -> Value {
            serde_json::from_slice(&checked(
                Command::new(&engine)
                    .arg("--db")
                    .arg(f.0.join("test.sqlite"))
                    .args(args)
                    .output()
                    .unwrap(),
            ))
            .unwrap()
        };
        run(&["index", "--root", root, "--content-root", selected]);
        let query = || {
            run(&[
                "query",
                "quartz calibration",
                "--mode",
                "text",
                "--check-access",
            ])
        };
        assert_eq!(run(&["status"])["content"]["image_ocr"], false);
        assert_eq!(run(&["content"])["indexed"], 0);
        assert_eq!(query(), serde_json::json!([]));
        let enabled = run(&["content-scope", "--content-root", selected, "--image-ocr"]);
        assert_eq!(enabled["scope"]["image_ocr"], true);
        assert_eq!(enabled["content"]["pending"], 3); // Local HEIC, oversized PNG, and 1-level symlink leaf (skipped on OCR).
        assert_eq!(run(&["content"])["indexed"], 1);
        let hits = query();
        assert_eq!(hits.as_array().unwrap().len(), 1);
        assert_eq!(hits[0]["name"], "scan.HEIC");
        assert_eq!(hits[0]["snippet"], "Quartz Calibration");
        assert_eq!(
            run(&["diagnose", image.to_str().unwrap()])["text"],
            "indexed"
        );
        let text_hit = &hits[0];
        assert_eq!(text_hit["matched_by"], "text");
        let path = text_hit["path"].as_str().unwrap();
        let stamp = metadata_stamp(&image);
        assert_eq!(text_hit["document_stamp"], stamp);

        run(&["image-scope", selected]);
        if let Ok(projector) = std::env::var("LUMEN_IMAGE_TEST_PROJECTOR") {
            // With the pinned Gemma assets installed, exercise actual pixel indexing too.
            assert_eq!(
                run(&["image-index", "--projector", &projector])["indexed"],
                1
            );
        } else {
            // Keep the validation regression runnable without downloading Gemma.
            // Seed a normalized embedding in the same format image-index persists.
            let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
            let mut vector = vec![0_u8; 768 * 2];
            vector[..2].copy_from_slice(&0x3c00_u16.to_le_bytes()); // 1.0 in f16
            assert_eq!(
                db.execute(
                    "INSERT INTO image_embedding SELECT id,?2,?3,?4 FROM item WHERE path=?1",
                    rusqlite::params![path, lumen::IMAGE_MODEL_ID, stamp, vector],
                )
                .unwrap(),
                1
            );
        }
        assert_eq!(run(&["image-status"])["vectors"], 1);
        let image_hit = serde_json::json!({
            "path": path, "kind": "file", "availability": "local",
            "document_stamp": stamp, "matched_by": "image_embedding"
        });
        let mut serve = Serve::new(&f);
        let mut validate = |text_valid: bool, image_valid: bool| {
            serve.id += 1;
            let request = serde_json::json!({
                "id": serve.id, "op": "validate", "hits": [text_hit, image_hit]
            });
            writeln!(serve.input, "{request}").unwrap();
            assert_eq!(
                serve.process.json(),
                serde_json::json!({
                    "id": serve.id, "valid": [text_valid, image_valid]
                })
            );
            for (matched_by, valid) in [("text", text_valid), ("image_embedding", image_valid)] {
                assert_eq!(
                    run(&[
                        "validate-hit",
                        "--kind",
                        "file",
                        "--availability",
                        "local",
                        "--document-stamp",
                        &stamp,
                        "--matched-by",
                        matched_by,
                        "--",
                        path
                    ])["valid"],
                    valid
                );
            }
        };
        validate(true, true);

        let cleared = run(&["content-scope", "--content-root", selected]);
        assert_eq!(cleared["content"]["total"], 0);
        assert_eq!(query(), serde_json::json!([]));
        assert_eq!(run(&["query", "scan.HEIC"])[0]["name"], "scan.HEIC");
        validate(false, true);

        run(&["content-scope", "--content-root", selected, "--image-ocr"]);
        assert_eq!(run(&["content"])["indexed"], 1);
        assert_eq!(query()[0]["document_stamp"], stamp);
        validate(true, true);
        assert_eq!(run(&["image-scope", "--clear"])["vectors"], 0);
        validate(true, false);

        let mut untyped = image_hit;
        untyped.as_object_mut().unwrap().remove("matched_by");
        serve.id += 1;
        let request = serde_json::json!({"id": serve.id, "op": "validate", "hits": [untyped]});
        writeln!(serve.input, "{request}").unwrap();
        assert_eq!(serve.process.json()["valid"], serde_json::json!([false]));
    }

    #[test]
    fn explicit_cloud_content_root_seeds_only_resident_documents() {
        let f = Fixture::new();
        let provider = f.0.join("Library/CloudStorage/OneDrive-Fixture");
        let selected = provider.join("Selected");
        fs::create_dir_all(&selected).unwrap();
        let resident = selected.join("resident.md");
        let placeholder = selected.join("online-only.md");
        let sibling = provider.join("outside.md");
        for (path, body) in [
            (&resident, "residentneedle indexed inside explicit scope"),
            (&placeholder, "placeholderneedle must not be indexed"),
            (&sibling, "outsideneedle must not be indexed"),
        ] {
            fs::write(path, body).unwrap();
        }
        let index = ["index", "--root", provider.to_str().unwrap()];
        f.run(&index);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        // APFS doesn't let ordinary files set SF_DATALESS via chflags. Inject
        // its catalog classification, leaving a readable marker to catch reads.
        db.execute(
            "UPDATE item SET availability='placeholder' WHERE display='online-only.md'",
            [],
        )
        .unwrap();
        let scope = [
            "content-scope",
            "--content-root",
            selected.to_str().unwrap(),
        ];
        assert_eq!(f.run(&scope)["content"]["pending"], 1);

        // Reopening an unchanged pre-fix scope must also seed the existing row
        // before any filesystem traversal (watch calls the same restrict_scope).
        db.execute_batch(
            "DELETE FROM content_job;
            DELETE FROM info WHERE key='cloud_content_policy_v1';",
        )
        .unwrap();
        assert_eq!(f.run(&scope)["content"]["pending"], 1);
        assert_eq!(
            f.run(&["content"]),
            serde_json::json!({"processed":1,"indexed":1,"pending":0,"skipped":0})
        );
        assert_eq!(f.run(&["status"])["gemma"]["pending"], true);

        // Simulate the file becoming dataless after the catalog and job were
        // written. The worker must reject the live SF_DATALESS flag too.
        db.execute_batch(
            "UPDATE item SET availability='provider_metadata_only' WHERE display='online-only.md';
            INSERT INTO content_job(item_id) SELECT id FROM item WHERE display='online-only.md';",
        )
        .unwrap();
        let source = f.0.join("dataless.c");
        let library = f.0.join("dataless.dylib");
        fs::write(&source, r#"
#include <string.h>
#include <sys/stat.h>
static int dataless_lstat(const char *path, struct stat *buf) {
    int result = lstat(path, buf);
    const char *leaf = strrchr(path, '/');
    if (result == 0 && leaf && strcmp(leaf, "/online-only.md") == 0)
        buf->st_flags |= SF_DATALESS;
    return result;
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } hook = {dataless_lstat, lstat};
"#).unwrap();
        let compile = Command::new("cc")
            .args(["-dynamiclib", "-o"])
            .arg(&library)
            .arg(&source)
            .output()
            .unwrap();
        assert!(
            compile.status.success(),
            "{}",
            String::from_utf8_lossy(&compile.stderr)
        );
        let output = f
            .cli()
            .arg("content")
            .env("DYLD_INSERT_LIBRARIES", &library)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&output.stdout).unwrap(),
            serde_json::json!({"processed":1,"indexed":0,"pending":0,"skipped":0})
        );
        assert_eq!(
            f.run(&["diagnose", resident.to_str().unwrap()]),
            serde_json::json!({
                "name":"indexed", "text":"indexed", "semantic":"pending_gemma", "availability":"provider_metadata_only"
            })
        );
        assert_eq!(
            f.run(&["diagnose", sibling.to_str().unwrap()])["text"],
            "outside_content_scope"
        );
        let hits = f.run(&[
            "query",
            "residentneedle",
            "--mode",
            "text",
            "--check-access",
        ]);
        assert_eq!(hits[0]["name"], "resident.md");
        assert_eq!(hits[0]["availability"], "provider_metadata_only");
        for term in ["placeholderneedle", "outsideneedle"] {
            assert_eq!(
                f.run(&["query", term, "--mode", "text"]),
                serde_json::json!([])
            );
        }
        assert_eq!(
            f.run(&["query", "outside.md"])[0]["availability"],
            "provider_metadata_only"
        );

        let helper = f.0.join("cloud-vector-helper");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        assert_eq!(
            f.run(&["embed", "--helper", helper.to_str().unwrap()])["new_embeddings"],
            1
        );
        fs::remove_file(placeholder).unwrap();
        let watcher = watch(&f, &[]);
        assert_eq!(f.run(&["status"])["embedded_chunks"], 1);
        fs::write(
            selected.join("new.md"),
            "newresidentneedle picked up by watch",
        )
        .unwrap();
        assert_eq!(watcher.json()["event"], "updated");
        assert_eq!(f.run(&["content"])["indexed"], 1);
        drop(watcher);
        f.run(&[&index[..], &["--documents"]].concat());
        assert_eq!(
            f.run(&["query", "residentneedle indexed", "--mode", "text"])[0]["name"],
            "resident.md"
        );
        f.run(&index);
        assert_eq!(f.run(&["status"])["embedded_chunks"], 0);
        assert_eq!(
            f.run(&["query", "residentneedle", "--mode", "text"]),
            serde_json::json!([])
        );
    }

    #[test]
    fn separate_content_resumes_batches_and_narrows_without_retiring_names() {
        let f = Fixture::new();
        let scope = f.0.join("scope");
        let selected = scope.join("Selected");
        let ignored = selected.join("Denied");
        let cloud = scope.join("Library/CloudStorage/OneDrive-Test");
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
    fn separate_content_keeps_denied_body_hidden_after_ready() {
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let f = Fixture::new();
        let scope = f.0.join("scope");
        fs::create_dir(&scope).unwrap();
        let secret = scope.join("restricted.md");
        fs::write(&secret, "restricted separate prose").unwrap();
        let root = scope.to_str().unwrap();
        f.run(&["index", "--root", root, "--content-root", root]);
        assert_eq!(f.run(&["content"])["indexed"], 1);
        let mut serve = Serve::new(&f);
        assert_eq!(
            serve.names("restricted separate prose", "text"),
            ["restricted.md"]
        );
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o000)).unwrap();
        assert!(fs::read_dir(&scope).unwrap().next().unwrap().is_ok());
        assert_eq!(
            fs::File::open(&secret).unwrap_err().kind(),
            std::io::ErrorKind::PermissionDenied
        );
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute("DELETE FROM info WHERE key='watch_checkpoint_v1'", [])
            .unwrap();
        let watcher = watch(&f, &[]);
        assert!(serve.names("restricted separate prose", "text").is_empty());
        f.run(&["content"]);
        assert!(serve.names("restricted separate prose", "text").is_empty());
        drop(watcher);
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600)).unwrap();
        let _watcher = watch(&f, &[]);
        f.run(&["content"]);
        assert_eq!(
            serve.names("restricted separate prose", "text"),
            ["restricted.md"]
        );
    }

    #[test]
    fn pending_legacy_content_is_cleared_on_permission_denied() {
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let f = Fixture::new();
        let scope = f.0.join("scope");
        let nested = scope.join("nested");
        fs::create_dir_all(&nested).unwrap();
        let unreadable = scope.join("unreadable.md");
        let unreachable = nested.join("unreachable.md");
        fs::write(&unreadable, "unreadable legacy body").unwrap();
        fs::write(&unreachable, "unreachable legacy body").unwrap();
        let root = scope.to_str().unwrap();
        f.run(&["index", "--root", root, "--documents"]);
        assert_eq!(
            f.run(&["content-scope", "--content-root", root])["content"]["pending"],
            2
        );
        let mut serve = Serve::new(&f);
        assert_eq!(
            serve.names("unreadable legacy body", "text"),
            ["unreadable.md"]
        );
        assert_eq!(
            serve.names("unreachable legacy body", "text"),
            ["unreachable.md"]
        );

        fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o000)).unwrap();
        fs::set_permissions(&nested, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            fs::File::open(&unreadable).unwrap_err().kind(),
            std::io::ErrorKind::PermissionDenied
        );
        assert_eq!(
            fs::symlink_metadata(&unreachable).unwrap_err().kind(),
            std::io::ErrorKind::PermissionDenied
        );
        let batch = f.run(&["content"]);
        fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o600)).unwrap();
        fs::set_permissions(&nested, fs::Permissions::from_mode(0o700)).unwrap();

        assert_eq!(batch["processed"], 0);
        assert_eq!(batch["pending"], 2);
        assert!(serve.names("legacy body", "text").is_empty());
        assert_eq!(f.run(&["content"])["indexed"], 2);
        assert_eq!(
            serve.names("unreadable legacy body", "text"),
            ["unreadable.md"]
        );
        assert_eq!(
            serve.names("unreachable legacy body", "text"),
            ["unreachable.md"]
        );
    }

    #[test]
    fn failed_low_ids_do_not_starve_later_content_jobs() {
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let f = Fixture::new();
        let scope = f.0.join("scope");
        fs::create_dir(&scope).unwrap();
        for name in ["first.txt", "second.txt", "third.txt"] {
            fs::write(scope.join(name), format!("queue prose for {name}")).unwrap();
        }
        let root = scope.to_str().unwrap();
        f.run(&["index", "--root", root, "--content-root", root]);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        let paths = db
            .prepare("SELECT path FROM content_job JOIN item ON item_id=id ORDER BY id")
            .unwrap()
            .query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        for path in &paths[..2] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o000)).unwrap();
        }
        let batch = f.run(&["content", "--max", "1"]);
        assert_eq!(batch["processed"], 1);
        assert_eq!(batch["indexed"], 1);
        assert_eq!(batch["pending"], 2);
        let mut serve = Serve::new(&f);
        assert_eq!(
            serve.names("queue prose", "text"),
            [Path::new(&paths[2]).file_name().unwrap().to_str().unwrap()]
        );
        assert_eq!(f.run(&["content", "--max", "1"])["processed"], 0);
        fs::set_permissions(&paths[0], fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(f.run(&["content", "--max", "1"])["indexed"], 1);
    }

    #[test]
    fn retry_cursor_survives_a_failed_job_that_exhausts_the_batch_budget() {
        let f = Fixture::new();
        let first = f.0.join("first");
        let second = f.0.join("second");
        for root in [&first, &second] {
            fs::create_dir(root).unwrap();
        }
        fs::write(first.join("slow.pdf"), "%PDF-synthetic").unwrap();
        fs::write(second.join("later.md"), "later pending prose").unwrap();
        // Jobs run newest first: the failing PDF is the newest.
        set_age(&second.join("later.md"), 60);
        let helper = f.0.join("extractor");
        executable(
            &helper,
            r#"#!/bin/sh
# Deliberately exceed the batch budget, then make the extraction stale.
sleep 2.2
printf 'changed' >> "${0%/*}/first/slow.pdf"
printf 'stale extraction'
"#,
        );
        let first = first.to_str().unwrap();
        let second = second.to_str().unwrap();
        f.run(&[
            "index",
            "--root",
            first,
            "--root",
            second,
            "--content-root",
            first,
            "--content-root",
            second,
            "--documents",
            "--pdf-helper",
            helper.to_str().unwrap(),
        ]);
        let stale = f.run(&["content"]);
        assert_eq!(stale["processed"], 0);
        assert_eq!(stale["skipped"], 1);
        assert_eq!(stale["pending"], 2);
        let next = f.run(&["content", "--max", "1"]);
        assert_eq!(next["indexed"], 1);
        assert_eq!(next["pending"], 1);
        assert_eq!(
            Serve::new(&f).names("later pending prose", "text"),
            ["later.md"]
        );
    }

    /// Backdate a file's mtime by `seconds`.
    fn set_age(path: &Path, seconds: u64) {
        fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(seconds))
            .unwrap();
    }

    fn pause_lstat(
        f: &Fixture,
        command: &mut Command,
        target: &Path,
        occurrence: u32,
    ) -> (PathBuf, PathBuf) {
        let source = f.0.join("pause-stat.c");
        let library = f.0.join("pause-stat.dylib");
        let marker = f.0.join("stat-started");
        let release = f.0.join("stat-release");
        // Pause the real metadata syscall without replacing the walker, worker, or DB.
        fs::write(
            &source,
            r#"
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int paused_lstat(const char *path, struct stat *buf) {
    const char *target = getenv("LUMEN_TEST_STAT_TARGET");
    static int calls;
    if (target && strcmp(target, path) == 0 && ++calls == atoi(getenv("LUMEN_TEST_STAT_OCCURRENCE"))) {
        int fd = open(getenv("LUMEN_TEST_STAT_STARTED"), O_CREAT | O_WRONLY, 0600);
        if (fd >= 0) close(fd);
        for (int i = 0; i < 500 && access(getenv("LUMEN_TEST_STAT_RELEASE"), F_OK) != 0; ++i)
            usleep(20000);
    }
    return lstat(path, buf);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } hook = {paused_lstat, lstat};
"#,
        )
        .unwrap();
        let compile = Command::new("cc")
            .args(["-dynamiclib", "-o"])
            .arg(&library)
            .arg(&source)
            .output()
            .unwrap();
        assert!(
            compile.status.success(),
            "{}",
            String::from_utf8_lossy(&compile.stderr)
        );
        command
            .env("DYLD_INSERT_LIBRARIES", &library)
            .env("LUMEN_TEST_STAT_TARGET", fs::canonicalize(target).unwrap())
            .env("LUMEN_TEST_STAT_OCCURRENCE", occurrence.to_string())
            .env("LUMEN_TEST_STAT_STARTED", &marker)
            .env("LUMEN_TEST_STAT_RELEASE", &release);
        (marker, release)
    }

    fn assert_stat_does_not_hold_writer(f: &Fixture, marker: &Path, release: &Path) {
        wait_for_path(marker);
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.busy_timeout(Duration::ZERO).unwrap();
        let write = db.execute(
            "INSERT INTO info VALUES('stat_probe','background write')",
            [],
        );
        fs::write(release, "").unwrap();
        assert_eq!(
            write.expect("metadata lookup must not hold SQLite's write lock"),
            1
        );
    }

    #[test]
    fn bulk_document_metadata_does_not_hold_a_writer_transaction() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        fs::create_dir(&root).unwrap();
        let file = root.join("metadata-probe.md");
        fs::write(&file, "content version probe").unwrap();
        let r = root.to_str().unwrap();
        assert!(
            f.run(&["index", "--root", r])["bulk_directories"]
                .as_u64()
                .unwrap()
                > 0
        );
        let mut command = f.cli();
        command.args(["index", "--root", r, "--content-root", r]);
        let (marker, release) = pause_lstat(&f, &mut command, &file, 1);
        let mut scan = Process::launch(&mut command);
        assert_stat_does_not_hold_writer(&f, &marker, &release);
        let output = scan.output.iter().collect::<Vec<_>>().join("\n");
        assert!(scan.child.wait().unwrap().success());
        let stats: Value = serde_json::from_str(&output).unwrap();
        assert!(stats["bulk_directories"].as_u64().unwrap() > 0);
        assert_eq!(f.run(&["content"])["indexed"], 1);
    }

    #[test]
    fn content_worker_rechecks_ancestor_metadata_before_the_writer_transaction() {
        let f = Fixture::new();
        let root = f.0.join("scope");
        let ancestor = root.join("nested");
        fs::create_dir_all(&ancestor).unwrap();
        fs::write(ancestor.join("pending.md"), "metadata lock probe").unwrap();
        let r = root.to_str().unwrap();
        f.run(&["index", "--root", r, "--content-root", r]);
        let mut command = f.cli();
        command.arg("content");
        // The first ancestor stat precedes extraction; pause the second one,
        // which revalidates the result just before it can be published.
        let (marker, release) = pause_lstat(&f, &mut command, &ancestor, 2);
        let mut worker = Process::launch(&mut command);
        assert_stat_does_not_hold_writer(&f, &marker, &release);
        assert_eq!(worker.json()["indexed"], 1);
        assert!(worker.child.wait().unwrap().success());
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

    #[test]
    fn phase1_resident_cloud_parity_and_dataless_protection() {
        let f = Fixture::new();
        let root = f.0.join("workspace");
        let cloud = root.join("Library/CloudStorage/OneDrive-Parity");
        let local_dropbox = root.join("Projects/dropbox");
        let local_onedrive = root.join("Documents/OneDrive");
        for dir in [&cloud, &local_dropbox, &local_onedrive] {
            fs::create_dir_all(dir).unwrap();
        }
        let resident_doc = cloud.join("resident-note.md");
        let late_cloud_doc = cloud.join("late-cloud.md");
        let placeholder_doc = cloud.join("dataless-only.md");
        let resident_img = cloud.join("resident-photo.png");
        fs::write(&resident_doc, "cloudparityneedle readable everywhere").unwrap();
        fs::write(&placeholder_doc, "datalessforbidden must never be read").unwrap();
        fs::write(&resident_img, "resident image payload").unwrap();
        fs::write(local_dropbox.join("repo.md"), "localdropneedle").unwrap();
        fs::write(local_onedrive.join("spec.md"), "localonedriveneedle").unwrap();

        let source = f.0.join("dataless_hook.c");
        let library = f.0.join("dataless_hook.dylib");
        fs::write(
            &source,
            r#"
#include <string.h>
#include <sys/stat.h>
static int hook_lstat(const char *path, struct stat *buf) {
    int rc = lstat(path, buf);
    const char *leaf = strrchr(path, '/');
    if (rc == 0 && leaf && strcmp(leaf, "/dataless-only.md") == 0)
        buf->st_flags |= SF_DATALESS;
    return rc;
}
static int hook_fstatat(int fd, const char *path, struct stat *buf, int flag) {
    int rc = fstatat(fd, path, buf, flag);
    if (rc == 0 && path && strcmp(path, "dataless-only.md") == 0)
        buf->st_flags |= SF_DATALESS;
    return rc;
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interpose_lstat = {hook_lstat, lstat};
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interpose_fstatat = {hook_fstatat, fstatat};
"#,
        )
        .unwrap();
        let cc = Command::new("cc")
            .args(["-dynamiclib", "-o"])
            .arg(&library)
            .arg(&source)
            .output()
            .unwrap();
        assert!(
            cc.status.success(),
            "{}",
            String::from_utf8_lossy(&cc.stderr)
        );

        let run_hooked = |args: &[&str]| -> Value {
            let out = f
                .cli()
                .args(args)
                .env("DYLD_INSERT_LIBRARIES", &library)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            serde_json::from_slice(&out.stdout).unwrap()
        };

        // Narrowed provider() keeps ordinary local folders as "local".
        run_hooked(&[
            "index",
            "--root",
            root.to_str().unwrap(),
            "--content-root",
            cloud.to_str().unwrap(),
        ]);
        assert_eq!(f.run(&["query", "repo.md"])[0]["availability"], "local");
        assert_eq!(f.run(&["query", "spec.md"])[0]["availability"], "local");
        assert_eq!(
            f.run(&["query", "resident-note.md"])[0]["availability"],
            "provider_metadata_only"
        );
        // Simulate catalog classification for the SF_DATALESS placeholder (getattrlistbulk
        // does not go through lstat, so test both catalog & live lstat protection).
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute(
            "UPDATE item SET availability='placeholder' WHERE display='dataless-only.md'",
            [],
        )
        .unwrap();
        db.execute(
            "DELETE FROM content_job WHERE item_id=(SELECT id FROM item WHERE display='dataless-only.md')",
            [],
        )
        .unwrap();

        // Content indexing reads resident cloud doc and skips SF_DATALESS placeholder.
        let content = run_hooked(&["content"]);
        assert_eq!(content["indexed"], 1);
        assert_eq!(
            f.run(&[
                "query",
                "cloudparityneedle",
                "--mode",
                "text",
                "--check-access"
            ])[0]["name"],
            "resident-note.md"
        );
        // Re-inject a stale content_job for dataless-only.md and verify live SF_DATALESS blocks it.
        db.execute_batch(
            "UPDATE item SET availability='provider_metadata_only' WHERE display='dataless-only.md';
             INSERT OR REPLACE INTO content_job(item_id, stamp)
             SELECT id, NULL FROM item WHERE display='dataless-only.md';",
        )
        .unwrap();
        assert_eq!(run_hooked(&["content"])["indexed"], 0);
        assert_eq!(
            f.run(&["query", "datalessforbidden", "--mode", "text"]),
            serde_json::json!([])
        );
        db.execute(
            "UPDATE item SET availability='placeholder' WHERE display='dataless-only.md'",
            [],
        )
        .unwrap();

        // Semantic indexing & search work on resident cloud doc.
        let helper = f.0.join("cloud-parity-embed");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]'\n",
        );
        assert_eq!(
            f.run(&["embed", "--helper", helper.to_str().unwrap()])["new_embeddings"],
            1
        );
        assert_eq!(
            f.run(&[
                "query",
                "cloud parity",
                "--mode",
                "semantic",
                "--helper",
                helper.to_str().unwrap()
            ])[0]["name"],
            "resident-note.md"
        );

        // Diagnose reports indexed / not_indexed cleanly for resident cloud files (never cloud_name_only / unknown),
        // while SF_DATALESS placeholder still reports cloud_name_only.
        assert_eq!(
            f.run(&["diagnose", "--", resident_doc.to_str().unwrap()]),
            serde_json::json!({
                "name": "indexed",
                "text": "indexed",
                "semantic": "pending_gemma",
                "availability": "provider_metadata_only"
            })
        );
        fs::write(&late_cloud_doc, "arrived after scan").unwrap();
        assert_eq!(
            f.run(&["diagnose", "--", late_cloud_doc.to_str().unwrap()]),
            serde_json::json!({
                "name": "not_indexed",
                "text": "not_indexed",
                "semantic": "not_indexed",
                "availability": "provider_metadata_only"
            })
        );
        assert_eq!(
            run_hooked(&["diagnose", "--", placeholder_doc.to_str().unwrap()]),
            serde_json::json!({
                "name": "indexed",
                "text": "cloud_name_only",
                "semantic": "cloud_name_only",
                "availability": "placeholder"
            })
        );

        // Image search scope, status, and hit validation work on resident cloud folders.
        assert_eq!(
            f.run(&["image-scope", cloud.to_str().unwrap()])["root"],
            fs::canonicalize(&cloud).unwrap().to_str().unwrap()
        );
        let img_stamp = metadata_stamp(&resident_img);
        let mut vector = vec![0_u8; 768 * 2];
        vector[..2].copy_from_slice(&0x3c00_u16.to_le_bytes());
        db.execute(
            "INSERT INTO image_embedding SELECT id,?2,?3,?4 FROM item WHERE path=?1",
            rusqlite::params![
                fs::canonicalize(&resident_img).unwrap().to_str().unwrap(),
                lumen::IMAGE_MODEL_ID,
                img_stamp,
                vector
            ],
        )
        .unwrap();
        assert_eq!(f.run(&["image-status"])["vectors"], 1);
        assert_eq!(
            f.run(&[
                "validate-hit",
                "--kind",
                "file",
                "--availability",
                "provider_metadata_only",
                "--document-stamp",
                &img_stamp,
                "--matched-by",
                "image_embedding",
                "--",
                fs::canonicalize(&resident_img).unwrap().to_str().unwrap()
            ])["valid"],
            true
        );
    }

    #[test]
    fn phase1_five_field_stamp_ignores_ctime_and_accepts_legacy_seven_field_rows() {
        let f = Fixture::new();
        let root = f.0.join("docs");
        fs::create_dir_all(&root).unwrap();
        let doc = root.join("stable.md");
        fs::write(&doc, "stablestampneedle unchanged content").unwrap();
        let root_str = root.to_str().unwrap();
        f.run(&["index", "--root", root_str, "--content-root", root_str]);
        assert_eq!(f.run(&["content"])["indexed"], 1);

        let five_field = metadata_stamp(&doc);
        assert_eq!(five_field.split(':').count(), 5);
        let hits = f.run(&[
            "query",
            "stablestampneedle",
            "--mode",
            "text",
            "--check-access",
        ]);
        assert_eq!(hits[0]["document_stamp"], five_field);

        // Rewrite DB rows to simulate a pre-Phase-1 catalog with legacy 7-field stamps.
        let legacy_seven = format!("{five_field}:111111:222222");
        let db = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
        db.execute(
            "UPDATE document_state SET stamp=?1",
            [format!("{legacy_seven}:")],
        )
        .unwrap();
        db.execute(
            "UPDATE content_job SET stamp=?1",
            [format!("{legacy_seven}:")],
        )
        .unwrap();

        // Bump ctime only via chmod without modifying file content or mtime.
        let before_ctime = (
            fs::symlink_metadata(&doc).unwrap().ctime(),
            fs::symlink_metadata(&doc).unwrap().ctime_nsec(),
        );
        thread::sleep(Duration::from_millis(5));
        fs::set_permissions(&doc, fs::Permissions::from_mode(0o600)).unwrap();
        let after_ctime = (
            fs::symlink_metadata(&doc).unwrap().ctime(),
            fs::symlink_metadata(&doc).unwrap().ctime_nsec(),
        );
        assert_ne!(before_ctime, after_ctime, "chmod must advance ctime");
        assert_eq!(metadata_stamp(&doc), five_field);

        // Freshness holds across diagnose, query --check-access, validate-hit, and rescan!
        assert_eq!(
            f.run(&["diagnose", "--", doc.to_str().unwrap()])["text"],
            "indexed"
        );
        assert_eq!(
            f.run(&[
                "query",
                "stablestampneedle",
                "--mode",
                "text",
                "--check-access"
            ])[0]["document_stamp"],
            five_field
        );
        assert_eq!(
            f.run(&[
                "validate-hit",
                "--kind",
                "file",
                "--availability",
                "local",
                "--document-stamp",
                &legacy_seven,
                "--",
                fs::canonicalize(&doc).unwrap().to_str().unwrap()
            ])["valid"],
            true
        );
        // Re-indexing must NOT reset content_job or re-extract the legacy 7-field document.
        f.run(&["index", "--root", root_str, "--content-root", root_str]);
        assert_eq!(f.run(&["status"])["content"]["pending"], 0);
        assert_eq!(f.run(&["content"])["processed"], 0);
        let kept: String = db
            .query_row("SELECT stamp FROM document_state", [], |r| r.get(0))
            .unwrap();
        assert_eq!(kept, format!("{legacy_seven}:"));
    }

    #[test]
    fn phase1_user_target_cookies_caches_are_indexed_while_build_target_excluded() {
        let f = Fixture::new();
        let root = f.0.join("user");
        let target_docs = root.join("Documents/Q4/Target");
        let cookies_docs = root.join("Documents/Recipes/Cookies");
        let caches_docs = root.join("Documents/Caches");
        let cargo_target = root.join("Code/rust-crate/target");
        let maven_target = root.join("Code/java-app/target");
        for dir in [
            &target_docs,
            &cookies_docs,
            &caches_docs,
            &cargo_target,
            &maven_target,
        ] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(
            root.join("Code/rust-crate/Cargo.toml"),
            "[package]\nname = \"demo\"\n",
        )
        .unwrap();
        fs::write(root.join("Code/java-app/pom.xml"), "<project/>").unwrap();

        fs::write(target_docs.join("q4-roadmap.md"), "q4targetneedle").unwrap();
        fs::write(cookies_docs.join("chocolate-chip.md"), "cookierecipeneedle").unwrap();
        fs::write(caches_docs.join("geo-caches.md"), "geocacheneedle").unwrap();
        fs::write(cargo_target.join("cargo-artifact.txt"), "cargonoiseneedle").unwrap();
        fs::write(maven_target.join("maven-artifact.txt"), "mavennoiseneedle").unwrap();

        f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
        assert_eq!(f.run(&["query", "q4-roadmap"])[0]["name"], "q4-roadmap.md");
        assert_eq!(
            f.run(&["query", "q4targetneedle", "--mode", "text"])[0]["name"],
            "q4-roadmap.md"
        );
        assert_eq!(
            f.run(&["query", "chocolate-chip"])[0]["name"],
            "chocolate-chip.md"
        );
        assert_eq!(
            f.run(&["query", "cookierecipeneedle", "--mode", "text"])[0]["name"],
            "chocolate-chip.md"
        );
        assert_eq!(f.run(&["query", "geo-caches"])[0]["name"], "geo-caches.md");
        assert_eq!(
            f.run(&["query", "geocacheneedle", "--mode", "text"])[0]["name"],
            "geo-caches.md"
        );
        assert!(
            f.run(&["query", "cargo-artifact"])
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(
            f.run(&["query", "maven-artifact"])
                .as_array()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn phase1_one_level_symlinks_indexed_safely_without_loops() {
        let f = Fixture::new();
        let root = f.0.join("workspace");
        let apps = root.join("Apps");
        let docs = root.join("Docs");
        let denied = root.join("Denied");
        let cask_app = f.0.join("Caskroom/HomebrewTool.app");
        let external_notes = f.0.join("ExternalNotes");
        for dir in [&apps, &docs, &denied, &cask_app, &external_notes] {
            fs::create_dir_all(dir).unwrap();
        }
        fs::write(cask_app.join("inner-binary.txt"), "inside cask bundle").unwrap();
        let ext_note = external_notes.join("linked-note.md");
        fs::write(&ext_note, "symlinkednotebody must not be extracted").unwrap();
        fs::write(denied.join("secret.md"), "denied secret").unwrap();

        // 1-level symlinks: cask .app bundle, leaf file, and cyclic directory link to root!
        let app_link = apps.join("HomebrewTool.app");
        let file_link = docs.join("linked-note.md");
        let loop_link = docs.join("loop-back");
        let chain_link = docs.join("two-hop.md");
        let denied_link = docs.join("denied-shortcut");
        symlink(&cask_app, &app_link).unwrap();
        symlink(&ext_note, &file_link).unwrap();
        symlink(&root, &loop_link).unwrap();
        symlink(&file_link, &chain_link).unwrap();
        symlink(&denied, &denied_link).unwrap();

        f.run(&[
            "index",
            "--root",
            root.to_str().unwrap(),
            "--deny",
            denied.to_str().unwrap(),
            "--documents",
        ]);
        // 1-level symlinks ARE searchable as leaf entries (no infinite loop!).
        let app_hits = f.run(&["query", "HomebrewTool.app"]);
        assert_eq!(app_hits.as_array().unwrap().len(), 1);
        assert_eq!(app_hits[0]["kind"], "directory");
        let file_hits = f.run(&["query", "linked-note.md"]);
        assert_eq!(file_hits.as_array().unwrap().len(), 1);
        assert_eq!(file_hits[0]["kind"], "file");
        assert_eq!(f.run(&["query", "loop-back"])[0]["kind"], "directory");

        // Never descend into symlinked directories or traverse 2-level / denied symlinks.
        assert!(
            f.run(&["query", "inner-binary"])
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(f.run(&["query", "two-hop"]).as_array().unwrap().is_empty());
        assert!(
            f.run(&["query", "denied-shortcut"])
                .as_array()
                .unwrap()
                .is_empty()
        );
        // Never extract content through a symlink.
        assert!(
            f.run(&["query", "symlinkednotebody", "--mode", "text"])
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            f.run(&[
                "validate-hit",
                "--kind",
                "directory",
                "--availability",
                "local",
                "--",
                fs::canonicalize(&apps)
                    .unwrap()
                    .join("HomebrewTool.app")
                    .to_str()
                    .unwrap()
            ])["valid"],
            true
        );
    }

    #[test]
    fn phase1_watch_transient_io_errors_do_not_mark_subtrees_unverified() {
        let f = Fixture::new();
        let root = f.0.join("watched");
        let sub = root.join("flaky-provider");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("important.md"), "transientrecoveryneedle").unwrap();
        let root_str = root.to_str().unwrap();
        f.run(&["index", "--root", root_str, "--documents"]);
        // Establish a settled watch checkpoint after initial fixture writes so
        // the subsequent cached start exercises resume::verify_access directly.
        let settle = Process::launch(f.cli().args(["watch", "--cached-start"]));
        assert_eq!(settle.json()["event"], "cached");
        assert_eq!(settle.json()["event"], "ready");
        drop(settle);

        // Inject EBUSY on open() for the flaky-provider directory during cached watch start.
        let source = f.0.join("ebusy_open.c");
        let library = f.0.join("ebusy_open.dylib");
        let hit_marker = f.0.join("ebusy-triggered");
        fs::write(
            &source,
            r#"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int hook_open(const char *path, int oflag, ...) {
    const char *target = getenv("LUMEN_TEST_EBUSY_TARGET");
    if (target && path && strcmp(path, target) == 0) {
        const char *marker = getenv("LUMEN_TEST_EBUSY_MARKER");
        if (marker) {
            int fd = open(marker, O_CREAT | O_WRONLY, 0600);
            if (fd >= 0) close(fd);
        }
        errno = EBUSY;
        return -1;
    }
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return open(path, oflag, mode);
    }
    return open(path, oflag);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interpose_open = {hook_open, open};
"#,
        )
        .unwrap();
        let cc = Command::new("cc")
            .args(["-dynamiclib", "-o"])
            .arg(&library)
            .arg(&source)
            .output()
            .unwrap();
        assert!(
            cc.status.success(),
            "{}",
            String::from_utf8_lossy(&cc.stderr)
        );

        let mut command = f.cli();
        command
            .args(["watch", "--cached-start", "--progress"])
            .stderr(Stdio::piped())
            .env("DYLD_INSERT_LIBRARIES", &library)
            .env("LUMEN_TEST_EBUSY_TARGET", fs::canonicalize(&sub).unwrap())
            .env("LUMEN_TEST_EBUSY_MARKER", &hit_marker);
        let mut watcher = Process::launch(&mut command);
        assert_eq!(watcher.json()["event"], "cached");
        assert_eq!(watcher.json()["event"], "ready");
        watcher.child.kill().unwrap();
        let stderr = std::io::read_to_string(watcher.child.stderr.take().unwrap()).unwrap();
        assert!(
            hit_marker.exists(),
            "EBUSY interposer must have fired during verify_access"
        );
        assert!(stderr.contains("lumen watch: recovered"), "{stderr}");

        assert_eq!(f.run(&["status"])["unverified"], 0);
        assert_eq!(f.run(&["query", "important.md"])[0]["name"], "important.md");
        assert_eq!(
            f.run(&["query", "transientrecoveryneedle", "--mode", "text"])[0]["name"],
            "important.md"
        );
    }

    #[test]
    fn content_poison_pill_timeout_and_denied_report_skipped_and_index_healthy_docs() {
        use std::os::unix::fs::PermissionsExt;
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let f = Fixture::new();
        let root = f.0.join("docs");
        fs::create_dir_all(&root).unwrap();
        let timeout_pdf = root.join("01-timeout.pdf");
        let denied_doc = root.join("02-denied.txt");
        let healthy_doc = root.join("03-healthy.md");
        fs::write(&timeout_pdf, "%PDF-1.4\n").unwrap();
        fs::write(&denied_doc, "denied poison pill document").unwrap();
        fs::write(&healthy_doc, "healthy document after poison pills").unwrap();
        // Jobs run newest first: both poison pills are newer than the healthy file.
        set_age(&denied_doc, 60);
        set_age(&healthy_doc, 120);
        let helper = f.0.join("pdf-timeout-helper");
        executable(&helper, "#!/bin/sh\ncat >/dev/null\nwhile :; do :; done\n");

        let root_str = root.to_str().unwrap();
        f.run(&[
            "index",
            "--root",
            root_str,
            "--content-root",
            root_str,
            "--documents",
            "--pdf-helper",
            helper.to_str().unwrap(),
        ]);
        fs::set_permissions(&denied_doc, fs::Permissions::from_mode(0o000)).unwrap();

        let first = f.run(&["content"]);
        assert_eq!(first["processed"], 0);
        assert_eq!(first["indexed"], 0);
        assert!(first["skipped"].as_u64().unwrap() >= 1, "{first}");
        assert_eq!(first["pending"], 3);

        let second = f.run(&["content", "--max", "1"]);
        assert_eq!(second["processed"], 1);
        assert_eq!(second["indexed"], 1);
        assert_eq!(second["skipped"], 1);
        assert_eq!(second["pending"], 2);
        assert_eq!(
            Serve::new(&f).names("healthy document after poison pills", "text"),
            ["03-healthy.md"]
        );

        let denied_only = f.run(&["content", "--max", "1"]);
        assert_eq!(denied_only["processed"], 0);
        assert!(
            denied_only["skipped"].as_u64().unwrap() >= 1,
            "{denied_only}"
        );
        fs::set_permissions(&denied_doc, fs::Permissions::from_mode(0o600)).unwrap();
    }

    #[test]
    fn embed_and_image_index_stream_flags_emit_valid_json_lines() {
        let f = Fixture::new();
        let docs = f.0.join("docs");
        let empty_images = f.0.join("empty-images");
        fs::create_dir_all(&docs).unwrap();
        fs::create_dir_all(&empty_images).unwrap();

        // Empty Gemma content scope with `--stream` emits one clean EmbedBatch line without booting llama-server.
        f.run(&[
            "index",
            "--root",
            empty_images.to_str().unwrap(),
            "--documents",
        ]);
        let empty_gemma = f
            .cli()
            .args([
                "embed",
                "--gemma",
                "--gemma-home",
                f.0.join("unused-gemma").to_str().unwrap(),
                "--stream",
                "--max",
                "32",
            ])
            .output()
            .unwrap();
        assert!(
            empty_gemma.status.success(),
            "{}",
            String::from_utf8_lossy(&empty_gemma.stderr)
        );
        let empty_gemma_lines: Vec<Value> = String::from_utf8_lossy(&empty_gemma.stdout)
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(
            empty_gemma_lines,
            [serde_json::json!({"new_embeddings":0,"skipped_chunks":0,"has_more":false})]
        );

        for i in 0..5 {
            fs::write(docs.join(format!("doc-{i}.md")), format!("Stream body {i}")).unwrap();
        }
        let helper = f.0.join("embed-helper");
        executable(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf '[1,0,0,0,0,0,0,0]\\n'\n",
        );

        f.run(&[
            "index",
            "--root",
            docs.to_str().unwrap(),
            "--root",
            empty_images.to_str().unwrap(),
            "--content-root",
            docs.to_str().unwrap(),
        ]);
        f.run(&["content", "--max", "32"]);

        let stream_out = f
            .cli()
            .args([
                "embed",
                "--helper",
                helper.to_str().unwrap(),
                "--stream",
                "--max",
                "2",
            ])
            .output()
            .unwrap();
        assert!(
            stream_out.status.success(),
            "{}",
            String::from_utf8_lossy(&stream_out.stderr)
        );
        let lines: Vec<Value> = String::from_utf8_lossy(&stream_out.stdout)
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(
            lines[0],
            serde_json::json!({"new_embeddings":2,"skipped_chunks":0,"has_more":true})
        );
        assert_eq!(
            lines[1],
            serde_json::json!({"new_embeddings":2,"skipped_chunks":0,"has_more":true})
        );
        assert_eq!(
            lines[2],
            serde_json::json!({"new_embeddings":1,"skipped_chunks":0,"has_more":false})
        );

        // Verify `image-index --stream` on an empty folder emits 1 ImageBatch JSON line cleanly.
        f.run(&["image-scope", empty_images.to_str().unwrap()]);
        let image_out = f
            .cli()
            .args([
                "image-index",
                "--projector",
                f.0.join("unused.gguf").to_str().unwrap(),
                "--stream",
                "--max",
                "16",
            ])
            .output()
            .unwrap();
        assert!(
            image_out.status.success(),
            "{}",
            String::from_utf8_lossy(&image_out.stderr)
        );
        let image_lines: Vec<Value> = String::from_utf8_lossy(&image_out.stdout)
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(image_lines.len(), 1);
        assert_eq!(image_lines[0]["processed"], 0);
        assert_eq!(image_lines[0]["next_after"], Value::Null);
    }
}

#[cfg(target_os = "macos")]
#[test]
fn unmounted_network_and_legacy_volume_catalogs_report_kind_and_fail_closed() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let local = f.0.join("local");
    fs::create_dir(&local).unwrap();
    f.run(&["index", "--root", local.to_str().unwrap()]);
    let folder = f.0.join("test.sqlite-external");
    fs::create_dir(&folder).unwrap();
    fs::set_permissions(&folder, fs::Permissions::from_mode(0o700)).unwrap();
    let nas = "277c4245-278e-cdeb-a5bc-0e32d5fe1ddc";
    let legacy = "01234567-89ab-cdef-0123-456789abcdef";
    let catalogs = [
        (
            nas,
            "/Volumes/Lumen-CLI-NAS",
            r#""mount_kind":"network","protocol":"smb","sanitized_source":"smb://nas/share""#,
        ),
        // Written before `mount_kind` existed.
        (
            legacy,
            "/Volumes/Lumen-CLI-Legacy",
            r#""filesystem_id":[1,2],"media_id":3,"boot":"stale-boot","source":"/dev/disk9s1""#,
        ),
    ];
    let mut files = Vec::new();
    for (uuid, root, identity) in catalogs {
        let sidecar = folder.join(format!("{uuid}.sqlite"));
        let created = Command::new(env!("CARGO_BIN_EXE_lumen"))
            .arg("--db")
            .arg(&sidecar)
            .args(["index", "--root"])
            .arg(&local)
            .output()
            .unwrap();
        assert!(
            created.status.success(),
            "{}",
            String::from_utf8_lossy(&created.stderr)
        );
        let db = rusqlite::Connection::open(&sidecar).unwrap();
        let file = format!("{root}/cli-netvol-report.txt");
        db.execute(
            "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
             VALUES(?1,'cli-netvol-report.txt','file','local','cli-netvol-report.txt','','',?1)",
            [&file],
        )
        .unwrap();
        db.execute(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
             SELECT id,name,full,initials,searchable_path FROM item WHERE path=?1",
            [&file],
        )
        .unwrap();
        db.execute(
            "INSERT OR REPLACE INTO info(key,value) VALUES('external_volume',?1)",
            [format!(r#"{{"path":"{root}","uuid":"{uuid}",{identity}}}"#)],
        )
        .unwrap();
        files.push(file);
    }
    let volumes = f.run(&["volumes"]);
    let status = |uuid: &str| {
        volumes
            .as_array()
            .unwrap()
            .iter()
            .find(|volume| volume["uuid"] == uuid)
            .unwrap_or_else(|| panic!("{uuid} missing from {volumes}"))
            .clone()
    };
    let network = status(nas);
    assert_eq!(network["kind"], "network");
    assert_eq!(network["protocol"], "smb");
    let external = status(legacy);
    assert_eq!(external["kind"], "external");
    assert_eq!(external["protocol"], Value::Null);
    for volume in [network, external] {
        assert_eq!(volume["available"], false);
        assert_eq!(volume["indexed"], false);
        assert_eq!(volume["needs_refresh"], true);
    }
    // Neither share is mounted: no hits, no validation, no diagnosis.
    assert_eq!(
        f.run(&["query", "cli-netvol-report"]),
        serde_json::json!([])
    );
    for file in &files {
        assert_eq!(
            f.run(&[
                "validate-hit",
                "--kind",
                "file",
                "--availability",
                "local",
                "--",
                file
            ]),
            serde_json::json!({"valid": false}),
        );
        assert_eq!(
            f.run(&["diagnose", "--", file])["name"],
            "index_unavailable"
        );
    }
}

#[test]
fn content_filter_json_survives_restarts_and_preview_reads_the_catalog() {
    let f = Fixture::new();
    let docs = fs::canonicalize(&f.0).unwrap().join("docs");
    for name in ["notes.md", "dist/bundle.md", "src/lib.rs", "tools/run.py"] {
        let path = docs.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "content").unwrap();
    }
    let docs = docs.to_str().unwrap();
    f.run(&["index", "--root", docs, "--separate-content"]);
    let raw: String = rusqlite::Connection::open(f.0.join("test.sqlite"))
        .unwrap()
        .query_row("SELECT value FROM info WHERE key='scope'", [], |r| r.get(0))
        .unwrap();
    assert!(!raw.contains("content_filter"), "{raw}");
    let filter = r#"{"enable_code":true,"deny_folders":["src"]}"#;
    let scoped = f.run(&[
        "content-scope",
        "--content-root",
        docs,
        "--content-filter-json",
        filter,
    ]);
    assert_eq!(scoped["scope"]["content_filter"]["enable_code"], true);
    // notes.md and tools/run.py; dist/ is noise and src/ is denied.
    assert_eq!(scoped["content"]["pending"], 2);
    // Restarting with an explicit scope but no filter keeps the saved filter.
    f.run(&[
        "index",
        "--root",
        docs,
        "--separate-content",
        "--content-root",
        docs,
    ]);
    let status = f.run(&["status", "--include-scope"]);
    assert_eq!(
        status["scope"]["content_filter"]["deny_folders"],
        serde_json::json!(["src"])
    );
    assert_eq!(status["content"]["total"], 2);
    let preview = f.run(&[
        "preview-content-scope",
        "--content-root",
        docs,
        "--content-filter-json",
        "{}",
    ]);
    assert_eq!(preview["total_files"], 1);
    assert_eq!(
        preview["by_category"],
        serde_json::json!({"pdf":0,"docx":0,"text":1,"images":0,"code":0})
    );
    let saved = f.run(&["preview-content-scope"]);
    assert_eq!(saved["total_files"], 2);
    assert_eq!(saved["by_category"]["code"], 1);
    assert_eq!(saved["top_subfolders"][0]["name"], "tools");
    let rejected = f
        .cli()
        .args([
            "content-scope",
            "--content-root",
            docs,
            "--content-filter-json",
            "{bad",
        ])
        .output()
        .unwrap();
    assert!(!rejected.status.success());
}

#[test]
fn local_openai_missing_unix_socket_keeps_status_working_while_failing_probe_and_embed() {
    let f = Fixture::new();
    let docs = fs::canonicalize(&f.0).unwrap().join("docs");
    fs::create_dir_all(&docs).unwrap();
    fs::write(
        docs.join("manual.md"),
        "Orbital rendezvous guidance and thermal radiator calibration notes.",
    )
    .unwrap();
    f.run(&["index", "--root", docs.to_str().unwrap(), "--documents"]);

    let missing_sock = format!("unix://{}", f.0.join("stopped-server.sock").display());

    // 1. status and status --include-scope MUST succeed cleanly when the Unix socket is missing.
    let status = f.run(&[
        "status",
        "--openai-url",
        &missing_sock,
        "--openai-model",
        "m",
    ]);
    assert_eq!(status["documents"], 1);
    assert!(status["local_openai"]["model_id"].is_null());
    assert!(status["local_openai"]["dimensions"].is_null());
    assert_eq!(status["local_openai"]["coverage"]["embedded_chunks"], 0);
    assert_eq!(status["local_openai"]["coverage"]["pending"], true);
    assert_eq!(status["gemma"]["pending"], true);

    let scoped = f.run(&[
        "status",
        "--include-scope",
        "--openai-url",
        &missing_sock,
        "--openai-model",
        "m",
    ]);
    assert_eq!(scoped["documents"], 1);
    assert_eq!(scoped["scope"]["documents"], true);
    assert!(scoped["local_openai"]["model_id"].is_null());

    // Misconfigured non-loopback URL also degrades cleanly in status without aborting it.
    let misconfigured = f.run(&[
        "status",
        "--openai-url",
        "https://api.openai.com/v1",
        "--openai-model",
        "m",
    ]);
    assert_eq!(misconfigured["documents"], 1);
    assert!(misconfigured["local_openai"]["model_id"].is_null());
    assert_eq!(misconfigured["local_openai"]["coverage"]["pending"], true);

    // Text search stays completely usable while the optional local OpenAI server is stopped.
    assert_eq!(
        f.run(&["query", "Orbital rendezvous", "--mode", "text"])[0]["name"],
        "manual.md"
    );

    // 2. model-status (both unchecked and --verify) MUST report unavailable with Unix socket error.
    for args in [
        vec![
            "model-status",
            "--openai-url",
            &missing_sock,
            "--openai-model",
            "m",
        ],
        vec![
            "model-status",
            "--verify",
            "--openai-url",
            &missing_sock,
            "--openai-model",
            "m",
        ],
    ] {
        let model_status = f.run(&args);
        assert_eq!(model_status["backend"], "local_openai");
        assert_eq!(model_status["available"], false);
        assert_eq!(model_status["verified"], false);
        let diagnostic = model_status["diagnostic"].as_str().unwrap_or("");
        assert!(
            diagnostic.contains("Unix socket"),
            "expected Unix socket error in diagnostic: {model_status}"
        );
    }

    // 3. embed and semantic-serve MUST error cleanly on the missing Unix socket.
    for args in [
        vec![
            "embed",
            "--openai-url",
            &missing_sock,
            "--openai-model",
            "m",
        ],
        vec![
            "semantic-serve",
            "--openai-url",
            &missing_sock,
            "--openai-model",
            "m",
        ],
    ] {
        let out = f.cli().args(&args).output().unwrap();
        assert!(
            !out.status.success(),
            "expected command {args:?} to fail on missing Unix socket"
        );
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("Unix socket"),
            "expected Unix socket error in stderr for {args:?}, got: {stderr}"
        );
    }
}

#[test]
fn v1_downgrade_fixture_cleanly_rebuilds_gemma_pending_queue() {
    let f = Fixture::new();
    let root = f.0.join("scope");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("note.md"), "Synthetic v1 downgrade schema check.").unwrap();
    f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);

    let raw = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
    raw.execute_batch(
        "PRAGMA user_version=1;
         DROP TRIGGER semantic_versioned_chunk_deleted;
         DROP TRIGGER IF EXISTS gemma_pending_chunk_deleted;
         DROP TRIGGER IF EXISTS gemma_pending_chunk_inserted;
         DROP TABLE IF EXISTS gemma_pending_chunk;
         DELETE FROM info WHERE key='gemma_pending_model';
         DROP TABLE semantic_vector; DROP TABLE semantic_vector_count;",
    )
    .unwrap();
    drop(raw);

    // Re-opening via CLI write path migrates v1 -> current schema cleanly and restores all triggers.
    f.run(&["index", "--root", root.to_str().unwrap(), "--documents"]);
    let raw = rusqlite::Connection::open(f.0.join("test.sqlite")).unwrap();
    let trigger_count: i64 = raw
        .query_row(
            "SELECT count(*) FROM sqlite_schema
             WHERE type='trigger' AND name IN (
                'gemma_pending_chunk_inserted',
                'gemma_pending_chunk_deleted',
                'gemma_pending_vector_inserted',
                'gemma_pending_vector_deleted'
             )",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(trigger_count, 4);
}
