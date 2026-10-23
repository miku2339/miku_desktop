import AppKit
import Darwin
import Foundation

@main
enum MikuDesktopMain {
    @MainActor
    static func main() {
        if Array(CommandLine.arguments.dropFirst()) == ["--configure-tts-token-stdin"] {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            var token = String(data: data, encoding: .utf8) ?? ""
            while token.last == "\n" || token.last == "\r" {
                token.removeLast()
            }
            do {
                try MikuSpeech.shared.storeAccessToken(token)
                FileHandle.standardOutput.write(Data("TTS_TOKEN_CONFIGURED\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("TTS_TOKEN_CONFIGURATION_FAILED\n".utf8))
                exit(EXIT_FAILURE)
            }
            return
        }
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.run()
    }
}
