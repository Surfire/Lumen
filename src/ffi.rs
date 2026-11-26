//! Read-only C transport for the same search session used by `lumen serve`.
use crate::{Hit, Mode, SearchSession, verify_cached_access};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr,
};

pub struct LumenSessionHandle(SearchSession);

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Operation {
    Search,
    Validate,
}

#[derive(Deserialize)]
struct Request {
    id: u64,
    op: Option<Operation>,
    query: Option<String>,
    #[serde(default)]
    mode: Mode,
    limit: Option<usize>,
    check_access: Option<bool>,
    hits: Option<Vec<ValidationHit>>,
}

#[derive(Deserialize)]
struct ValidationHit {
    path: String,
    kind: String,
    availability: String,
    document_stamp: Option<String>,
    matched_by: Option<String>,
}

#[derive(Serialize)]
#[serde(untagged)]
enum Reply {
    Search { id: u64, hits: Vec<Hit> },
    Validate { id: u64, valid: Vec<bool> },
}

// The caller vouches that each non-null pointer is live for the duration of the call.
unsafe fn input<'a>(ptr: *const c_char) -> Result<&'a str> {
    ensure!(!ptr.is_null(), "null string pointer");
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_session_open(
    db: *const c_char,
    root: *const c_char,
) -> *mut LumenSessionHandle {
    catch_unwind(|| -> Result<_> {
        let db = unsafe { input(db)? };
        ensure!(
            !db.is_empty() && (root.is_null() || !unsafe { input(root)? }.is_empty()),
            "empty path"
        );
        let session = SearchSession::open(Path::new(db))?;
        Ok(Box::into_raw(Box::new(LumenSessionHandle(session))))
    })
    .ok()
    .and_then(Result::ok)
    .unwrap_or(ptr::null_mut())
}

fn json_response(work: impl FnOnce(&mut Option<u64>) -> Result<Reply>) -> *mut c_char {
    let mut id = None;
    catch_unwind(AssertUnwindSafe(|| {
        let result = work(&mut id).and_then(|reply| Ok(CString::new(serde_json::to_vec(&reply)?)?));
        result.unwrap_or_else(|error| error_reply(id, &error.to_string()))
    }))
    .unwrap_or_else(|_| error_reply(id, "lumen core request panicked"))
    .into_raw()
}

fn error_reply(id: Option<u64>, error: &str) -> CString {
    let reply = match id {
        Some(id) => serde_json::json!({"id":id,"error":error}),
        None => serde_json::json!({"error":error}),
    };
    // Serialized JSON escapes NULs, including those in error messages.
    CString::new(reply.to_string()).unwrap()
}

unsafe fn request(
    handle: *mut LumenSessionHandle,
    json: *const c_char,
    op: Operation,
) -> *mut c_char {
    json_response(|id| {
        let q: Request = serde_json::from_str(unsafe { input(json)? })?;
        *id = Some(q.id);
        let session = &mut unsafe { handle.as_mut() }.context("null session handle")?.0;
        ensure!(
            q.op.is_none_or(|value| value == op),
            "request op does not match entry point"
        );
        match op {
            Operation::Search => {
                let query = q.query.context("search requires query")?;
                ensure!(
                    matches!(q.mode, Mode::Name | Mode::Text),
                    "in-process search supports name and text only"
                );
                let limit = q.limit.unwrap_or(20).clamp(1, 100);
                // Match serve's access-checked candidate budget before applying the limit.
                let check_access = q.check_access.unwrap_or(false);
                let fetch = if check_access {
                    (4 * limit).min(100)
                } else {
                    limit
                };
                let mut hits = session.search(&query, q.mode, fetch)?;
                if check_access {
                    verify_cached_access(&mut hits);
                    hits.truncate(limit);
                }
                Ok(Reply::Search { id: q.id, hits })
            }
            Operation::Validate => {
                let hits = q.hits.context("validate requires hits")?;
                let inputs: Vec<_> = hits
                    .iter()
                    .map(|hit| {
                        (
                            hit.path.as_str(),
                            hit.kind.as_str(),
                            hit.availability.as_str(),
                            hit.document_stamp.as_deref(),
                            hit.matched_by.as_deref(),
                        )
                    })
                    .collect();
                Ok(Reply::Validate {
                    id: q.id,
                    valid: session.validate(&inputs),
                })
            }
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_session_search_json(
    handle: *mut LumenSessionHandle,
    json: *const c_char,
) -> *mut c_char {
    unsafe { request(handle, json, Operation::Search) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_session_validate_json(
    handle: *mut LumenSessionHandle,
    json: *const c_char,
) -> *mut c_char {
    unsafe { request(handle, json, Operation::Validate) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_session_close(handle: *mut LumenSessionHandle) {
    if !handle.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(handle) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumen_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::{fs, path::PathBuf};

    fn reply(ptr: *mut c_char) -> Value {
        assert!(!ptr.is_null());
        let bytes = unsafe { CStr::from_ptr(ptr) }.to_bytes().to_vec();
        unsafe { lumen_string_free(ptr) };
        serde_json::from_slice(&bytes).unwrap()
    }

    #[test]
    fn null_and_invalid_inputs_are_rejected() {
        unsafe {
            let null = ptr::null();
            let no_handle = ptr::null_mut();
            let invalid = [0xffu8, 0];
            let invalid = invalid.as_ptr().cast();
            assert!(lumen_session_open(null, null).is_null());
            assert!(lumen_session_open(invalid, null).is_null());
            assert!(lumen_session_open(c"index.sqlite".as_ptr(), invalid).is_null());
            assert!(lumen_session_open(c"".as_ptr(), null).is_null());
            for request in [lumen_session_search_json, lumen_session_validate_json] {
                for json in [null, invalid, c"{broken".as_ptr()] {
                    let response = reply(request(no_handle, json));
                    assert!(response["error"].is_string());
                    assert!(response.get("id").is_none());
                }
                assert_eq!(
                    reply(request(no_handle, c"{\"id\":7}".as_ptr())),
                    json!({"id":7,"error":"null session handle"})
                );
            }
            lumen_session_close(no_handle);
            lumen_string_free(ptr::null_mut());
        }
    }

    #[test]
    fn request_panics_become_owned_error_replies() {
        assert_eq!(
            reply(json_response(|id| {
                *id = Some(9);
                panic!("failure in search core");
            })),
            json!({"id":9,"error":"lumen core request panicked"})
        );
    }

    #[test]
    fn serve_json_contract_across_repeated_sessions() {
        struct Fixture(PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                fs::remove_dir_all(&self.0).unwrap();
            }
        }
        let mut template = *b"/tmp/lumen-ffi-XXXXXX\0";
        let dir = unsafe { libc::mkdtemp(template.as_mut_ptr().cast()) };
        assert!(!dir.is_null());
        let fixture = Fixture(PathBuf::from(
            unsafe { CStr::from_ptr(dir) }.to_str().unwrap(),
        ));
        let root = fixture.0.join("corpus");
        let db = fixture.0.join("index.sqlite");
        let c_db = CString::new(db.to_str().unwrap()).unwrap();
        let c_root = CString::new(root.to_str().unwrap()).unwrap();
        assert!(unsafe { lumen_session_open(c_db.as_ptr(), c_root.as_ptr()) }.is_null());
        fs::create_dir(&root).unwrap();
        for name in ["match-a.txt", "match-b.txt"] {
            fs::write(root.join(name), "the fixture needle").unwrap();
        }
        crate::scan(
            &db,
            &crate::Scope {
                roots: vec![root],
                documents: true,
                ..crate::Scope::default()
            },
        )
        .unwrap();
        let mut serve = SearchSession::open(&db).unwrap();
        let names = serve.search("match", Mode::Name, 20).unwrap();
        let text = serve.search("needle", Mode::Text, 20).unwrap();
        assert_eq!(names.len(), 2);
        assert_eq!(text.len(), 2);
        fs::remove_file(&names[0].path).unwrap();
        let validation =
            CString::new(json!({"id":4,"op":"validate","hits":names}).to_string()).unwrap();
        let name_query = cr#"{"id":1,"query":"match"}"#;
        let text_query = cr#"{"id":2,"query":"needle","mode":"text"}"#;
        let checked = cr#"{"id":3,"query":"match","limit":1,"check_access":true}"#;
        let semantic = cr#"{"id":5,"query":"match","mode":"semantic"}"#;
        let searches = [
            (name_query, json!({"id":1,"hits":names})),
            (text_query, json!({"id":2,"hits":text})),
            (checked, json!({"id":3,"hits":[names[1]]})),
            (
                cr#"{"id":6}"#,
                json!({"id":6,"error":"search requires query"}),
            ),
        ];
        let validations = [
            (validation.as_c_str(), json!({"id":4,"valid":[false,true]})),
            (
                cr#"{"id":7}"#,
                json!({"id":7,"error":"validate requires hits"}),
            ),
        ];
        for root in [ptr::null(), c_root.as_ptr()].into_iter().cycle().take(32) {
            unsafe {
                let handle = lumen_session_open(c_db.as_ptr(), root);
                assert!(!handle.is_null());
                for (request, expected) in &searches {
                    assert_eq!(
                        &reply(lumen_session_search_json(handle, request.as_ptr())),
                        expected
                    );
                }
                for (request, expected) in &validations {
                    assert_eq!(
                        &reply(lumen_session_validate_json(handle, request.as_ptr())),
                        expected
                    );
                }
                assert!(
                    reply(lumen_session_search_json(handle, semantic.as_ptr()))["error"]
                        .is_string()
                );
                lumen_session_close(handle);
            }
        }
    }
}
