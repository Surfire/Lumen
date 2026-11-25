// An optional offline NaturalLanguage adapter: argv[1] is the language and input is UTF-8.
import Foundation
import NaturalLanguage

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("expected en, zh-Hans, or another supported language tag\n".utf8))
    exit(2)
}
let raw = CommandLine.arguments[1]
let language = raw == "zh" ? NLLanguage.simplifiedChinese : NLLanguage(rawValue: raw)
let data = FileHandle.standardInput.readData(ofLength: 16_385)
guard data.count <= 16_384, let text = String(data: data, encoding: .utf8), !text.isEmpty,
      let model = NLEmbedding.sentenceEmbedding(for: language), let vector = model.vector(for: text) else {
    FileHandle.standardError.write(Data("no installed sentence embedding or no embedding for this input\n".utf8))
    exit(1)
}
FileHandle.standardOutput.write(try JSONEncoder().encode(vector))
