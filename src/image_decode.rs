//! Decode already-authorized bytes with ImageIO. Never hand it a file or URL.
use std::path::Path;

pub(super) const MAX_FILE_BYTES: u64 = 12 * 1024 * 1024;

pub(super) fn supported_path(path: &Path) -> bool {
    path.extension().is_some_and(|ext| {
        ["png", "jpg", "jpeg", "heic", "heif", "webp"]
            .iter()
            .any(|kind| ext.eq_ignore_ascii_case(kind))
    })
}

#[cfg(target_os = "macos")]
fn sniff(bytes: &[u8]) -> Option<&'static std::ffi::CStr> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some(c"public.png");
    }
    if bytes.starts_with(b"\xff\xd8\xff") {
        return Some(c"public.jpeg");
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        return Some(c"org.webmproject.webp");
    }
    // HEIF's ftyp contains a major brand, minor version, and aligned compatible
    // brands. Do not scan bytes beyond this box (e.g. inside EXIF or payloads).
    if bytes.get(4..8)? != b"ftyp" {
        return None;
    }
    let (header, size) = match u32::from_be_bytes(bytes.get(..4)?.try_into().ok()?) {
        1 => (
            16,
            usize::try_from(u64::from_be_bytes(bytes.get(8..16)?.try_into().ok()?)).ok()?,
        ),
        0 => (8, bytes.len()),
        size => (8, size as usize),
    };
    let major = bytes.get(header..header + 4)?;
    let (compatible, []) = bytes.get(header + 8..size)?.as_chunks::<4>() else {
        return None;
    };
    let mut format = None;
    for brand in std::iter::once(major).chain(compatible.iter().map(<[u8; 4]>::as_slice)) {
        match brand {
            b"heic" | b"heix" => return Some(c"public.heic"),
            b"mif1" => format = Some(c"public.heif"),
            _ => {}
        }
    }
    format
}
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
    // Darwin CFNumber.h: kCFNumberFloat64Type = 6
    const CF_FLOAT64: isize = 6;
    const MAX_INPUT_PIXELS: i64 = 32_000_000;
    const THUMBNAIL_SIDE: i64 = 512;
    const JPEG_QUALITY: f64 = 0.85;

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

    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGImageGetAlphaInfo(image: Ref) -> u32;
    }

    #[link(name = "ImageIO", kind = "framework")]
    unsafe extern "C" {
        static kCGImagePropertyPixelWidth: Ref;
        static kCGImagePropertyPixelHeight: Ref;
        static kCGImagePropertyHasAlpha: Ref;
        static kCGImageSourceShouldCache: Ref;
        static kCGImageSourceCreateThumbnailFromImageAlways: Ref;
        static kCGImageSourceCreateThumbnailWithTransform: Ref;
        static kCGImageSourceThumbnailMaxPixelSize: Ref;
        static kCGImageDestinationLossyCompressionQuality: Ref;
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

    fn has_alpha(props: Ref) -> bool {
        unsafe {
            let flag = CFDictionaryGetValue(props, kCGImagePropertyHasAlpha);
            !flag.is_null() && CFEqual(flag, kCFBooleanTrue) != 0
        }
    }

    pub(super) fn thumbnail(bytes: &[u8]) -> Option<Vec<u8>> {
        // Reject unapproved formats before sending even metadata to an OS decoder.
        let expected_type = super::sniff(bytes)?;
        let expected = Owned::string(expected_type)?;
        // Generic HEIF (mif1) may still contain a HEVC-coded primary image.
        let heic = (expected_type == c"public.heif")
            .then(|| Owned::string(c"public.heic"))
            .flatten();
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
                || (CFEqual(format, expected.0) == 0
                    && heic
                        .as_ref()
                        .is_none_or(|heic| CFEqual(format, heic.0) == 0))
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
            // Darwin CGImage.h CGImageAlphaInfo: None (0), NoneSkipLast (5), NoneSkipFirst (6).
            // Apple's HEIF thumbnailer renders opaque HEIC/HEIF into an RGBA buffer (PremultipliedLast = 1),
            // so combine kCGImagePropertyHasAlpha with CGImageGetAlphaInfo.
            let opaque = !has_alpha(properties.0)
                && (matches!(CGImageGetAlphaInfo(image.0), 0 | 5 | 6)
                    || expected_type == c"public.heic"
                    || expected_type == c"public.heif");
            let (dest_format, _quality_number, dest_options) = if opaque {
                let number = Owned::new(CFNumberCreate(
                    ptr::null(),
                    CF_FLOAT64,
                    (&JPEG_QUALITY as *const f64).cast(),
                ))?;
                let opts = options([kCGImageDestinationLossyCompressionQuality], [number.0])?;
                (Owned::string(c"public.jpeg")?, Some(number), Some(opts))
            } else {
                (Owned::string(c"public.png")?, None, None)
            };
            let output = Owned::new(CFDataCreateMutable(ptr::null(), 0))?;
            let destination = Owned::new(CGImageDestinationCreateWithData(
                output.0.cast_mut(),
                dest_format.0,
                1,
                ptr::null(),
            ))?;
            CGImageDestinationAddImage(
                destination.0,
                image.0,
                dest_options.as_ref().map_or(ptr::null(), |opts| opts.0),
            );
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

    #[cfg(test)]
    pub(super) fn dimensions(bytes: &[u8]) -> Option<(i64, i64)> {
        unsafe {
            let data = Owned::new(CFDataCreate(
                ptr::null(),
                bytes.as_ptr(),
                bytes.len().try_into().ok()?,
            ))?;
            let no_cache = options([kCGImageSourceShouldCache], [kCFBooleanFalse])?;
            let source = Owned::new(CGImageSourceCreateWithData(data.0, no_cache.0))?;
            let properties =
                Owned::new(CGImageSourceCopyPropertiesAtIndex(source.0, 0, no_cache.0))?;
            Some((
                dimension(properties.0, kCGImagePropertyPixelWidth)?,
                dimension(properties.0, kCGImagePropertyPixelHeight)?,
            ))
        }
    }
}

pub(super) fn thumbnail(bytes: &[u8]) -> Option<Vec<u8>> {
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return None;
    }
    #[cfg(target_os = "macos")]
    return native::thumbnail(bytes);
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::{fs, process::Command};

    #[test]
    fn imageio_decodes_heic_heif_and_webp_with_original_limits() {
        let root = std::env::temp_dir().join(format!("lumen-image-decode-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let ppm = root.join("colors.ppm");
        fs::write(&ppm, b"P6\n2 2\n255\n\xff\0\0\0\xff\0\0\0\xff\xff\xff\xff").unwrap();
        let png = root.join("colors.png");
        let heic = root.join("colors.heic");
        let sips = |options: &[&str], source: &Path, dest: &Path| {
            let output = Command::new("/usr/bin/sips")
                .args(options)
                .arg(source)
                .arg("--out")
                .arg(dest)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            fs::read(dest).unwrap()
        };
        let png_bytes = sips(&["-s", "format", "png"], &ppm, &png);
        let heic_bytes = sips(&["-s", "format", "heic"], &png, &heic);
        assert_eq!(sniff(&heic_bytes), Some(c"public.heic"));
        let mut heif = heic_bytes.clone();
        let end = u32::from_be_bytes(heif[..4].try_into().unwrap()) as usize;
        heif[8..12].copy_from_slice(b"mif1");
        for brand in heif[16..end].as_chunks_mut::<4>().0 {
            if matches!(&*brand, b"heic" | b"heix") {
                brand.copy_from_slice(b"mif1");
            }
        }
        assert_eq!(sniff(&heif), Some(c"public.heif"));
        // Lossless 2x2 WebP of the same colors, generated with cwebp.
        let webp = b"RIFF\x2c\0\0\0WEBPVP8L\x1f\0\0\0\x2f\x01\x40\0\0\x1f\x20\x10\x48\xde\x1f\x3a\x8d\xf9\x17\x10\x14\xfc\x1f\xdd\xfc\x47\x64\x0f\xe0\x06\x0c\x11\xfd\x0f\x01\0";
        for bytes in [heic_bytes.as_slice(), &heif, webp, &png_bytes] {
            let scaled = thumbnail(bytes).expect("ImageIO should decode the opaque image");
            assert_eq!(sniff(&scaled), Some(c"public.jpeg"));
            assert_eq!(native::dimensions(&scaled), Some((2, 2)));
        }
        // Transparent 2x2 RGBA PNG must keep alpha as PNG instead of flattening to JPEG.
        let rgba = transparent_rgba_png_2x2();
        let alpha_scaled = thumbnail(&rgba).expect("ImageIO should decode the transparent PNG");
        assert_eq!(sniff(&alpha_scaled), Some(c"public.png"));
        assert_eq!(&alpha_scaled[16..24], &[0, 0, 0, 2, 0, 0, 0, 2]);

        let mut too_many_bytes = heic_bytes;
        too_many_bytes.resize(MAX_FILE_BYTES as usize + 1, 0);
        assert!(thumbnail(&too_many_bytes).is_none());
        let oversized = sips(&["-z", "5400", "6000"], &png, &root.join("big.png"));
        assert_eq!(&oversized[16..24], &[0, 0, 23, 112, 0, 0, 21, 24]);
        assert!(thumbnail(&oversized).is_none());
        // Two independently decodable frames in an animated WebP container.
        let mut animated = b"RIFF\x92\0\0\0WEBPVP8X\x0a\0\0\0\x02\0\0\0\x01\0\0\x01\0\0ANIM\x06\0\0\0\xff\xff\xff\xff\0\0ANMF\x38\0\0\0\0\0\0\0\0\0\x01\0\0\x01\0\0\x64\0\0\x02".to_vec();
        animated.extend_from_slice(&webp[12..]);
        animated.extend_from_slice(b"ANMF\x26\0\0\0\0\0\0\0\0\0\x01\0\0\x01\0\0\x64\0\0\0VP8L\x0e\0\0\0\x2f\x01\x40\0\0\x07\x10\x11\xfd\x0f\x44\x44\xff\x03");
        assert_eq!(animated.len(), 154);
        assert!(thumbnail(&animated).is_none());
        fs::remove_dir_all(root).unwrap();
    }

    fn transparent_rgba_png_2x2() -> Vec<u8> {
        let crc32 = |data: &[u8]| -> u32 {
            let mut crc = 0xffff_ffff_u32;
            for &byte in data {
                crc ^= byte as u32;
                for _ in 0..8 {
                    crc = (crc >> 1) ^ (0xedb8_8320 & (0_u32.wrapping_sub(crc & 1)));
                }
            }
            !crc
        };
        let adler32 = |data: &[u8]| -> u32 {
            let (mut s1, mut s2) = (1_u32, 0_u32);
            for &byte in data {
                s1 = (s1 + byte as u32) % 65521;
                s2 = (s2 + s1) % 65521;
            }
            (s2 << 16) | s1
        };
        let chunk = |out: &mut Vec<u8>, tag: &[u8; 4], body: &[u8]| {
            out.extend_from_slice(&(body.len() as u32).to_be_bytes());
            let start = out.len();
            out.extend_from_slice(tag);
            out.extend_from_slice(body);
            out.extend_from_slice(&crc32(&out[start..]).to_be_bytes());
        };
        // Two scanlines of 2x2 8-bit RGBA: transparent red + opaque green, blue + half-alpha white.
        let raw: [u8; 18] = [
            0, 255, 0, 0, 0, 0, 255, 0, 255, // row 0
            0, 0, 0, 255, 255, 255, 255, 255, 128, // row 1
        ];
        let mut zlib = vec![0x78, 0x01, 0x01];
        zlib.extend_from_slice(&(raw.len() as u16).to_le_bytes());
        zlib.extend_from_slice(&(!(raw.len() as u16)).to_le_bytes());
        zlib.extend_from_slice(&raw);
        zlib.extend_from_slice(&adler32(&raw).to_be_bytes());

        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        chunk(&mut png, b"IHDR", &[0, 0, 0, 2, 0, 0, 0, 2, 8, 6, 0, 0, 0]);
        chunk(&mut png, b"IDAT", &zlib);
        chunk(&mut png, b"IEND", &[]);
        png
    }
}
