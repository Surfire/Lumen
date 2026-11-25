import Foundation
import PDFKit

let bytes = FileHandle.standardInput.readData(ofLength: 24 * 1024 * 1024 + 1)
guard !bytes.isEmpty, bytes.count <= 24 * 1024 * 1024,
      let pdf = PDFDocument(data: bytes), !pdf.isLocked, pdf.pageCount > 0,
      pdf.pageCount <= 350 else { exit(2) }
var result = ""
for i in 0..<pdf.pageCount {
    if let text = pdf.page(at: i)?.string, !text.isEmpty {
        if result.utf8.count + text.utf8.count + 1 > 2 * 1024 * 1024 { exit(3) }
        result.append(text)
        result.append("\n")
    }
}
if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { exit(4) }
FileHandle.standardOutput.write(Data(result.utf8))
