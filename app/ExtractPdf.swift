import Foundation
import PDFKit

struct ExtractedPage: Encodable {
    let page: Int
    let text: String
}

let bytes = FileHandle.standardInput.readData(ofLength: 24 * 1024 * 1024 + 1)
guard !bytes.isEmpty, bytes.count <= 24 * 1024 * 1024,
      let pdf = PDFDocument(data: bytes), !pdf.isLocked, pdf.pageCount > 0,
      pdf.pageCount <= 350 else { exit(2) }
var size = 0
var pages: [ExtractedPage] = []
for i in 0..<pdf.pageCount {
    if let text = pdf.page(at: i)?.string, !text.isEmpty {
        size += text.utf8.count + 1
        guard size <= 2 * 1024 * 1024 else { exit(3) }
        pages.append(ExtractedPage(page: i + 1, text: text))
    }
}
guard pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { exit(4) }
if CommandLine.arguments.dropFirst().elementsEqual(["--pages-v1"]) {
    guard let output = try? JSONEncoder().encode(pages) else { exit(3) }
    FileHandle.standardOutput.write(output)
} else {
    FileHandle.standardOutput.write(Data(pages.map { $0.text + "\n" }.joined().utf8))
}
