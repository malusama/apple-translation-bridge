import Foundation

@main
enum TranslationWorker {
    static func main() async { await run() }

    nonisolated static func run() async {
        let processor = TranslationProcessor()
        FileHandle.standardOutput.write(Data(#"{"ready":true,"engine":"Apple Translation","strategy":"lowLatency"}"#.utf8))
        FileHandle.standardOutput.write(Data([10]))
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                FileHandle.standardOutput.write(await processor.process(Data(line.utf8)))
                FileHandle.standardOutput.write(Data([10]))
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }
    }
}
