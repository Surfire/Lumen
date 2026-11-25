import Darwin
import Foundation
import ImageIO
import Vision

let maxBytes = 12 * 1024 * 1024
let maxPixels = 32_000_000
let maxText = 2 * 1024 * 1024

// The indexer sends only bytes opened by its local-file reader. Standalone
// path use must also disable materialization before inspecting any ancestor.
func openLocalImage(_ path: String) -> FileHandle? {
    guard path.utf8.count < Int(PATH_MAX),
          setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                         IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
    let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    let parts = absolute.split(separator: "/")
    guard !parts.isEmpty, !parts.contains("..") else { return nil }
    var prefix = ""
    var info = stat()
    let dataless = UInt32(SF_DATALESS)
    for part in parts.dropLast() {
        prefix += "/" + part
        guard lstat(prefix, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_flags & dataless == 0 else { return nil }
    }
    guard lstat(absolute, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_flags & dataless == 0, info.st_size <= maxBytes else { return nil }
    let fd = open(absolute, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_flags & dataless == 0, info.st_size <= maxBytes else {
        close(fd)
        return nil
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

let args = Array(CommandLine.arguments.dropFirst())
let input: FileHandle
if args.isEmpty || args == ["-"] {
    input = FileHandle.standardInput
} else if args.count == 1, let file = openLocalImage(args[0]) {
    input = file
} else {
    exit(2)
}
let bytes = input.readData(ofLength: maxBytes + 1)
let formats = ["public.png", "public.jpeg", "public.heic", "public.heif", "org.webmproject.webp"]
let options = [kCGImageSourceShouldCache: false] as CFDictionary
guard !bytes.isEmpty, bytes.count <= maxBytes,
      let source = CGImageSourceCreateWithData(bytes as CFData, options),
      let format = CGImageSourceGetType(source), formats.contains(format as String),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
      let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
      width <= maxPixels / height,
      let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { exit(2) }
let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
    .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.automaticallyDetectsLanguage = true
let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
do {
    try handler.perform([request])
} catch {
    exit(2)
}
let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
guard text.utf8.count <= maxText else { exit(3) }
FileHandle.standardOutput.write(Data(text.utf8))
