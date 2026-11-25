use anyhow::{Context, Result, bail};
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;

pub fn availability(path: &Path, meta: &fs::Metadata) -> &'static str {
    classify(path, dataless(meta))
}

pub fn classify(path: &Path, dataless: bool) -> &'static str {
    if dataless {
        "placeholder"
    } else if provider(path) {
        "provider_metadata_only"
    } else {
        "local"
    }
}

fn provider(path: &Path) -> bool {
    let mut prior_library = false;
    for part in path.components() {
        let value = part.as_os_str().to_string_lossy().to_ascii_lowercase();
        if prior_library && matches!(value.as_str(), "cloudstorage" | "mobile documents") {
            return true;
        }
        prior_library = value == "library";
        if matches!(
            value.as_str(),
            "onedrive" | "dropbox" | "google drive" | "icloud drive" | "box sync"
        ) || value.starts_with("onedrive - ")
            || value.starts_with("onedrive-")
        {
            return true;
        }
    }
    false
}

#[cfg(target_os = "macos")]
fn dataless(meta: &fs::Metadata) -> bool {
    use std::os::macos::fs::MetadataExt;
    meta.st_flags() & 0x4000_0000 != 0 // SF_DATALESS, Darwin <sys/stat.h>.
}
#[cfg(not(target_os = "macos"))]
fn dataless(_: &fs::Metadata) -> bool {
    false
}

#[cfg(target_os = "macos")]
pub struct NoMaterialization(i32);
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn setiopolicy_np(kind: i32, scope: i32, policy: i32) -> i32;
    fn getiopolicy_np(kind: i32, scope: i32) -> i32;
}
#[cfg(target_os = "macos")]
impl NoMaterialization {
    pub fn enter() -> Result<Self> {
        // Darwin <sys/resource.h>: materialization policy, current thread, OFF.
        let old = unsafe { getiopolicy_np(3, 1) };
        if old < 0 || unsafe { setiopolicy_np(3, 1, 1) } != 0 {
            return Err(std::io::Error::last_os_error()).context("disable APFS materialization");
        }
        Ok(Self(old))
    }
}
#[cfg(target_os = "macos")]
impl Drop for NoMaterialization {
    fn drop(&mut self) {
        // Destructor only restores the policy for the thread that entered it.
        if unsafe { setiopolicy_np(3, 1, self.0) } != 0 {
            eprintln!("lumen: could not restore thread I/O policy");
        }
    }
}

/// Accept regular files only, no symlink of any component on macOS. Provider paths
/// remain metadata-only even if a race changes flags after preflight.
pub fn read_local(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let preflight = fs::symlink_metadata(path)?;
    if !preflight.is_file() || preflight.len() > limit || availability(path, &preflight) != "local"
    {
        bail!("not a small local regular file");
    }
    #[cfg(target_os = "macos")]
    let _io = NoMaterialization::enter()?;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    #[cfg(target_os = "macos")]
    let flags = libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK;
    #[cfg(not(target_os = "macos"))]
    let flags = libc::O_NOFOLLOW | libc::O_NONBLOCK;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(flags)
        .open(path)?;
    let opened = file.metadata()?;
    if !opened.is_file()
        || opened.dev() != preflight.dev()
        || opened.ino() != preflight.ino()
        || opened.len() > limit
        || availability(path, &opened) != "local"
    {
        bail!("file changed or is not local");
    }
    let mut data = Vec::new();
    File::take(file, limit + 1).read_to_end(&mut data)?;
    if data.len() as u64 > limit {
        bail!("file exceeded size limit");
    }
    Ok(data)
}

#[cfg(target_os = "macos")]
pub fn pinyin(name: &str) -> (String, String) {
    use std::ffi::c_void;
    type Cf = *const c_void;
    type CfMut = *mut c_void;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            allocator: Cf,
            bytes: *const u8,
            n: isize,
            encoding: u32,
            is_external: u8,
        ) -> Cf;
        fn CFStringCreateMutableCopy(allocator: Cf, capacity: isize, text: Cf) -> CfMut;
        fn CFStringTransform(text: CfMut, range: *mut c_void, transform: Cf, reverse: u8) -> u8;
        fn CFStringGetCString(text: Cf, buffer: *mut u8, size: isize, encoding: u32) -> u8;
        fn CFRelease(object: Cf);
        static kCFStringTransformMandarinLatin: Cf;
        static kCFStringTransformStripDiacritics: Cf;
    }
    if !name
        .chars()
        .any(|c| matches!(c, '\u{3400}'..='\u{9fff}' | '\u{20000}'..='\u{2ffff}'))
    {
        return Default::default();
    }
    let null = std::ptr::null();
    let raw = unsafe {
        CFStringCreateWithBytes(null, name.as_ptr(), name.len() as isize, 0x0800_0100, 0)
    };
    if raw.is_null() {
        return Default::default();
    }
    let mutable = unsafe { CFStringCreateMutableCopy(null, 0, raw) };
    unsafe { CFRelease(raw) };
    if mutable.is_null() {
        return Default::default();
    }
    let mut data = vec![0u8; name.len() * 8 + 16];
    let ok = unsafe {
        let range = std::ptr::null_mut();
        let ok = CFStringTransform(mutable, range, kCFStringTransformMandarinLatin, 0) != 0
            && CFStringTransform(mutable, range, kCFStringTransformStripDiacritics, 0) != 0
            && CFStringGetCString(mutable, data.as_mut_ptr(), data.len() as isize, 0x0800_0100)
                != 0;
        CFRelease(mutable);
        ok
    };
    if !ok {
        return Default::default();
    }
    let latin =
        String::from_utf8_lossy(&data[..data.iter().position(|&b| b == 0).unwrap_or(data.len())]);
    let words: Vec<_> = latin
        .split(|ch: char| !ch.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect();
    let full = words.join("").to_ascii_lowercase();
    let initials = words
        .iter()
        .filter_map(|w| w.chars().next())
        .collect::<String>()
        .to_ascii_lowercase();
    (full, initials)
}
#[cfg(not(target_os = "macos"))]
pub fn pinyin(_: &str) -> (String, String) {
    Default::default()
}

#[derive(Debug)]
pub struct FastInfo {
    pub directory: bool,
    pub dataless: bool,
}
type Children = Vec<(std::ffi::OsString, Option<FastInfo>)>;

/// Darwin batch metadata enumeration. If the filesystem or any record layout
/// is not compatible, discard the incomplete batch and use normal enumeration.
#[cfg(target_os = "macos")]
pub fn bulk_children(path: &Path) -> Option<Children> {
    use std::ffi::OsString;
    use std::os::{
        fd::AsRawFd,
        unix::{ffi::OsStringExt, fs::OpenOptionsExt},
    };
    #[repr(C)]
    struct AttrList {
        bitmapcount: u16,
        reserved: u16,
        common: u32,
        vol: u32,
        dir: u32,
        file: u32,
        fork: u32,
    }
    const NAME: u32 = 0x0000_0001;
    const KIND: u32 = 0x0000_0008;
    const FLAGS: u32 = 0x0004_0000;
    const ERROR: u32 = 0x2000_0000;
    const RETURNED: u32 = 0x8000_0000;
    const DATALESS: u32 = 0x4000_0000;
    let mut a = AttrList {
        bitmapcount: 5,
        reserved: 0,
        common: RETURNED | NAME | KIND | FLAGS | ERROR,
        vol: 0,
        dir: 0,
        file: 0,
        fork: 0,
    };
    let fd = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY)
        .open(path)
        .ok()?;
    let mut buf = vec![0u64; 8192];
    let mut children = Vec::new();
    let u32at = |data: &[u8], offset: usize| {
        Some(u32::from_ne_bytes(
            data.get(offset..offset + 4)?.try_into().ok()?,
        ))
    };
    loop {
        let found = unsafe {
            libc::getattrlistbulk(
                fd.as_raw_fd(),
                (&mut a as *mut AttrList).cast(),
                buf.as_mut_ptr().cast(),
                buf.len() * 8,
                0,
            )
        };
        if found < 0 {
            return None;
        }
        if found == 0 {
            return Some(children);
        }
        let bytes = unsafe { std::slice::from_raw_parts(buf.as_ptr().cast::<u8>(), buf.len() * 8) };
        let mut base = 0usize;
        for _ in 0..found {
            let len = u32at(bytes, base)? as usize;
            if len < 24 {
                return None;
            }
            let r = bytes.get(base..base + len)?;
            base += len;
            let fields = u32at(r, 4)?;
            if fields & ERROR != 0 && u32at(r, 24)? != 0 {
                return None;
            }
            if fields & NAME == 0 {
                return None;
            }
            let i = 24 + if fields & ERROR != 0 { 4 } else { 0 };
            let relative = u32at(r, i)? as i32;
            let start = i.checked_add_signed(relative as isize)?;
            let size = u32at(r, i + 4)? as usize;
            let name = r.get(start..start.checked_add(size)?)?.strip_suffix(&[0])?;
            if name.is_empty()
                || name == b"."
                || name == b".."
                || name.contains(&0)
                || name.contains(&b'/')
            {
                return None;
            }
            let info = if fields & (KIND | FLAGS) == (KIND | FLAGS) {
                let kind = u32at(r, i + 8)?;
                if !matches!(kind, 1 | 2) {
                    continue;
                }
                Some(FastInfo {
                    directory: kind == 2,
                    dataless: u32at(r, i + 12)? & DATALESS != 0,
                })
            } else {
                None
            };
            children.push((OsString::from_vec(name.to_vec()), info));
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn bulk_children(_: &Path) -> Option<Children> {
    None
}
