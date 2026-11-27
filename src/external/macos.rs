use super::{Mount, MountKind, Mounted, uuid_valid};
use std::{
    ffi::{CStr, OsStr, c_char, c_void},
    mem::{MaybeUninit, size_of},
    os::unix::ffi::OsStrExt,
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
    fn DADiskCopyIOMedia(disk: Cf) -> u32;
    static kDADiskDescriptionDeviceInternalKey: Cf;
    static kDADiskDescriptionDeviceProtocolKey: Cf;
    static kDADiskDescriptionVolumeUUIDKey: Cf;
}

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    fn IORegistryEntryGetRegistryEntryID(media: u32, id: *mut u64) -> libc::c_int;
    fn IOObjectRelease(media: u32) -> libc::c_int;
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

fn physical_identity(session: &Owned, source: &CStr) -> Option<(String, u64)> {
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
    if !uuid_valid(&uuid) {
        return None;
    }
    // The boot-local media registry entry disambiguates clones even if macOS
    // recycles a device number, filesystem ID and mount point.
    let media = unsafe { DADiskCopyIOMedia(disk.0) };
    if media == 0 {
        return None;
    }
    let mut media_id = 0;
    let status = unsafe { IORegistryEntryGetRegistryEntryID(media, &mut media_id) };
    unsafe { IOObjectRelease(media) };
    (status == 0 && media_id != 0).then_some((uuid, media_id))
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
            || mount.f_flags & libc::MNT_DONTBROWSE as u32 != 0
        {
            continue;
        }
        let source = unsafe { CStr::from_ptr(mount.f_mntfromname.as_ptr()) };
        if mount.f_flags & libc::MNT_LOCAL as u32 == 0 {
            let fstype = unsafe { CStr::from_ptr(mount.f_fstypename.as_ptr()) };
            if let Some(volume) =
                network_mount(path, &fstype.to_string_lossy(), &source.to_string_lossy())
            {
                result.eligible.push(volume);
            }
            continue;
        }
        let Some((uuid, media_id)) = physical_identity(&session, source) else {
            continue;
        };
        // Darwin's fsid_t contains exactly two i32 words. Reading them from
        // the mount table avoids stat'ing an external root before opt-in.
        let filesystem_id = unsafe { std::mem::transmute::<libc::fsid_t, [i32; 2]>(mount.f_fsid) };
        result.eligible.push(Mount {
            path: path.to_owned(),
            uuid,
            kind: MountKind::Physical {
                filesystem_id,
                media_id,
                boot: boot.clone(),
            },
        });
    }
    Some(result)
}

fn network_protocol(fstype: &str) -> Option<&'static str> {
    Some(match fstype {
        "smbfs" => "smb",
        "nfs" => "nfs",
        "afpfs" => "afp",
        "webdav" => "webdav",
        _ => return None,
    })
}

/// Drop any `user[:password]@` userinfo from the URL authority (RFC 3986:
/// the authority ends at the first `/`), so credentials never reach a
/// registration, catalog, status reply or log line.
pub(super) fn sanitize_source(source: &str) -> String {
    let (scheme, rest) = match source.find("://") {
        Some(at) => source.split_at(at + 3),
        None if source.starts_with("//") => source.split_at(2),
        None => ("", source),
    };
    let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    format!(
        "{}{}{path}",
        scheme.to_ascii_lowercase(),
        host.to_ascii_lowercase()
    )
}

unsafe extern "C" {
    // CommonCrypto ships in libSystem.
    fn CC_SHA256(data: *const c_void, len: u32, md: *mut u8) -> *mut u8;
}

/// Deterministic UUID-shaped identity for a share, derived only from its
/// protocol and credential-free source.
pub(super) fn network_uuid(protocol: &str, sanitized_source: &str) -> Option<String> {
    let input = format!("lumen-netvol:{protocol}:{sanitized_source}");
    let mut digest = [0_u8; 32];
    let len = u32::try_from(input.len()).ok()?;
    unsafe { CC_SHA256(input.as_ptr().cast(), len, digest.as_mut_ptr()) };
    let hex: String = digest[..16].iter().map(|b| format!("{b:02x}")).collect();
    let uuid = format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    );
    uuid_valid(&uuid).then_some(uuid)
}

/// A browsable `/Volumes/<name>` SMB/NFS/AFP/WebDAV share. Time Machine
/// destinations and hidden mount points are never offered.
pub(super) fn network_mount(path: &Path, fstype: &str, source: &str) -> Option<Mount> {
    let protocol = network_protocol(fstype)?;
    let name = path.file_name()?.as_bytes();
    if name.starts_with(b".") || name.starts_with(b"com.apple.TimeMachine") {
        return None;
    }
    let sanitized_source = sanitize_source(source);
    Some(Mount {
        path: path.to_owned(),
        uuid: network_uuid(protocol, &sanitized_source)?,
        kind: MountKind::Network {
            protocol: protocol.into(),
            sanitized_source,
        },
    })
}
