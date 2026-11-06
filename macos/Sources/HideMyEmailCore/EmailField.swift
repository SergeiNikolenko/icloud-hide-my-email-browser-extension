import Foundation

/// The accessibility attributes of a focused text field that hint at its purpose.
public struct FieldDescriptor: Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var roleDescription: String?
    public var identifier: String?
    public var title: String?
    public var placeholder: String?
    public var label: String?
    public var help: String?
    public var value: String?

    public init(role: String, subrole: String? = nil, roleDescription: String? = nil, identifier: String? = nil,
                title: String? = nil, placeholder: String? = nil, label: String? = nil, help: String? = nil,
                value: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.identifier = identifier
        self.title = title
        self.placeholder = placeholder
        self.label = label
        self.help = help
        self.value = value
    }
}

public enum EmailField {
    static let keywords = [
        "email", "e-mail", "e_mail", "mail address", "почт", "邮箱", "電子郵件", "メール",
        "correo", "courriel", "e-posta", "eposta",
    ]
    static let negativeKeywords = ["password", "пароль", "search", "поиск", "subject", "тема", "code", "код"]

    /// Whether a focused field asks for an email address. Chromium exposes
    /// `type=email` as the role description; other browsers only expose the
    /// field's id, label and placeholder, so those are checked too.
    public static func isEmailField(_ field: FieldDescriptor) -> Bool {
        guard ["AXTextField", "AXComboBox"].contains(field.role), field.subrole != "AXSecureTextField" else {
            return false
        }
        if field.roleDescription?.lowercased() == "email" { return true }

        let hints = [field.identifier, field.title, field.placeholder, field.label, field.help]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        if hints.contains(where: { hint in negativeKeywords.contains { hint.contains($0) } }) { return false }
        if hints.contains(where: { hint in keywords.contains { hint.contains($0) } }) { return true }
        // Placeholders such as "you@example.com".
        return field.placeholder.map { $0.range(of: #"\S+@\S+\.\S+"#, options: .regularExpression) != nil } ?? false
    }
}
