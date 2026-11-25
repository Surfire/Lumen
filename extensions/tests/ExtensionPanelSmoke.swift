import Foundation

@main
struct ExtensionPanelSmoke {
    @MainActor
    static func main() async throws {
        _ = LumenExtensionPanel()
        let package = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let model = LumenExtensionPanelModel()
        expect(model.package == nil && model.catalog == nil && model.outcome == nil, "idle on creation")

        await model.load(package)
        expect(model.catalog?.commands.map(\.name) == ["show-ready", "format-note", "copy-markdown-link"],
               "listed example commands")
        expect(model.outcome == nil && model.canRun, "listing selects without executing")

        await model.runSelection()
        expectHUD(model, "Lumen Search Notes is ready.")
        await checkClipboardPreview(model)

        model.select("format-note")
        expect(model.outcome == nil && !model.canRun, "clear HUD and require arguments on selection")
        model.setArgument("topic", value: "索引")
        expect(!model.canRun, "keep Run disabled while a required value is missing")
        model.setArgument("message", value: String(repeating: "界", count: 400))
        expect(!model.canRun, "reject oversized UTF-8 before launching")
        model.setArgument("message", value: "a\0b")
        expect(!model.canRun, "reject NUL in process arguments")
        let text = #"本地 📝 = "$HOME"; $(printf ignored)"#
        model.setArgument("message", value: text)
        expect(model.canRun, "allow ready text-only command")
        await model.runSelection()
        expectHUD(model, "[索引] " + text)

        let command = package.appendingPathComponent("src/format-note.js")
        let original = try String(contentsOf: command, encoding: .utf8)
        try Data(original.replacingOccurrences(of: "] ", with: "] updated: ").utf8).write(to: command)
        await model.runSelection()
        if case .failure(.run, .snapshotChanged) = model.outcome {
            expect(model.catalog == nil && !model.canRun, "clear stale commands until explicitly refreshed")
        } else {
            fail("reject valid replacement source through the snapshot check")
        }

        await model.load(package)
        model.select("format-note")
        model.setArgument("topic", value: "索引")
        model.setArgument("message", value: text)
        await model.runSelection()
        expectHUD(model, "[索引] updated: " + text)

        let repeatedArgument = Array(repeating: "props.arguments.message", count: 5).joined(separator: " + ")
        let oversized = """
        import { showHUD } from "@raycast/api";
        export default async function Command(props) {
            await showHUD(\(repeatedArgument));
        }
        """
        try Data(oversized.utf8).write(to: command)
        await model.load(package)
        model.select("format-note")
        model.setArgument("topic", value: "Index")
        model.setArgument("message", value: String(repeating: "a", count: 1_000))
        await model.runSelection()
        if case .failure(.run, .process(let message)) = model.outcome {
            expect(message.contains("HUD exceeds"), "show the host's command rejection")
        } else {
            fail("classify command failure separately from HUD")
        }

        try Data("invalid synthetic command".utf8).write(to: command)
        await model.load(package)
        expect(model.outcome == nil && model.canRun, "allow sibling command after reload")
        model.select("format-note")
        expect(model.selectedCommand?.unsupportedReason?.contains("validate src/format-note.js") == true,
               "decode and retain the host's unsupported reason")
        expect(!model.canRun, "disable Run for unsupported commands")
        await model.runSelection()
        expect(model.outcome == nil, "do not run unsupported commands")

        try Data("invalid synthetic manifest".utf8).write(to: package.appendingPathComponent("package.json"))
        await model.load(package)
        if case .failure(.list, .process(let message)) = model.outcome {
            expect(message.contains("parse package.json"), "show the host's manifest rejection")
        } else {
            fail("classify package failure separately from command failure")
        }
        expect(model.catalog == nil && !model.canRun, "clear the catalog after package failure")
        print("PASS: bundle helper lookup, UTF-8 HUD, confirmed clipboard preview, stale snapshot recovery, and separate errors")
    }

    @MainActor
    private static func checkClipboardPreview(_ model: LumenExtensionPanelModel) async {
        model.select("copy-markdown-link")
        model.confirmCopy { _ in fail("no clipboard action before a preview exists") }
        model.setArgument("title", value: " 笔记 [v2] ")
        model.setArgument("url", value: " https://example.test/本地 文件(v2) ")
        await model.runSelection()

        let expected = #"[笔记 \[v2\]](<https://example.test/本地%20文件(v2)>)"#
        if case .clipboardPreview(let text, false) = model.outcome {
            expect(text == expected, "show the generated Markdown link before confirmation")
        } else {
            fail("return a pending preview rather than a copied state")
        }

        model.confirmCopy { text in
            expect(text == expected, "pass the complete preview text to the writer")
            return false
        }
        if case .clipboardPreview(let text, true) = model.outcome {
            expect(text == expected, "preserve preview for retry after a write failure")
        } else {
            fail("show copy failure separately from extension failure")
        }

        var copiedText: String?
        model.confirmCopy { text in
            copiedText = text
            return true
        }
        expect(copiedText == expected, "write only the confirmed preview")
        if case .clipboardCopied = model.outcome {} else { fail("show successful copy") }
        model.confirmCopy { _ in fail("do not reuse a consumed clipboard preview") }
    }

    @MainActor
    private static func expectHUD(_ model: LumenExtensionPanelModel, _ expected: String) {
        if case .hud(let message) = model.outcome, message == expected { return }
        fail("display expected HUD text")
    }

    private static func expect(_ condition: Bool, _ name: String) {
        if !condition { fail(name) }
    }

    private static func fail(_ name: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
        exit(1)
    }
}
