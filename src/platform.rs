use anyhow::{Context, Result, bail};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

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

fn is_provider_folder_name(value: &[u8]) -> bool {
    let equals = |name: &[u8]| value.eq_ignore_ascii_case(name);
    let starts = |prefix: &[u8]| {
        value
            .get(..prefix.len())
            .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
    };
    equals(b"onedrive")
        || equals(b"dropbox")
        || equals(b"google drive")
        || equals(b"icloud drive")
        || equals(b"box sync")
        || starts(b"onedrive - ")
        || starts(b"onedrive-")
}

fn direct_home_provider(path: &Path) -> bool {
    use std::path::{Component, PathBuf};
    static HOME: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();
    let home = HOME.get_or_init(|| crate::absolute(Path::new(&std::env::var_os("HOME")?)).ok());
    if let Some(home) = home
        && let Ok(tail) = path.strip_prefix(home)
        && let Some(Component::Normal(first)) = tail.components().next()
        && is_provider_folder_name(first.as_encoded_bytes())
    {
        return true;
    }
    let normalized = path.strip_prefix("/System/Volumes/Data").unwrap_or(path);
    let mut parts = match normalized.strip_prefix("/Users") {
        Ok(rest) => rest.components(),
        Err(_) => match normalized.strip_prefix("Users") {
            Ok(rest) => rest.components(),
            Err(_) => return false,
        },
    };
    if !matches!(parts.next(), Some(Component::Normal(_))) {
        return false;
    }
    matches!(
        parts.next(),
        Some(Component::Normal(first)) if is_provider_folder_name(first.as_encoded_bytes())
    )
}

fn provider(path: &Path) -> bool {
    let mut prior_library = false;
    for part in path.components() {
        let value = part.as_os_str().as_encoded_bytes();
        let equals = |name: &[u8]| value.eq_ignore_ascii_case(name);
        if prior_library && (equals(b"cloudstorage") || equals(b"mobile documents")) {
            return true;
        }
        prior_library = equals(b"library");
    }
    direct_home_provider(path)
}

#[cfg(target_os = "macos")]
fn dataless(meta: &fs::Metadata) -> bool {
    use std::os::macos::fs::MetadataExt;
    dataless_flags(meta.st_flags())
}
#[cfg(target_os = "macos")]
pub(super) fn dataless_flags(flags: u32) -> bool {
    flags & 0x4000_0000 != 0 // SF_DATALESS, Darwin <sys/stat.h>.
}
#[cfg(not(target_os = "macos"))]
fn dataless(_: &fs::Metadata) -> bool {
    false
}

const DEFAULT_PHYSICAL_MEMORY_BYTES: u64 = 16 * 1024 * 1024 * 1024;

#[cfg(target_os = "macos")]
pub(crate) fn physical_memory_bytes() -> u64 {
    let mut memsize: u64 = 0;
    let mut size = std::mem::size_of::<u64>();
    let ok = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&raw mut memsize).cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if ok == 0 && size == std::mem::size_of::<u64>() && memsize > 0 {
        memsize
    } else {
        DEFAULT_PHYSICAL_MEMORY_BYTES
    }
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn physical_memory_bytes() -> u64 {
    DEFAULT_PHYSICAL_MEMORY_BYTES
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum ThermalPressure {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[cfg(target_os = "macos")]
pub(crate) fn thermal_pressure() -> ThermalPressure {
    use std::ffi::c_char;
    unsafe extern "C" {
        fn notify_register_check(name: *const c_char, out_token: *mut i32) -> u32;
        fn notify_get_state(token: i32, state64: *mut u64) -> u32;
        fn notify_cancel(token: i32) -> u32;
    }
    let mut token = 0_i32;
    let mut level = 0_u64;
    let reg = unsafe {
        notify_register_check(
            c"com.apple.system.thermalpressurelevel".as_ptr(),
            &raw mut token,
        )
    };
    if reg != 0 {
        return ThermalPressure::Nominal;
    }
    let status = unsafe { notify_get_state(token, &raw mut level) };
    unsafe {
        notify_cancel(token);
    }
    if status != 0 {
        return ThermalPressure::Nominal;
    }
    match level {
        0 => ThermalPressure::Nominal,
        1 => ThermalPressure::Fair,
        2 => ThermalPressure::Serious,
        _ => ThermalPressure::Critical,
    }
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn thermal_pressure() -> ThermalPressure {
    ThermalPressure::Nominal
}

#[cfg(target_os = "macos")]
pub(crate) fn on_battery_power() -> bool {
    use std::ffi::c_void;
    type Cf = *const c_void;
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> Cf;
        fn IOPSGetProvidingPowerSourceType(snapshot: Cf) -> Cf;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringGetCString(
            the_string: Cf,
            buffer: *mut u8,
            buffer_size: isize,
            encoding: u32,
        ) -> u8;
        fn CFRelease(cf: Cf);
    }
    let info = unsafe { IOPSCopyPowerSourcesInfo() };
    if info.is_null() {
        return false;
    }
    let ptype = unsafe { IOPSGetProvidingPowerSourceType(info) };
    let mut buf = [0_u8; 64];
    let ok = !ptype.is_null()
        && unsafe {
            CFStringGetCString(ptype, buf.as_mut_ptr(), buf.len() as isize, 0x0800_0100) != 0
        };
    // `ptype` is borrowed from `info`; only release `info`.
    unsafe { CFRelease(info) };
    if !ok {
        return false;
    }
    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    &buf[..len] == b"Battery Power"
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn on_battery_power() -> bool {
    false
}

const PACE_SLICE: Duration = Duration::from_millis(50);
const PACE_SERIOUS_POLL: Duration = Duration::from_secs(1);
const PACE_SERIOUS_CAP: Duration = Duration::from_secs(30);
const PACE_RECOVERY_MIN_REST: Duration = Duration::from_millis(500);

pub(crate) fn stream_rest_duration(
    work: Duration,
    thermal: ThermalPressure,
    on_battery: bool,
) -> Duration {
    if thermal >= ThermalPressure::Serious {
        return Duration::from_secs(1);
    }
    if work < Duration::from_millis(50) {
        return Duration::ZERO;
    }
    let bounded = work.min(Duration::from_secs(60));
    match (thermal, on_battery) {
        (ThermalPressure::Nominal, false) => bounded
            .mul_f64(2.0)
            .clamp(Duration::from_millis(200), Duration::from_secs(5)),
        (ThermalPressure::Fair, false) | (ThermalPressure::Nominal, true) => bounded
            .mul_f64(3.5)
            .clamp(Duration::from_millis(300), Duration::from_secs(8)),
        (ThermalPressure::Fair, true) => bounded
            .mul_f64(7.0)
            .clamp(Duration::from_millis(500), Duration::from_secs(12)),
        (ThermalPressure::Serious | ThermalPressure::Critical, _) => Duration::from_secs(1),
    }
}

pub(crate) fn pace_stream_batch_with(
    work: Duration,
    stop: &AtomicBool,
    sample: impl Fn() -> (ThermalPressure, bool),
    mut sleep_step: impl FnMut(Duration),
) {
    let mut sleep_sliced = |mut remaining: Duration| -> Duration {
        let mut slept = Duration::ZERO;
        while !remaining.is_zero() && !stop.load(Ordering::Acquire) {
            let step = remaining.min(PACE_SLICE);
            sleep_step(step);
            remaining = remaining.saturating_sub(step);
            slept += step;
        }
        slept
    };

    let mut cooled = Duration::ZERO;
    while !stop.load(Ordering::Acquire) {
        let (thermal, on_battery) = sample();
        if thermal >= ThermalPressure::Serious {
            let remaining_cap = PACE_SERIOUS_CAP.saturating_sub(cooled);
            if remaining_cap.is_zero() {
                break;
            }
            cooled += sleep_sliced(PACE_SERIOUS_POLL.min(remaining_cap));
            if cooled >= PACE_SERIOUS_CAP {
                break;
            }
            continue;
        }
        let rest = stream_rest_duration(work, thermal, on_battery);
        if !cooled.is_zero() {
            let target = rest.max(PACE_RECOVERY_MIN_REST);
            sleep_sliced(target.saturating_sub(cooled));
        } else {
            sleep_sliced(rest);
        }
        break;
    }
}

pub(crate) fn pace_stream_batch(work: Duration, stop: &AtomicBool) {
    if work < Duration::from_millis(50) {
        return;
    }
    pace_stream_batch_with(
        work,
        stop,
        || (thermal_pressure(), on_battery_power()),
        std::thread::sleep,
    );
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

fn is_resident(path: &Path, meta: &fs::Metadata) -> bool {
    !dataless(meta) && matches!(availability(path, meta), "local" | "provider_metadata_only")
}

/// Open handle to a verified resident regular file (local or hydrated cloud
/// file with `SF_DATALESS == 0`), keeping thread-level `NoMaterialization`
/// active until the file descriptor is closed.
pub(crate) struct CheckedLocalFile {
    file: File,
    path: PathBuf,
    limit: u64,
    dev: u64,
    ino: u64,
    expected_stamp: String,
    #[cfg(target_os = "macos")]
    _io: NoMaterialization,
}

impl CheckedLocalFile {
    /// Re-verify via `fstat` that the open file remained a resident regular
    /// file within `limit` and with an unchanged metadata stamp.
    pub(crate) fn verify_unchanged(&self) -> Result<()> {
        use std::os::unix::fs::MetadataExt;
        let after = self.file.metadata()?;
        if !after.is_file()
            || after.dev() != self.dev
            || after.ino() != self.ino
            || after.len() > self.limit
            || !is_resident(&self.path, &after)
            || !crate::index::stamp_matches(&self.expected_stamp, &crate::index::stamp(&after))
        {
            bail!("file changed while reading");
        }
        Ok(())
    }
}

impl Read for CheckedLocalFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.file.read(buf)
    }
}

impl Seek for CheckedLocalFile {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.file.seek(pos)
    }
}

/// Open a resident regular file (local or hydrated cloud file with
/// `SF_DATALESS == 0`) without following symlinks on any path component and
/// without materializing cloud placeholders.
pub(crate) fn open_local_checked(
    path: &Path,
    limit: u64,
    stamp: Option<&str>,
) -> Result<CheckedLocalFile> {
    #[cfg(target_os = "macos")]
    let io = NoMaterialization::enter()?;
    let preflight = fs::symlink_metadata(path)?;
    if !preflight.is_file() || preflight.len() > limit || !is_resident(path, &preflight) {
        bail!("not a small resident regular file");
    }
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
        || !is_resident(path, &opened)
    {
        bail!("file changed or is not resident");
    }
    let opened_stamp = crate::index::stamp(&opened);
    if stamp.is_some_and(|expected| !crate::index::stamp_matches(expected, &opened_stamp)) {
        bail!("file changed before reading");
    }
    Ok(CheckedLocalFile {
        file,
        path: path.to_path_buf(),
        limit,
        dev: opened.dev(),
        ino: opened.ino(),
        expected_stamp: opened_stamp,
        #[cfg(target_os = "macos")]
        _io: io,
    })
}

/// Accept resident regular files only (local or hydrated cloud files with
/// `SF_DATALESS == 0`), no symlink of any component on macOS. Placeholders
/// remain unreadable even if a race changes flags after preflight.
#[allow(dead_code)]
pub fn read_local(path: &Path, limit: u64) -> Result<Vec<u8>> {
    read_local_checked(path, limit, None)
}

pub(crate) fn read_local_checked(path: &Path, limit: u64, stamp: Option<&str>) -> Result<Vec<u8>> {
    let mut file = open_local_checked(path, limit, stamp)?;
    let mut data = Vec::new();
    Read::take(&mut file, limit + 1).read_to_end(&mut data)?;
    if data.len() as u64 > limit {
        bail!("file exceeded size limit");
    }
    file.verify_unchanged()?;
    Ok(data)
}

/// Decode a Windows codepage byte slice (e.g. 936 GBK, 950 Big5, 932 Shift-JIS,
/// 1252 Windows-1252) to UTF-8 via CoreFoundation on macOS.
#[cfg(target_os = "macos")]
pub(crate) fn decode_codepage(codepage: u32, bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() {
        return Some(String::new());
    }
    use std::ffi::c_void;
    type Cf = *const c_void;
    const K_CF_STRING_ENCODING_INVALID_ID: u32 = 0xffff_ffff;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringConvertWindowsCodepageToEncoding(codepage: u32) -> u32;
        fn CFStringCreateWithBytes(
            allocator: Cf,
            bytes: *const u8,
            num_bytes: isize,
            encoding: u32,
            is_external: u8,
        ) -> Cf;
        fn CFStringGetLength(text: Cf) -> isize;
        fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) -> isize;
        fn CFStringGetCString(text: Cf, buffer: *mut u8, size: isize, encoding: u32) -> u8;
        fn CFRelease(object: Cf);
    }
    let encoding = unsafe { CFStringConvertWindowsCodepageToEncoding(codepage) };
    if encoding == K_CF_STRING_ENCODING_INVALID_ID {
        return None;
    }
    let len = isize::try_from(bytes.len()).ok()?;
    let cf = unsafe { CFStringCreateWithBytes(std::ptr::null(), bytes.as_ptr(), len, encoding, 0) };
    if cf.is_null() {
        return None;
    }
    let max_size = unsafe {
        let cf_len = CFStringGetLength(cf);
        CFStringGetMaximumSizeForEncoding(cf_len, K_CF_STRING_ENCODING_UTF8)
    };
    if max_size < 0 {
        unsafe { CFRelease(cf) };
        return None;
    }
    let cap = (max_size as usize).checked_add(1)?;
    let mut buf = vec![0u8; cap];
    let ok = unsafe {
        let ok = CFStringGetCString(
            cf,
            buf.as_mut_ptr(),
            buf.len() as isize,
            K_CF_STRING_ENCODING_UTF8,
        ) != 0;
        CFRelease(cf);
        ok
    };
    if !ok {
        return None;
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    buf.truncate(end);
    String::from_utf8(buf).ok()
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn decode_codepage(codepage: u32, bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() {
        return Some(String::new());
    }
    match codepage {
        65001 => std::str::from_utf8(bytes).ok().map(str::to_owned),
        1252 => Some(
            bytes
                .iter()
                .map(|&b| crate::legacy_office::cp1252_byte(b))
                .collect(),
        ),
        _ => None,
    }
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
    let name = crate::pinyin::contextual_input(name);
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
    pub mtime: i64,
}
type Children = Vec<(std::ffi::OsString, Option<FastInfo>)>;

/// Darwin batch metadata enumeration. If the filesystem or any record layout
/// is not compatible, discard the incomplete batch and use normal enumeration.
#[cfg(target_os = "macos")]
pub fn bulk_children(path: &Path, scratch: &mut Vec<u64>) -> Option<Children> {
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
    const MODTIME: u32 = 0x0000_0400;
    const FLAGS: u32 = 0x0004_0000;
    const ERROR: u32 = 0x2000_0000;
    const RETURNED: u32 = 0x8000_0000;
    const DATALESS: u32 = 0x4000_0000;
    let mut a = AttrList {
        bitmapcount: 5,
        reserved: 0,
        common: RETURNED | NAME | KIND | MODTIME | FLAGS | ERROR,
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
    scratch.resize(8192, 0);
    let buf = scratch;
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
            let info = if fields & (KIND | MODTIME | FLAGS) == (KIND | MODTIME | FLAGS) {
                let kind = u32at(r, i + 8)?;
                if kind == 5 {
                    // Emit VSYMLINK (VLNK) with None so Walk::visit handles 1-level symlinks.
                    None
                } else if matches!(kind, 1 | 2) {
                    Some(FastInfo {
                        directory: kind == 2,
                        // Darwin packs attributes on 4-byte boundaries; MODTIME
                        // is a timespec between the object type and flags.
                        mtime: i64::from_ne_bytes(r.get(i + 12..i + 20)?.try_into().ok()?),
                        dataless: u32at(r, i + 28)? & DATALESS != 0,
                    })
                } else {
                    continue;
                }
            } else {
                None
            };
            children.push((OsString::from_vec(name.to_vec()), info));
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn bulk_children(_: &Path, _: &mut Vec<u64>) -> Option<Children> {
    None
}

/// The fallback also opens by descriptor to retain the bulk path's nofollow
/// policy if a directory is swapped for a symlink between metadata and listing.
#[cfg(target_os = "macos")]
pub fn children_on_device(
    path: &Path,
    device: Option<u64>,
) -> std::io::Result<Vec<std::ffi::OsString>> {
    use std::{
        ffi::OsString,
        io,
        os::{
            fd::IntoRawFd,
            unix::{ffi::OsStringExt, fs::OpenOptionsExt},
        },
    };
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY)
        .open(path)?;
    if let Some(device) = device {
        use std::os::unix::fs::MetadataExt;
        if directory.metadata()?.dev() != device {
            return Err(io::Error::from(io::ErrorKind::PermissionDenied));
        }
    }
    let fd = directory.into_raw_fd();
    let directory = unsafe { libc::fdopendir(fd) };
    if directory.is_null() {
        let error = io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(error);
    }
    let mut children = Vec::new();
    let result = loop {
        // readdir distinguishes EOF and failure through errno.
        let entry = unsafe {
            *libc::__error() = 0;
            libc::readdir(directory)
        };
        if entry.is_null() {
            let errno = unsafe { *libc::__error() };
            break if errno == 0 {
                Ok(children)
            } else {
                Err(io::Error::from_raw_os_error(errno))
            };
        }
        let entry = unsafe { &*entry };
        let name = unsafe {
            std::slice::from_raw_parts(entry.d_name.as_ptr().cast(), entry.d_namlen.into())
        };
        if name != b"." && name != b".." {
            children.push(OsString::from_vec(name.to_vec()));
        }
    };
    unsafe { libc::closedir(directory) };
    result
}

#[cfg(not(target_os = "macos"))]
pub fn children_on_device(path: &Path, _: Option<u64>) -> std::io::Result<Vec<std::ffi::OsString>> {
    fs::read_dir(path)?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect()
}

#[cfg(target_os = "macos")]
pub(super) fn descriptor_path(fd: &File) -> Option<std::path::PathBuf> {
    use std::{
        ffi::{CStr, OsStr},
        os::{fd::AsRawFd, unix::ffi::OsStrExt},
    };
    let mut bytes = [0u8; libc::PATH_MAX as usize];
    if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETPATH, bytes.as_mut_ptr()) } != 0 {
        return None;
    }
    let result = CStr::from_bytes_until_nul(&bytes).ok()?;
    let path = Path::new(OsStr::from_bytes(result.to_bytes()));
    path.is_absolute().then(|| {
        path.strip_prefix("/System/Volumes/Data")
            .map_or_else(|_| path.to_path_buf(), |rest| Path::new("/").join(rest))
    })
}

/// APFS can resolve a path whose spelling differs from the spelling FSEvents
/// delivers. Resolve only through the nearest real, reachable prefix.
#[cfg(target_os = "macos")]
pub fn filesystem_spelling(path: &Path) -> std::path::PathBuf {
    use std::os::unix::fs::OpenOptionsExt;
    for prefix in path.ancestors() {
        let Ok(fd) = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_EVTONLY | libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK)
            .open(prefix)
        else {
            continue;
        };
        if let Some(canonical) = descriptor_path(&fd) {
            let suffix = path.strip_prefix(prefix).expect("ancestor prefix");
            return if suffix.as_os_str().is_empty() {
                canonical
            } else {
                canonical.join(suffix)
            };
        }
    }
    path.to_path_buf()
}

#[cfg(not(target_os = "macos"))]
pub fn filesystem_spelling(path: &Path) -> std::path::PathBuf {
    path.to_path_buf()
}

/// Be conservative about denies on macOS, including a future case or Unicode
/// alias of a deny path that does not exist when the scope is configured.
pub fn denied_by(path: &Path, rule: &Path) -> bool {
    if path.starts_with(rule) {
        return true;
    }
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        let mut actual = path.components();
        rule.components().all(|prefix| {
            actual.next().is_some_and(|part| {
                let a = part.as_os_str().as_bytes();
                let b = prefix.as_os_str().as_bytes();
                a.eq_ignore_ascii_case(b) || (!a.is_ascii() || !b.is_ascii()) && equal_folded(a, b)
            })
        })
    }
    #[cfg(not(target_os = "macos"))]
    false
}

#[cfg(target_os = "macos")]
fn equal_folded(a: &[u8], b: &[u8]) -> bool {
    use std::{ffi::c_void, ptr::null};
    type Cf = *const c_void;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            alloc: Cf,
            bytes: *const u8,
            count: isize,
            encoding: u32,
            external: u8,
        ) -> Cf;
        fn CFStringCompare(left: Cf, right: Cf, flags: usize) -> isize;
        fn CFRelease(object: Cf);
    }
    let cf = |bytes: &[u8]| unsafe {
        CFStringCreateWithBytes(null(), bytes.as_ptr(), bytes.len() as isize, 0x0800_0100, 0)
    };
    let (a, b) = (cf(a), cf(b));
    let same = !a.is_null() && !b.is_null() && unsafe { CFStringCompare(a, b, 1 | 16) } == 0; // case insensitive + nonliteral
    for pointer in [a, b] {
        if !pointer.is_null() {
            unsafe { CFRelease(pointer) };
        }
    }
    same
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn bulk_enumeration_reuses_scratch_between_directories() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-bulk-scratch-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let first = root.join("first");
        let second = root.join("second");
        fs::create_dir_all(&first).unwrap();
        fs::create_dir(&second).unwrap();
        fs::write(first.join("one.txt"), "one").unwrap();
        fs::write(second.join("two.txt"), "two").unwrap();
        let mut scratch = Vec::new();
        let entries = bulk_children(&first, &mut scratch).expect("APFS batch enumeration");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "one.txt");
        assert!(!entries[0].1.as_ref().unwrap().directory);
        let allocation = scratch.as_ptr();
        let entries = bulk_children(&second, &mut scratch).expect("APFS batch enumeration");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "two.txt");
        assert_eq!(scratch.as_ptr(), allocation);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn provider_narrows_to_cloud_roots_and_direct_home_folders() {
        for local in [
            "/Users/alice/Projects/dropbox/readme.md",
            "/Users/alice/Documents/OneDrive/plan.md",
            "/Users/alice/Documents/Google Drive/export.pdf",
            "/Users/alice/Desktop/Box Sync/notes.txt",
            "/private/tmp/OneDrive-Fixture/image.heic",
        ] {
            assert_eq!(classify(Path::new(local), false), "local", "{local}");
        }
        for cloud in [
            "/Users/alice/Library/CloudStorage/OneDrive-Personal/doc.md",
            "/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/doc.md",
            "/Users/alice/OneDrive/doc.md",
            "/Users/alice/OneDrive - Contoso/doc.md",
            "/Users/alice/OneDrive-Work/doc.md",
            "/Users/alice/Dropbox/doc.md",
            "/Users/alice/Google Drive/doc.md",
            "/Users/alice/iCloud Drive/doc.md",
            "/Users/alice/Box Sync/doc.md",
        ] {
            assert_eq!(
                classify(Path::new(cloud), false),
                "provider_metadata_only",
                "{cloud}"
            );
            assert_eq!(classify(Path::new(cloud), true), "placeholder", "{cloud}");
        }
    }

    #[test]
    fn read_local_checked_reads_resident_cloud_and_ignores_ctime() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-read-cloud-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let cloud_dir = root.join("Library/CloudStorage/OneDrive-Test");
        fs::create_dir_all(&cloud_dir).unwrap();
        let file = cloud_dir.join("resident.txt");
        fs::write(&file, b"resident cloud payload").unwrap();
        let meta = fs::symlink_metadata(&file).unwrap();
        assert_eq!(availability(&file, &meta), "provider_metadata_only");
        let five_field = crate::index::stamp(&meta);
        assert_eq!(five_field.split(':').count(), 5);
        let legacy_seven_field = format!("{five_field}:999999:123456");
        assert_eq!(
            read_local_checked(&file, 1024, Some(&five_field)).unwrap(),
            b"resident cloud payload"
        );
        assert_eq!(
            read_local_checked(&file, 1024, Some(&legacy_seven_field)).unwrap(),
            b"resident cloud payload"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bulk_enumeration_emits_symlinks_instead_of_dropping_them() {
        use std::os::unix::fs::symlink;
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-bulk-symlink-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let target = root.join("real.txt");
        fs::write(&target, "real").unwrap();
        symlink(&target, root.join("link.txt")).unwrap();
        let mut scratch = Vec::new();
        let entries = bulk_children(&root, &mut scratch).expect("APFS batch enumeration");
        let link = entries
            .iter()
            .find(|(name, _)| name == "link.txt")
            .expect("bulk_children must emit VSYMLINK entries");
        assert!(link.1.is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn physical_memory_bytes_reports_at_least_one_gib() {
        assert!(physical_memory_bytes() >= 1024 * 1024 * 1024);
    }

    #[test]
    fn stream_rest_duration_covers_all_thermal_and_battery_states() {
        use ThermalPressure::{Critical, Fair, Nominal, Serious};
        let ms = Duration::from_millis;
        let secs = Duration::from_secs;

        // Fast batches stay zero-wait below Serious so stub/unit tests never stall.
        for (thermal, battery) in [
            (Nominal, false),
            (Nominal, true),
            (Fair, false),
            (Fair, true),
        ] {
            assert_eq!(
                stream_rest_duration(ms(0), thermal, battery),
                Duration::ZERO
            );
            assert_eq!(
                stream_rest_duration(ms(49), thermal, battery),
                Duration::ZERO
            );
        }
        for (thermal, battery) in [
            (Serious, false),
            (Serious, true),
            (Critical, false),
            (Critical, true),
        ] {
            assert_eq!(stream_rest_duration(ms(10), thermal, battery), secs(1));
            assert_eq!(stream_rest_duration(secs(2), thermal, battery), secs(1));
        }

        // Nominal on AC: 2.0x clamped to [200ms, 5s] (~33% GPU duty cycle).
        assert_eq!(stream_rest_duration(ms(50), Nominal, false), ms(200));
        assert_eq!(stream_rest_duration(ms(1000), Nominal, false), secs(2));
        assert_eq!(stream_rest_duration(secs(5), Nominal, false), secs(5));

        // Fair on AC or Nominal on battery: 3.5x clamped to [300ms, 8s].
        for (thermal, battery) in [(Fair, false), (Nominal, true)] {
            assert_eq!(stream_rest_duration(ms(50), thermal, battery), ms(300));
            assert_eq!(stream_rest_duration(ms(1000), thermal, battery), ms(3500));
            assert_eq!(stream_rest_duration(secs(3), thermal, battery), secs(8));
        }

        // Fair on battery: 7.0x clamped to [500ms, 12s].
        assert_eq!(stream_rest_duration(ms(50), Fair, true), ms(500));
        assert_eq!(stream_rest_duration(ms(1000), Fair, true), secs(7));
        assert_eq!(stream_rest_duration(secs(2), Fair, true), secs(12));
    }

    #[test]
    fn pace_stream_batch_with_wakes_immediately_on_stop_and_recovers_from_serious() {
        use ThermalPressure::{Critical, Fair, Nominal, Serious};
        use std::cell::Cell;
        let ms = Duration::from_millis;
        let secs = Duration::from_secs;

        // Pre-set stop exits before sampling or sleeping.
        let preset_stop = AtomicBool::new(true);
        let sampled = Cell::new(0usize);
        let mut sleeps = Vec::new();
        pace_stream_batch_with(
            secs(1),
            &preset_stop,
            || {
                sampled.set(sampled.get() + 1);
                (Nominal, false)
            },
            |d| sleeps.push(d),
        );
        assert_eq!(sampled.get(), 0);
        assert!(sleeps.is_empty());

        // Immediate wakeup on stop during normal rest (2s -> stops after 3x50ms = 150ms).
        let stop = AtomicBool::new(false);
        let mut normal_sleeps = Vec::new();
        pace_stream_batch_with(
            secs(1),
            &stop,
            || (Nominal, false),
            |d| {
                normal_sleeps.push(d);
                if normal_sleeps.len() == 3 {
                    stop.store(true, Ordering::Release);
                }
            },
        );
        assert_eq!(normal_sleeps, vec![ms(50), ms(50), ms(50)]);

        // Immediate wakeup on stop during Serious thermal wait.
        let hot_stop = AtomicBool::new(false);
        let mut hot_sleeps = Vec::new();
        pace_stream_batch_with(
            ms(200),
            &hot_stop,
            || (Serious, false),
            |d| {
                hot_sleeps.push(d);
                if hot_sleeps.len() == 4 {
                    hot_stop.store(true, Ordering::Release);
                }
            },
        );
        assert_eq!(hot_sleeps, vec![ms(50); 4]);

        // Serious -> Nominal recovery cools in 1s chunks then breaks once below Serious (>=500ms).
        let stop = AtomicBool::new(false);
        let calls = Cell::new(0usize);
        let mut recovery_total = Duration::ZERO;
        pace_stream_batch_with(
            ms(200),
            &stop,
            || {
                let n = calls.get();
                calls.set(n + 1);
                if n < 2 {
                    (Serious, false)
                } else {
                    (Nominal, false)
                }
            },
            |d| {
                assert!(d <= ms(50));
                recovery_total += d;
            },
        );
        assert_eq!(calls.get(), 3);
        assert_eq!(recovery_total, secs(2));

        // Serious -> Fair on battery honors full Fair+battery rest target rather than under-resting.
        let calls = Cell::new(0usize);
        let mut fair_recovery = Duration::ZERO;
        pace_stream_batch_with(
            secs(1),
            &stop,
            || {
                let n = calls.get();
                calls.set(n + 1);
                if n == 0 {
                    (Critical, true)
                } else {
                    (Fair, true)
                }
            },
            |d| {
                assert!(d <= ms(50));
                fair_recovery += d;
            },
        );
        assert_eq!(calls.get(), 2);
        assert_eq!(fair_recovery, secs(7));

        // Stuck Serious yields cleanly at the 30s cap.
        let mut cap_total = Duration::ZERO;
        pace_stream_batch_with(
            ms(200),
            &stop,
            || (Serious, false),
            |d| {
                assert!(d <= ms(50));
                cap_total += d;
            },
        );
        assert_eq!(cap_total, secs(30));
    }

    #[test]
    fn thermal_pressure_and_battery_power_live_smoke() {
        let pressure = thermal_pressure();
        assert!(pressure <= ThermalPressure::Critical);
        let _on_battery: bool = on_battery_power();
        // Fast (<50ms) stub batches must never stall even if the host is thermally hot.
        let stop = AtomicBool::new(false);
        let started = std::time::Instant::now();
        pace_stream_batch(Duration::from_millis(10), &stop);
        assert!(started.elapsed() < Duration::from_millis(50));
    }

    #[test]
    fn open_local_checked_enforces_symlink_cap_stamp_seek_and_verify() {
        use std::os::unix::fs::symlink;

        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-open-checked-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();

        let file_path = root.join("sample.bin");
        fs::write(&file_path, b"0123456789abcdef").unwrap();
        let meta = fs::symlink_metadata(&file_path).unwrap();
        let live_stamp = crate::index::stamp(&meta);

        // Symlink leaf and symlink ancestor must be rejected.
        let link_file = root.join("link.bin");
        symlink(&file_path, &link_file).unwrap();
        assert!(open_local_checked(&link_file, 64, None).is_err());

        let subdir = root.join("real_dir");
        fs::create_dir_all(&subdir).unwrap();
        let nested = subdir.join("inside.bin");
        fs::write(&nested, b"hello").unwrap();
        let link_dir = root.join("link_dir");
        symlink(&subdir, &link_dir).unwrap();
        assert!(open_local_checked(&link_dir.join("inside.bin"), 64, None).is_err());

        // Size cap rejection.
        assert!(open_local_checked(&file_path, 8, None).is_err());

        // Stamp mismatch rejection.
        assert!(open_local_checked(&file_path, 64, Some("0:0:16:0:0")).is_err());

        // Seek + read + verify_unchanged on valid resident file.
        assert_eq!(read_local(&file_path, 64).unwrap(), b"0123456789abcdef");
        let mut checked = open_local_checked(&file_path, 64, Some(&live_stamp)).unwrap();
        assert_eq!(checked.seek(SeekFrom::Start(10)).unwrap(), 10);
        let mut tail = [0u8; 6];
        checked.read_exact(&mut tail).unwrap();
        assert_eq!(&tail, b"abcdef");
        checked.verify_unchanged().unwrap();

        // In-place mutation invalidates verify_unchanged().
        fs::write(&file_path, b"mutated payload with different size").unwrap();
        assert!(checked.verify_unchanged().is_err());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn decode_codepage_handles_cjk_and_western_codepages() {
        // Empty input always succeeds.
        assert_eq!(decode_codepage(936, b"").as_deref(), Some(""));
        // Windows-1252: Euro sign + smart quotes + accented Latin.
        assert_eq!(
            decode_codepage(1252, &[0x80, b' ', 0x93, b'c', b'a', b'f', 0xE9, 0x94]).as_deref(),
            Some("€ “café”")
        );
        // GBK (936): "中文测试"
        assert_eq!(
            decode_codepage(936, &[0xD6, 0xD0, 0xCE, 0xC4, 0xB2, 0xE2, 0xCA, 0xD4]).as_deref(),
            Some("中文测试")
        );
        // Big5 (950): "繁體中文"
        assert_eq!(
            decode_codepage(950, &[0xC1, 0x63, 0xC5, 0xE9, 0xA4, 0xA4, 0xA4, 0xE5]).as_deref(),
            Some("繁體中文")
        );
        // Shift-JIS (932): "日本語"
        assert_eq!(
            decode_codepage(932, &[0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA]).as_deref(),
            Some("日本語")
        );
        // Unknown Windows codepage returns None.
        assert_eq!(decode_codepage(999_999, b"abc"), None);
    }
}
