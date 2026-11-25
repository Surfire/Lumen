use anyhow::Result;
use std::fs::File;

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use anyhow::ensure;
    use std::{ffi::c_void, os::unix::fs::MetadataExt};

    unsafe extern "C" {
        fn CC_SHA256(data: *const c_void, len: u32, digest: *mut u8) -> *mut u8;
    }

    pub(crate) struct Snapshot(Vec<u8>);

    impl Snapshot {
        pub(crate) fn new(package: &File, manifest: &str) -> Result<Self> {
            let metadata = package.metadata()?;
            let mut snapshot = Self(b"lumen-extension-snapshot-v1".to_vec());
            snapshot.field(&metadata.dev().to_be_bytes());
            snapshot.field(&metadata.ino().to_be_bytes());
            snapshot.field(manifest.as_bytes());
            Ok(snapshot)
        }

        pub(crate) fn source(&mut self, name: &str, source: &str) {
            self.field(name.as_bytes());
            self.field(source.as_bytes());
        }

        pub(crate) fn finish(self) -> Result<Option<String>> {
            let mut digest = [0_u8; 32];
            // The length is bounded by the manifest and command source limits.
            let len = u32::try_from(self.0.len())?;
            let result = unsafe { CC_SHA256(self.0.as_ptr().cast(), len, digest.as_mut_ptr()) };
            ensure!(!result.is_null(), "compute extension snapshot");
            Ok(Some(
                digest.iter().map(|byte| format!("{byte:02x}")).collect(),
            ))
        }

        fn field(&mut self, field: &[u8]) {
            self.0
                .extend_from_slice(&(field.len() as u64).to_be_bytes());
            self.0.extend_from_slice(field);
        }
    }
}

#[cfg(target_os = "macos")]
pub(crate) use macos::Snapshot;

#[cfg(not(target_os = "macos"))]
pub(crate) struct Snapshot;

#[cfg(not(target_os = "macos"))]
impl Snapshot {
    pub(crate) fn new(_package: &File, _manifest: &str) -> Result<Self> {
        Ok(Self)
    }

    pub(crate) fn source(&mut self, _name: &str, _source: &str) {}

    pub(crate) fn finish(self) -> Result<Option<String>> {
        Ok(None)
    }
}
