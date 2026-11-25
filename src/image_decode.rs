//! Decode already-authorized bytes with ImageIO. Never hand it a file or URL.
#[cfg(target_os = "macos")]
mod native {
    use std::{
        ffi::{CStr, c_char, c_void},
        ptr, slice,
    };

    type Ref = *const c_void;
    type Mutable = *mut c_void;
    const UTF8: u32 = 0x0800_0100;
    const CF_SINT64: isize = 4;
    const MAX_INPUT_PIXELS: i64 = 32_000_000;
    const THUMBNAIL_SIDE: i64 = 512;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFBooleanTrue: Ref;
        static kCFBooleanFalse: Ref;
        fn CFRelease(value: Ref);
        fn CFEqual(a: Ref, b: Ref) -> u8;
        fn CFGetTypeID(value: Ref) -> usize;
        fn CFNumberGetTypeID() -> usize;
        fn CFStringCreateWithCString(allocator: Ref, string: *const c_char, encoding: u32) -> Ref;
        fn CFDataCreate(allocator: Ref, bytes: *const u8, length: isize) -> Ref;
        fn CFDataCreateMutable(allocator: Ref, capacity: isize) -> Mutable;
        fn CFDataGetLength(data: Ref) -> isize;
        fn CFDataGetBytePtr(data: Ref) -> *const u8;
        fn CFNumberCreate(allocator: Ref, kind: isize, value: Ref) -> Ref;
        fn CFNumberGetValue(number: Ref, kind: isize, value: Mutable) -> u8;
        fn CFDictionaryCreate(
            allocator: Ref,
            keys: *const Ref,
            values: *const Ref,
            count: isize,
            key_callbacks: Ref,
            value_callbacks: Ref,
        ) -> Ref;
        fn CFDictionaryGetValue(dictionary: Ref, key: Ref) -> Ref;
    }

    #[link(name = "ImageIO", kind = "framework")]
    unsafe extern "C" {
        static kCGImagePropertyPixelWidth: Ref;
        static kCGImagePropertyPixelHeight: Ref;
        static kCGImageSourceShouldCache: Ref;
        static kCGImageSourceCreateThumbnailFromImageAlways: Ref;
        static kCGImageSourceCreateThumbnailWithTransform: Ref;
        static kCGImageSourceThumbnailMaxPixelSize: Ref;
        fn CGImageSourceCreateWithData(data: Ref, options: Ref) -> Ref;
        fn CGImageSourceGetCount(source: Ref) -> usize;
        fn CGImageSourceGetType(source: Ref) -> Ref;
        fn CGImageSourceCopyPropertiesAtIndex(source: Ref, index: usize, options: Ref) -> Ref;
        fn CGImageSourceCreateThumbnailAtIndex(source: Ref, index: usize, options: Ref) -> Ref;
        fn CGImageDestinationCreateWithData(
            data: Mutable,
            format: Ref,
            count: usize,
            options: Ref,
        ) -> Ref;
        fn CGImageDestinationAddImage(destination: Ref, image: Ref, options: Ref);
        fn CGImageDestinationFinalize(destination: Ref) -> bool;
    }

    struct Owned(Ref);

    impl Owned {
        fn new(p: Ref) -> Option<Self> {
            (!p.is_null()).then(|| Self(p))
        }

        fn string(s: &CStr) -> Option<Self> {
            Self::new(unsafe { CFStringCreateWithCString(ptr::null(), s.as_ptr(), UTF8) })
        }
    }

    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0) }
        }
    }

    // All keys and values are framework constants or held by the caller while
    // ImageIO uses this dictionary. No callbacks or transferred ownership.
    fn options<const N: usize>(keys: [Ref; N], values: [Ref; N]) -> Option<Owned> {
        Owned::new(unsafe {
            CFDictionaryCreate(
                ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                N as isize,
                ptr::null(),
                ptr::null(),
            )
        })
    }

    fn dimension(props: Ref, key: Ref) -> Option<i64> {
        let mut value = 0_i64;
        unsafe {
            let number = CFDictionaryGetValue(props, key);
            if number.is_null()
                || CFGetTypeID(number) != CFNumberGetTypeID()
                || CFNumberGetValue(number, CF_SINT64, (&mut value as *mut i64).cast()) == 0
            {
                return None;
            }
        }
        (value > 0).then_some(value)
    }

    pub(super) fn thumbnail(bytes: &[u8]) -> Option<Vec<u8>> {
        // Reject unapproved formats before sending even metadata to an OS decoder.
        let expected_type = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            c"public.png"
        } else if bytes.starts_with(b"\xff\xd8\xff") {
            c"public.jpeg"
        } else {
            return None;
        };
        let expected = Owned::string(expected_type)?;
        let png = Owned::string(c"public.png")?;
        unsafe {
            let data = Owned::new(CFDataCreate(
                ptr::null(),
                bytes.as_ptr(),
                bytes.len().try_into().ok()?,
            ))?;
            let no_cache = options([kCGImageSourceShouldCache], [kCFBooleanFalse])?;
            let source = Owned::new(CGImageSourceCreateWithData(data.0, no_cache.0))?;
            let format = CGImageSourceGetType(source.0);
            if format.is_null()
                || CFEqual(format, expected.0) == 0
                || CGImageSourceGetCount(source.0) != 1
            {
                return None;
            }
            let properties =
                Owned::new(CGImageSourceCopyPropertiesAtIndex(source.0, 0, no_cache.0))?;
            let width = dimension(properties.0, kCGImagePropertyPixelWidth)?;
            let height = dimension(properties.0, kCGImagePropertyPixelHeight)?;
            if width.checked_mul(height)? > MAX_INPUT_PIXELS {
                return None;
            }
            let max_side = Owned::new(CFNumberCreate(
                ptr::null(),
                CF_SINT64,
                (&THUMBNAIL_SIDE as *const i64).cast(),
            ))?;
            let thumbnail_options = options(
                [
                    kCGImageSourceShouldCache,
                    kCGImageSourceCreateThumbnailFromImageAlways,
                    kCGImageSourceCreateThumbnailWithTransform,
                    kCGImageSourceThumbnailMaxPixelSize,
                ],
                [kCFBooleanFalse, kCFBooleanTrue, kCFBooleanTrue, max_side.0],
            )?;
            let image = Owned::new(CGImageSourceCreateThumbnailAtIndex(
                source.0,
                0,
                thumbnail_options.0,
            ))?;
            let output = Owned::new(CFDataCreateMutable(ptr::null(), 0))?;
            let destination = Owned::new(CGImageDestinationCreateWithData(
                output.0.cast_mut(),
                png.0,
                1,
                ptr::null(),
            ))?;
            CGImageDestinationAddImage(destination.0, image.0, ptr::null());
            if !CGImageDestinationFinalize(destination.0) {
                return None;
            }
            let length = usize::try_from(CFDataGetLength(output.0)).ok()?;
            let start = CFDataGetBytePtr(output.0);
            if start.is_null() || length == 0 || length as u64 > crate::gemma::IMAGE_MAX_BYTES {
                return None;
            }
            Some(slice::from_raw_parts(start, length).to_vec())
        }
    }
}

pub(super) fn thumbnail(bytes: &[u8]) -> Option<Vec<u8>> {
    #[cfg(target_os = "macos")]
    return native::thumbnail(bytes);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = bytes;
        None
    }
}
