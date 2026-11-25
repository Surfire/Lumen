use super::{Mount, Mounted, uuid_valid};
use std::{
    ffi::{CStr, OsStr, c_char, c_void},
    fs,
    mem::{MaybeUninit, size_of},
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::Path,
    ptr::{null, null_mut},
};

type Cf = *const c_void;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: Cf);
    fn CFGetTypeID(value: Cf) -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(value: Cf) -> u8;
    fn CFUUIDGetTypeID() -> usize;
    fn CFUUIDCreateString(allocator: Cf, uuid: Cf) -> Cf;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetCString(value: Cf, out: *mut u8, size: isize, encoding: u32) -> u8;
    fn CFDictionaryGetValue(value: Cf, key: Cf) -> Cf;
}

#[link(name = "DiskArbitration", kind = "framework")]
unsafe extern "C" {
    fn DASessionCreate(allocator: Cf) -> Cf;
    fn DADiskCreateFromBSDName(allocator: Cf, session: Cf, name: *const c_char) -> Cf;
    fn DADiskCopyDescription(disk: Cf) -> Cf;
    static kDADiskDescriptionDeviceInternalKey: Cf;
    static kDADiskDescriptionDeviceProtocolKey: Cf;
    static kDADiskDescriptionVolumeUUIDKey: Cf;
}

struct Owned(Cf);
impl Owned {
    fn new(value: Cf) -> Option<Self> {
        (!value.is_null()).then(|| Self(value))
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

fn string(value: Cf) -> Option<String> {
    if value.is_null() || unsafe { CFGetTypeID(value) != CFStringGetTypeID() } {
        return None;
    }
    let mut buffer = [0; 128];
    let ok = unsafe { CFStringGetCString(value, buffer.as_mut_ptr(), 128, 0x0800_0100) };
    if ok == 0 {
        return None;
    }
    Some(
        CStr::from_bytes_until_nul(&buffer)
            .ok()?
            .to_str()
            .ok()?
            .to_owned(),
    )
}

fn boot_session() -> Option<String> {
    let mut buffer = [0; 64];
    let mut len = buffer.len();
    let ok = unsafe {
        libc::sysctlbyname(
            c"kern.bootsessionuuid".as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut len,
            null_mut(),
            0,
        )
    };
    if ok != 0 || len > buffer.len() {
        return None;
    }
    Some(
        CStr::from_bytes_until_nul(&buffer[..len])
            .ok()?
            .to_str()
            .ok()?
            .to_owned(),
    )
}

fn physical_uuid(session: &Owned, source: &CStr) -> Option<String> {
    if !source.to_bytes().starts_with(b"/dev/disk") {
        return None;
    }
    let disk = Owned::new(unsafe { DADiskCreateFromBSDName(null(), session.0, source.as_ptr()) })?;
    let dict = Owned::new(unsafe { DADiskCopyDescription(disk.0) })?;
    let internal = unsafe { CFDictionaryGetValue(dict.0, kDADiskDescriptionDeviceInternalKey) };
    if internal.is_null()
        || unsafe {
            CFGetTypeID(internal) != CFBooleanGetTypeID() || CFBooleanGetValue(internal) != 0
        }
    {
        return None;
    }
    let transport =
        string(unsafe { CFDictionaryGetValue(dict.0, kDADiskDescriptionDeviceProtocolKey) })?;
    // Unknown, virtual and network transports aren't eligible even if they
    // appear under /Volumes and report a local filesystem.
    if !matches!(
        transport.as_str(),
        "USB"
            | "Thunderbolt"
            | "FireWire"
            | "Secure Digital"
            | "SD"
            | "SATA"
            | "PCI-Express"
            | "NVMe"
            | "SCSI"
    ) {
        return None;
    }
    let uuid = unsafe { CFDictionaryGetValue(dict.0, kDADiskDescriptionVolumeUUIDKey) };
    if uuid.is_null() || unsafe { CFGetTypeID(uuid) != CFUUIDGetTypeID() } {
        return None;
    }
    let uuid = Owned::new(unsafe { CFUUIDCreateString(null(), uuid) })?;
    let uuid = string(uuid.0)?.to_ascii_lowercase();
    uuid_valid(&uuid).then_some(uuid)
}

pub(super) fn mounted() -> Option<Mounted> {
    let native_count = unsafe { libc::getfsstat(null_mut(), 0, libc::MNT_NOWAIT) };
    let capacity = usize::try_from(native_count).ok()?.checked_add(8)?;
    let bytes = capacity
        .checked_mul(size_of::<libc::statfs>())?
        .try_into()
        .ok()?;
    let mut buffer = vec![MaybeUninit::<libc::statfs>::uninit(); capacity];
    let count = unsafe { libc::getfsstat(buffer.as_mut_ptr().cast(), bytes, libc::MNT_NOWAIT) };
    let count = usize::try_from(count).ok()?;
    if count == 0 || count >= capacity {
        return None;
    }
    let boot = boot_session()?;
    let session = Owned::new(unsafe { DASessionCreate(null()) })?;
    let mut result = Mounted::default();
    for mount in &buffer[..count] {
        let mount = unsafe { mount.assume_init_ref() };
        let path = unsafe { CStr::from_ptr(mount.f_mntonname.as_ptr()) };
        let path = Path::new(OsStr::from_bytes(path.to_bytes()));
        result.points.push(path.to_owned());
        if path.parent() != Some(Path::new("/Volumes"))
            || mount.f_flags & libc::MNT_LOCAL as u32 == 0
        {
            continue;
        }
        let source = unsafe { CStr::from_ptr(mount.f_mntfromname.as_ptr()) };
        let Some(uuid) = physical_uuid(&session, source) else {
            continue;
        };
        let Ok(metadata) = fs::symlink_metadata(path) else {
            continue;
        };
        if !metadata.is_dir() || metadata.dev() == 0 {
            continue;
        }
        result.eligible.push(Mount {
            path: path.to_owned(),
            uuid,
            device: metadata.dev(),
            boot: boot.clone(),
            source: source.to_string_lossy().into_owned(),
        });
    }
    Some(result)
}
