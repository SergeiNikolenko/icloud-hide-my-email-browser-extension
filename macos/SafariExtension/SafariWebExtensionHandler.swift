import Foundation
import SafariServices

/// Receives the icloud.com cookies from background.js and leaves them in the
/// app group container, where the app picks them up.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        if let message = item?.userInfo?[SFExtensionMessageKey],
           JSONSerialization.isValidJSONObject(message),
           let data = try? JSONSerialization.data(withJSONObject: message),
           let directory = FileManager.default
               .containerURL(forSecurityApplicationGroupIdentifier: "XNPNVQSG77.com.nikolenko.HideMyEmail") {
            try? data.write(to: directory.appendingPathComponent("SafariSession.json"), options: .atomic)
        }
        context.completeRequest(returningItems: nil)
    }
}
