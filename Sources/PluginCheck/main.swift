import Foundation
import NookPluginSDK

// Uses the actual SDK validators. Never echo module payloads or returned values.
do {
    if CommandLine.arguments.contains("--manifest") {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        guard data.count <= 8192 else { throw ModuleProblem("Manifest exceeds its limit.") }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        print("OK")
    } else {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        var lines = PluginLines()
        let messages = try lines.append(data)
        guard data.last == 10, messages.count == 1 else { throw ModuleProblem("Expected one complete message.") }
        for message in messages {
            try message.snapshot?.validate()
            try message.bus?.registration?.validate()
            try message.bus?.update?.validate()
        }
        print("OK")
    }
} catch {
    FileHandle.standardError.write(Data("SDK validation failed. Check the manifest or message against the SDK contract.\n".utf8))
    exit(1)
}
