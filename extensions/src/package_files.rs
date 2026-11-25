use anyhow::{Context, Result, ensure};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{self, Read},
    mem::MaybeUninit,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::Path,
};

pub(crate) fn open_package(path: &Path) -> Result<File> {
    let path = path.components().collect::<std::path::PathBuf>();
    #[cfg(target_os = "macos")]
    let no_symlinks = libc::O_NOFOLLOW_ANY;
    #[cfg(not(target_os = "macos"))]
    let no_symlinks = libc::O_NOFOLLOW;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | no_symlinks | libc::O_NONBLOCK)
        .open(&path)
        .with_context(|| format!("open explicit extension directory {}", path.display()))
}

pub(crate) fn open_sources(package: &File) -> Result<File> {
    open_child(package, &child_name("src")?, libc::O_DIRECTORY)
        .context("open package src directory")
}

pub(crate) fn read_file(directory: &File, name: &str, limit: u64) -> Result<String> {
    let component = child_name(name)?;
    let mut stat = MaybeUninit::<libc::stat>::uninit();
    let status = unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            component.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if status != 0 {
        return Err(io::Error::last_os_error()).with_context(|| format!("inspect {name}"));
    }
    // fstatat initialized the buffer on success.
    let stat = unsafe { stat.assume_init() };
    ensure!(
        stat.st_mode & libc::S_IFMT == libc::S_IFREG
            && stat.st_nlink == 1
            && (0..=limit as libc::off_t).contains(&stat.st_size),
        "{name} must be a regular file with one link and at most {limit} bytes"
    );

    let file = open_child(directory, &component, 0).with_context(|| format!("open {name}"))?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file()
            && metadata.nlink() == 1
            && metadata.len() <= limit
            && metadata.dev() == stat.st_dev as u64
            && metadata.ino() == stat.st_ino,
        "{name} changed between inspection and open"
    );
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "{name} exceeded {limit} bytes");
    String::from_utf8(bytes).with_context(|| format!("{name} must be UTF-8"))
}

fn child_name(name: &str) -> io::Result<CString> {
    assert!(!name.is_empty() && !name.contains('/') && name != "." && name != "..");
    CString::new(name).map_err(io::Error::from)
}

fn open_child(directory: &File, name: &std::ffi::CStr, flags: libc::c_int) -> io::Result<File> {
    // Keep every lookup relative to its already-open parent directory.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd == -1 {
        return Err(io::Error::last_os_error());
    }
    // openat returned a newly owned descriptor.
    Ok(unsafe { File::from_raw_fd(fd) })
}

#[cfg(target_os = "macos")]
pub(crate) struct NoMaterialization(libc::c_int);

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn getiopolicy_np(kind: libc::c_int, scope: libc::c_int) -> libc::c_int;
    fn setiopolicy_np(kind: libc::c_int, scope: libc::c_int, policy: libc::c_int) -> libc::c_int;
}

#[cfg(target_os = "macos")]
impl NoMaterialization {
    // Darwin <sys/resource.h>, matching Lumen's indexer policy.
    const MATERIALIZE_DATALESS_FILES: libc::c_int = 3;
    const THREAD: libc::c_int = 1;
    const OFF: libc::c_int = 1;

    pub(crate) fn enter() -> Result<Self> {
        let previous = unsafe { getiopolicy_np(Self::MATERIALIZE_DATALESS_FILES, Self::THREAD) };
        if previous < 0
            || unsafe { setiopolicy_np(Self::MATERIALIZE_DATALESS_FILES, Self::THREAD, Self::OFF) }
                != 0
        {
            return Err(io::Error::last_os_error()).context("disable APFS materialization");
        }
        Ok(Self(previous))
    }
}

#[cfg(target_os = "macos")]
impl Drop for NoMaterialization {
    fn drop(&mut self) {
        if unsafe { setiopolicy_np(Self::MATERIALIZE_DATALESS_FILES, Self::THREAD, self.0) } != 0 {
            eprintln!("lumen-extensions: could not restore thread I/O policy");
        }
    }
}
