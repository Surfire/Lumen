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
