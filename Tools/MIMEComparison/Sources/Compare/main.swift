import Foundation
import MimeFoundation
for path in CommandLine.arguments.dropFirst() {
    do {
        let message = try MimeMessage.load(MemoryStream(Array(Data(contentsOf: URL(fileURLWithPath: path))), writable: false))
        let value: [String: Any] = [
            "fixture": URL(fileURLWithPath: path).lastPathComponent, "body": message.textBody ?? message.htmlBody ?? "",
            "headers": message.headers.map { [$0.field, $0.value] },
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    } catch { print("error: \(URL(fileURLWithPath: path).lastPathComponent)") }
}
