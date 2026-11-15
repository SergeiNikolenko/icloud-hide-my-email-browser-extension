import Foundation
import SafariServices

/// Receives the icloud.com cookies from background.js and leaves them in the
/// app group container, where the app picks them up.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let reply = NSExtensionItem()
        var saved = false
        defer {
            reply.userInfo = [SFExtensionMessageKey: ["ok": saved]]
            context.completeRequest(returningItems: [reply])
        }
        let item = context.inputItems.first as? NSExtensionItem
        guard let message = item?.userInfo?[SFExtensionMessageKey],
              JSONSerialization.isValidJSONObject(message),
              let directory = FileManager.default
                  .containerURL(forSecurityApplicationGroupIdentifier: "XNPNVQSG77.com.nikolenko.HideMyEmail")
        else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            try data.write(to: directory.appendingPathComponent("SafariSession.json"), options: .atomic)
            saved = true
        } catch {
            saved = false
        }
    }
}
