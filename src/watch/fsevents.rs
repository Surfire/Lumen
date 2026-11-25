use super::macos::Sink;
use anyhow::{Result, bail};
use std::{
    ffi::{CStr, c_char, c_void},
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::Arc,
};

type Cf = *const c_void;
type NativeStream = *mut c_void;
type DispatchQueue = *mut c_void;
type Callback =
    unsafe extern "C" fn(*const c_void, *mut c_void, usize, *mut c_void, *const u32, *const u64);

#[repr(C)]
struct Context {
    version: isize,
    info: *mut c_void,
    retain: Option<unsafe extern "C" fn(*const c_void) -> *const c_void>,
    release: Option<unsafe extern "C" fn(*const c_void)>,
    copy_description: Option<unsafe extern "C" fn(*const c_void) -> Cf>,
}

#[repr(C)]
struct ArrayCallbacks {
    version: isize,
    retain: Option<unsafe extern "C" fn(Cf, Cf) -> Cf>,
    release: Option<unsafe extern "C" fn(Cf, Cf)>,
    copy_description: Option<unsafe extern "C" fn(Cf) -> Cf>,
    equal: Option<unsafe extern "C" fn(Cf, Cf) -> u8>,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeArrayCallBacks: ArrayCallbacks;
    fn CFStringCreateWithFileSystemRepresentation(allocator: Cf, text: *const c_char) -> Cf;
    fn CFArrayCreate(
        allocator: Cf,
        values: *const Cf,
        count: isize,
        callbacks: *const ArrayCallbacks,
    ) -> Cf;
    fn CFRelease(object: Cf);
    fn CFUUIDCreateString(allocator: Cf, uuid: Cf) -> Cf;
    fn CFStringGetCString(value: Cf, output: *mut u8, size: isize, encoding: u32) -> u8;
}

#[link(name = "CoreServices", kind = "framework")]
unsafe extern "C" {
    fn FSEventStreamCreate(
        allocator: Cf,
        callback: Callback,
        context: *mut Context,
        paths: Cf,
        since_when: u64,
        latency: f64,
        flags: u32,
    ) -> NativeStream;
    fn FSEventStreamCreateRelativeToDevice(
        allocator: Cf,
        callback: Callback,
        context: *mut Context,
        device: libc::dev_t,
        paths: Cf,
        since_when: u64,
        latency: f64,
        flags: u32,
    ) -> NativeStream;
    fn FSEventsCopyUUIDForDevice(device: libc::dev_t) -> Cf;
    fn FSEventsGetCurrentEventId() -> u64;
    fn FSEventStreamSetDispatchQueue(stream: NativeStream, queue: DispatchQueue);
    fn FSEventStreamStart(stream: NativeStream) -> u8;
    fn FSEventStreamStop(stream: NativeStream);
    fn FSEventStreamInvalidate(stream: NativeStream);
    fn FSEventStreamRelease(stream: NativeStream);
}

unsafe extern "C" {
    fn dispatch_queue_create(label: *const c_char, attr: DispatchQueue) -> DispatchQueue;
    fn dispatch_release(queue: DispatchQueue);
}

const SINCE_NOW: u64 = u64::MAX;
const NO_DEFER: u32 = 0x02;
const WATCH_ROOT: u32 = 0x04;
const FILE_EVENTS: u32 = 0x10;
const FULL_HISTORY: u32 = 0x80;

const MUST_SCAN_SUBDIRS: u32 = 0x0001;
const LOST_EVENTS: u32 = 0x0002 | 0x0004 | 0x0008; // user dropped, kernel dropped, IDs wrapped
const HISTORY_DONE: u32 = 0x0010;
const ROOT_CHANGED: u32 = 0x0020;
const VOLUME_CHANGED: u32 = 0x0040 | 0x0080; // mount, unmount
const TREE_CHANGED: u32 = 0x0100 | 0x0200 | 0x0400 | 0x0800 | 0x4000 | 0x8000; // create, remove, inode metadata, rename, owner, xattrs
const IS_DIRECTORY: u32 = 0x0002_0000;

struct CfObject(Cf);
impl Drop for CfObject {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

pub(super) fn uuid(device: libc::dev_t) -> Option<String> {
    let uuid = unsafe { FSEventsCopyUUIDForDevice(device) };
    if uuid.is_null() {
        return None;
    }
    let uuid = CfObject(uuid);
    let string = unsafe { CFUUIDCreateString(null(), uuid.0) };
    if string.is_null() {
        return None;
    }
    let string = CfObject(string);
    let mut output = [0; 37];
    let ok = unsafe { CFStringGetCString(string.0, output.as_mut_ptr(), 37, 0x0800_0100) };
    if ok == 0 {
        return None;
    }
    unsafe { CStr::from_ptr(output.as_ptr().cast()) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

pub(super) fn current_id() -> Option<u64> {
    // IDs are generated system-wide. A full walk covers the state through
    // this pre-subscription fence. Its volume UUID and boot session bound it
    // to the current host and journal.
    let id = unsafe { FSEventsGetCurrentEventId() };
    (id != 0 && id != SINCE_NOW).then_some(id)
}

pub(super) struct Stream {
    stream: NativeStream,
    started: bool,
}

impl Stream {
    pub(super) fn start(
        paths: &[PathBuf],
        sink: &Arc<Sink>,
        replay: Option<(libc::dev_t, u64)>,
    ) -> Result<Self> {
        let strings = paths
            .iter()
            .map(|path| {
                let path = std::ffi::CString::new(path.as_os_str().as_bytes())?;
                let value =
                    unsafe { CFStringCreateWithFileSystemRepresentation(null(), path.as_ptr()) };
                if value.is_null() {
                    bail!("could not convert watch path to a Core Foundation string");
                }
                Ok(CfObject(value))
            })
            .collect::<Result<Vec<_>>>()?;
        let values: Vec<_> = strings.iter().map(|s| s.0).collect();
        let array = unsafe {
            CFArrayCreate(
                null(),
                values.as_ptr(),
                values.len() as isize,
                &kCFTypeArrayCallBacks,
            )
        };
        if array.is_null() {
            bail!("could not allocate FSEvents path array");
        }
        let array = CfObject(array);
        let mut context = Context {
            version: 0,
            info: Arc::as_ptr(sink).cast_mut().cast(),
            retain: Some(retain),
            release: Some(release),
            copy_description: None,
        };
        let flags = NO_DEFER | WATCH_ROOT | FILE_EVENTS;
        let stream = unsafe {
            if let Some((device, since)) = replay {
                FSEventStreamCreateRelativeToDevice(
                    null(),
                    callback,
                    &mut context,
                    device,
                    array.0,
                    since,
                    0.18,
                    flags | FULL_HISTORY,
                )
            } else {
                FSEventStreamCreate(
                    null(),
                    callback,
                    &mut context,
                    array.0,
                    SINCE_NOW,
                    0.18,
                    flags,
                )
            }
        };
        if stream.is_null() {
            bail!("could not create FSEvents stream");
        }
        let queue = unsafe { dispatch_queue_create(c"lumen.fsevents".as_ptr(), null_mut()) };
        if queue.is_null() {
            unsafe { FSEventStreamRelease(stream) };
            bail!("could not create FSEvents dispatch queue");
        }
        unsafe {
            FSEventStreamSetDispatchQueue(stream, queue);
            dispatch_release(queue);
        }
        let started = unsafe { FSEventStreamStart(stream) } != 0;
        let stream = Self { stream, started };
        if !started {
            bail!("macOS refused to start the FSEvents stream");
        }
        Ok(stream)
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        unsafe {
            if self.started {
                FSEventStreamStop(self.stream);
            }
            FSEventStreamInvalidate(self.stream);
            FSEventStreamRelease(self.stream);
        }
    }
}

unsafe extern "C" fn retain(info: *const c_void) -> *const c_void {
    unsafe { Arc::increment_strong_count(info.cast::<Sink>()) };
    info
}

unsafe extern "C" fn release(info: *const c_void) {
    unsafe { Arc::decrement_strong_count(info.cast::<Sink>()) };
}

unsafe extern "C" fn callback(
    _: *const c_void,
    info: *mut c_void,
    count: usize,
    raw_paths: *mut c_void,
    flags: *const u32,
    ids: *const u64,
) {
    if count == 0 {
        return;
    }
    let sink = unsafe { &*info.cast::<Sink>() };
    let paths = unsafe { std::slice::from_raw_parts(raw_paths.cast::<*const c_char>(), count) };
    let flags = unsafe { std::slice::from_raw_parts(flags, count) };
    let ids = unsafe { std::slice::from_raw_parts(ids, count) };
    let mut watermark = 0;
    for ((&raw_path, &flag), &id) in paths.iter().zip(flags).zip(ids) {
        if flag & LOST_EVENTS != 0 {
            sink.lost();
        } else if flag & HISTORY_DONE != 0 {
            sink.checkpoint(watermark, true);
            watermark = 0;
        } else {
            if raw_path.is_null() {
                sink.lost();
                continue;
            }
            let path = unsafe { CStr::from_ptr(raw_path) }.to_bytes();
            let path = Path::new(std::ffi::OsStr::from_bytes(path));
            let rearm = flag & (ROOT_CHANGED | VOLUME_CHANGED) != 0;
            let subtree = rearm
                || flag & MUST_SCAN_SUBDIRS != 0
                || flag == 0
                || flag & IS_DIRECTORY != 0 && flag & TREE_CHANGED != 0;
            if sink.native_change(path, subtree, rearm, flag & MUST_SCAN_SUBDIRS != 0) {
                watermark = watermark.max(id);
            }
        }
    }
    if watermark != 0 {
        sink.checkpoint(watermark, false);
    }
}
