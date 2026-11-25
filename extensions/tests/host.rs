use lumen_extensions::{Extension, RunOutput};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::atomic::{AtomicUsize, Ordering},
};

const PACKAGE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/examples/search-notes");
const EXAMPLE: &str = include_str!("../examples/search-notes/src/format-note.js");

#[test]
fn sample_commands_run_through_cli() {
    let package = Path::new(PACKAGE);
    let catalog = success(cli(package, &["list"]));
    assert_eq!(catalog["name"], "lumen-search-notes");
    assert_eq!(catalog["commands"][1]["arguments"][0]["name"], "topic");
    assert_eq!(catalog["commands"][1]["arguments"][0]["type"], "text");
    assert!(catalog["commands"][1]["unsupported_reason"].is_null());

    assert_eq!(
        success(cli(package, &["run", "show-ready"])),
        json!({"hud": "Lumen Search Notes is ready."})
    );
    assert_eq!(
        success(cli(
            package,
            &[
                "run",
                "format-note",
                "--arg",
                "topic=索引",
                "--arg",
                "message=只包含本地文件 📝"
            ]
        )),
        json!({"hud": "[索引] 只包含本地文件 📝"})
    );

    let missing = cli(package, &["run", "format-note", "--arg", "topic=Index"]);
    assert!(!missing.status.success());
    assert!(missing.stdout.is_empty());
    assert!(String::from_utf8_lossy(&missing.stderr).contains("missing required argument"));
    let duplicate = cli(
        package,
        &["run", "format-note", "--arg", "topic=1", "--arg", "topic=2"],
    );
    assert!(!duplicate.status.success());
    assert!(String::from_utf8_lossy(&duplicate.stderr).contains("duplicate argument"));
    assert!(
        !Command::new(env!("CARGO_BIN_EXE_lumen-extensions"))
            .arg("list")
            .output()
            .unwrap()
            .status
            .success()
    );
}

#[test]
fn host_executes_validated_source_and_treats_arguments_as_text() {
    let fixture = Fixture::new();
    let source = fixture.path.join("src/format-note.js");
    fs::write(&source, EXAMPLE.replace("] ", "] Changed = ")).unwrap();
    let extension = Extension::open(&fixture.path).unwrap();
    fs::remove_file(source).unwrap();
    let input = BTreeMap::from([
        ("topic".to_owned(), "local".to_owned()),
        (
            "message".to_owned(),
            r#"" + fetch("synthetic") + ""#.to_owned(),
        ),
    ]);
    assert_eq!(
        extension.run("format-note", &input).unwrap(),
        RunOutput::Hud {
            hud: r#"[local] Changed = " + fetch("synthetic") + ""#.to_owned()
        }
    );
    let mut extra = input.clone();
    extra.insert("extra".into(), "ignored?".into());
    assert!(extension.run("format-note", &extra).is_err());
    extra.remove("extra");
    extra.insert("topic".into(), "界".repeat(400));
    assert!(extension.run("format-note", &extra).is_err());
}

#[test]
fn unsupported_code_cannot_run_and_leaves_other_commands_available() {
    let fixture = Fixture::new();
    for source in [
        format!("import {{ readFile }} from \"node:fs\";\n{EXAMPLE}"),
        EXAMPLE.replace("props.arguments.topic", "fetch(\"synthetic\")"),
        EXAMPLE.replace("props.arguments.topic", "props.arguments.other"),
        EXAMPLE.replace("props.arguments.topic", "process.env.HOME"),
        format!("{EXAMPLE}\nshowHUD(\"second call\");"),
        EXAMPLE.replace("async function", "async\nfunction"),
        EXAMPLE.replace(
            "from \"@raycast/api\";\n\nexport",
            "from \"@raycast/api\"export",
        ),
    ] {
        fs::write(fixture.path.join("src/format-note.js"), source).unwrap();
        let extension = Extension::open(&fixture.path).unwrap();
        assert!(extension.info().commands[0].unsupported_reason.is_none());
        assert!(extension.info().commands[1].unsupported_reason.is_some());
        let output = cli(&fixture.path, &["run", "format-note"]);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("unsupported"));
    }
}

#[test]
fn markdown_link_preview_formats_original_text_through_cli() {
    let package = Path::new(PACKAGE);
    let catalog = success(cli(package, &["list"]));
    assert!(catalog["commands"][2]["unsupported_reason"].is_null());
    assert_eq!(
        success(cli(
            package,
            &[
                "run",
                "copy-markdown-link",
                "--arg",
                "title=\u{feff}索引 [v2]\\草稿\u{3000}",
                "--arg",
                "url= https://example.test/测试 路径(v2)<x> ",
            ],
        )),
        json!({"clipboard": {
            "text": r"[索引 \[v2\]\\草稿](<https://example.test/测试%20路径(v2)%3Cx%3E>)"
        }})
    );
}

#[test]
fn clipboard_host_rejects_other_operations_and_unbounded_transforms() {
    let fixture = Fixture::new();
    let source = fixture.path.join("src/copy-markdown-link.js");
    let command = |statement: &str| {
        format!(
            "import {{ Clipboard }} from \"@raycast/api\";\nexport default async function Command(props) {{ await {statement}; }}"
        )
    };
    for statement in [
        r#"Clipboard.readText()"#,
        r#"Clipboard.clear()"#,
        r#"Clipboard.paste("text")"#,
        r#"Clipboard.copy({"file":"synthetic.txt"})"#,
        r#"Clipboard.copy({"text":"synthetic"})"#,
        r#"Clipboard.copy(123)"#,
        r#"Clipboard.copy("text", {"concealed":true})"#,
        r#"Clipboard.copy("text".replaceAll(/t/g, "x"))"#,
        r#"Clipboard.copy("text".replaceAll("", "x"))"#,
        r#"Clipboard.copy("text".replaceAll("t", "$&"))"#,
        r#"Clipboard.copy("text".repeat(2))"#,
        r#"Clipboard.copy("text"); await Clipboard.copy("again")"#,
        r#"Clipboard.copy("text".trim().trim().trim().trim().trim().trim().trim().trim().trim())"#,
    ] {
        fs::write(&source, command(statement)).unwrap();
        let listing = success(cli(&fixture.path, &["list"]));
        assert!(
            !listing["commands"][2]["unsupported_reason"].is_null(),
            "unexpectedly accepted {statement}"
        );
        let output = cli(&fixture.path, &["run", "copy-markdown-link"]);
        assert!(!output.status.success() && output.stdout.is_empty());
    }

    fs::write(
        &source,
        command(
            r#"Clipboard.copy(props.arguments.title.replaceAll("a", "aaaaa").replaceAll("a", ""))"#,
        ),
    )
    .unwrap();
    let long_title = format!("title={}", "a".repeat(1_000));
    let output = cli(
        &fixture.path,
        &[
            "run",
            "copy-markdown-link",
            "--arg",
            &long_title,
            "--arg",
            "url=test",
        ],
    );
    assert!(!output.status.success() && output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("clipboard text exceeds 4096 bytes"));
}

#[test]
fn unsupported_modes_and_manifest_features_are_reported() {
    let fixture = Fixture::new();
    let mut manifest = manifest();
    for mode in ["view", "menu-bar"] {
        manifest["commands"][1]["mode"] = json!(mode);
        fixture.write_manifest(&manifest);
        assert_eq!(
            success(cli(&fixture.path, &["list"]))["commands"][1]["unsupported_reason"],
            "only no-view commands are supported"
        );
    }
    manifest["commands"][1]["mode"] = json!("no-view");
    manifest["commands"][1]["interval"] = json!("1m");
    fixture.write_manifest(&manifest);
    assert_eq!(
        success(cli(&fixture.path, &["list"]))["commands"][1]["unsupported_reason"],
        "background refresh is unsupported"
    );
    manifest["commands"][1]
        .as_object_mut()
        .unwrap()
        .remove("interval");
    manifest["commands"][1]["arguments"][0]["type"] = json!("password");
    fixture.write_manifest(&manifest);
    assert_eq!(
        success(cli(&fixture.path, &["list"]))["commands"][1]["unsupported_reason"],
        "only required text arguments are supported"
    );
}

#[test]
fn rejects_bad_package_platform_paths_dependencies_and_oversized_source() {
    let fixture = Fixture::new();
    for (edit, expected) in [
        (("/platforms", json!(["Windows"])), "must declare macOS"),
        (
            ("/commands/1/name", json!("../outside")),
            "invalid command name",
        ),
        (
            ("/commands/1/name", json!("show-ready")),
            "duplicate command",
        ),
        (
            ("/dependencies", json!({"other": "1"})),
            "only runtime dependency",
        ),
    ] {
        let mut modified = manifest();
        *modified.pointer_mut(edit.0).unwrap() = edit.1;
        fixture.write_manifest(&modified);
        assert!(
            Extension::open(&fixture.path)
                .unwrap_err()
                .to_string()
                .contains(expected)
        );
    }
    fixture.write_manifest(&manifest());
    fs::write(
        fixture.path.join("src/format-note.js"),
        " ".repeat(16 * 1024 + 1),
    )
    .unwrap();
    assert!(
        Extension::open(&fixture.path).unwrap().info().commands[1]
            .unsupported_reason
            .as_ref()
            .unwrap()
            .contains("at most 16384 bytes")
    );
}

#[test]
fn package_files_cannot_follow_links() {
    let fixture = Fixture::new();
    let original = fixture.path.join("outside.js");
    fs::write(&original, EXAMPLE).unwrap();
    let source = fixture.path.join("src/format-note.js");
    fs::remove_file(&source).unwrap();
    symlink(&original, &source).unwrap();
    assert!(
        Extension::open(&fixture.path).unwrap().info().commands[1]
            .unsupported_reason
            .is_some()
    );
    fs::remove_file(&source).unwrap();
    fs::hard_link(&original, &source).unwrap();
    assert!(
        Extension::open(&fixture.path).unwrap().info().commands[1]
            .unsupported_reason
            .is_some()
    );

    fs::rename(fixture.path.join("src"), fixture.path.join("other")).unwrap();
    symlink(fixture.path.join("other"), fixture.path.join("src")).unwrap();
    assert!(
        Extension::open(&fixture.path)
            .unwrap()
            .info()
            .commands
            .iter()
            .all(|entry| entry.unsupported_reason.is_some())
    );
    fs::rename(
        fixture.path.join("package.json"),
        fixture.path.join("other.json"),
    )
    .unwrap();
    symlink(
        fixture.path.join("other.json"),
        fixture.path.join("package.json"),
    )
    .unwrap();
    assert!(Extension::open(&fixture.path).is_err());
}

#[cfg(target_os = "macos")]
#[test]
fn package_paths_reject_symlink_ancestors() {
    let fixture = Fixture::new();
    let alias = fixture.path.join("parent-alias");
    symlink(fixture.path.parent().unwrap(), &alias).unwrap();
    let through_alias = alias.join(fixture.path.file_name().unwrap());
    let failure = Extension::open(&through_alias).unwrap_err();
    assert!(
        failure
            .to_string()
            .contains("open explicit extension directory")
    );
}

#[cfg(target_os = "macos")]
#[test]
fn expected_snapshot_binds_execution_to_the_listed_package() {
    let fixture = Fixture::new();
    let listing = success(cli(&fixture.path, &["list"]));
    let snapshot = listing["snapshot"].as_str().unwrap();
    assert_eq!(snapshot.len(), 64);
    let args = ["run", "show-ready", "--expect-snapshot", snapshot];
    assert_eq!(
        success(cli(&fixture.path, &args)),
        json!({"hud": "Lumen Search Notes is ready."})
    );
    let replacement = Fixture::new();
    assert_stale(cli(&replacement.path, &args));

    let source = fixture.path.join("src/show-ready.js");
    let original = fs::read_to_string(&source).unwrap();
    fs::write(&source, original.replace("is ready", "has changed")).unwrap();
    assert_stale(cli(&fixture.path, &args));
    let updated = success(cli(&fixture.path, &["list"]));
    let updated = updated["snapshot"].as_str().unwrap();
    let args = ["run", "show-ready", "--expect-snapshot", updated];
    assert_eq!(
        success(cli(&fixture.path, &args)),
        json!({"hud": "Lumen Search Notes has changed."})
    );

    let mut changed_manifest = manifest();
    changed_manifest["title"] = json!("A changed manifest");
    fixture.write_manifest(&changed_manifest);
    assert_stale(cli(&fixture.path, &args));
    fs::write(
        fixture.path.join("package.json"),
        "invalid synthetic manifest",
    )
    .unwrap();
    assert_stale(cli(&fixture.path, &args));
}

#[cfg(target_os = "macos")]
fn assert_stale(output: Output) {
    assert_eq!(output.status.code(), Some(3));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("refresh the command list"));
}

fn cli(package: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_lumen-extensions"))
        .arg("--package")
        .arg(package)
        .args(args)
        .output()
        .unwrap()
}

fn success(output: Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn manifest() -> Value {
    serde_json::from_str(include_str!("../examples/search-notes/package.json")).unwrap()
}

struct Fixture {
    path: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let parent = std::env::temp_dir().canonicalize().unwrap();
        let path = loop {
            let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!(
                "lumen-extensions-{}-{sequence}",
                std::process::id()
            ));
            match fs::create_dir(&path) {
                Ok(()) => break path,
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(err) => panic!("create synthetic test package: {err}"),
            }
        };
        fs::create_dir(path.join("src")).unwrap();
        for file in ["format-note.js", "show-ready.js", "copy-markdown-link.js"] {
            fs::copy(
                Path::new(PACKAGE).join("src").join(file),
                path.join("src").join(file),
            )
            .unwrap();
        }
        let fixture = Self { path };
        fixture.write_manifest(&manifest());
        fixture
    }

    fn write_manifest(&self, manifest: &Value) {
        fs::write(self.path.join("package.json"), manifest.to_string()).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
