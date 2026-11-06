import Foundation
import Testing
@testable import HideMyEmailCore

@Suite struct SitesTests {
    @Test(arguments: [
        ("accounts.google.com", "google.com"),
        ("www.bbc.co.uk", "bbc.co.uk"),
        ("shop.example.com.au", "example.com.au"),
        ("github.com", "github.com"),
        ("my-app.vercel.app", "my-app.vercel.app"),
        ("192.168.1.10", "192.168.1.10"),
    ])
    func registrableDomain(host: String, expected: String) {
        #expect(Sites.registrableDomain(host) == expected)
    }

    @Test func ignoresNonWebURLs() {
        #expect(Sites.registrableDomain(of: URL(string: "app://-/index.html")!) == nil)
        #expect(Sites.registrableDomain(of: URL(string: "https://login.figma.com/signup")!) == "figma.com")
    }

    @Test func matchesAddressesByLabelOrDomain() {
        let addresses = [
            HMEAddress(anonymousId: "1", hme: "a@icloud.com", label: "www.figma.com"),
            HMEAddress(anonymousId: "2", hme: "b@icloud.com", label: "Figma work", domain: "figma.com"),
            HMEAddress(anonymousId: "3", hme: "c@icloud.com", label: "notfigma.com"),
            HMEAddress(anonymousId: "4", hme: "d@icloud.com", label: "Newsletter"),
        ]
        #expect(Sites.addresses(addresses, for: "help.figma.com").map(\.id) == ["1", "2"])
    }
}

@Suite struct SiteIconTests {
    @Test func prefersTouchIconsThenLargestIcon() {
        let html = """
        <head><link rel="icon" href="/small.png" sizes="16x16">
        <LINK REL='shortcut icon' href='https://cdn.example.com/big.png' sizes='64x64'/>
        <link rel="mask-icon" href="/mask.svg"><link rel="stylesheet" href="/a.css">
        <link href="touch.png" rel="apple-touch-icon"></head>
        """
        let urls = SiteIcon.candidates(in: html, base: URL(string: "https://www.example.com/en/")!)
        #expect(urls.map(\.absoluteString) == [
            "https://www.example.com/en/touch.png",
            "https://cdn.example.com/big.png",
            "https://www.example.com/small.png",
            "https://www.example.com/favicon.ico",
        ])
    }
}

@Suite struct SignInTests {
    @Test func recognizesSignInForms() {
        let apple = FieldDescriptor(role: "AXTextField", roleDescription: "email", placeholder: "Email or Phone Number")
        #expect(EmailField.isSignIn(apple, pageTitle: "Sign in to your Apple Account", url: nil))
        let oracle = FieldDescriptor(role: "AXTextField", title: "Username or email")
        #expect(EmailField.isSignIn(oracle, pageTitle: nil, url: URL(string: "https://login.oracle.com/mysso")))
        let byPath = FieldDescriptor(role: "AXTextField", roleDescription: "email", title: "Email")
        #expect(EmailField.isSignIn(byPath, pageTitle: "Acme", url: URL(string: "https://acme.com/login")))
    }

    @Test func keepsSignUpAndPlainEmailForms() {
        let email = FieldDescriptor(role: "AXTextField", roleDescription: "email", title: "Email")
        #expect(!EmailField.isSignIn(email, pageTitle: "Create your account", url: URL(string: "https://acme.com/signup")))
        #expect(!EmailField.isSignIn(email, pageTitle: "Checkout", url: URL(string: "https://shop.com/checkout")))
        #expect(!EmailField.isSignIn(email, pageTitle: "Sign up or log in", url: nil))
    }
}

@Suite struct EmailFieldTests {
    @Test func chromiumEmailInput() {
        #expect(EmailField.isEmailField(FieldDescriptor(role: "AXTextField", roleDescription: "email")))
    }

    @Test func firefoxEmailInputByIdentifierOrLabel() {
        #expect(EmailField.isEmailField(FieldDescriptor(role: "AXTextField", roleDescription: "text field",
                                                        identifier: "email")))
        #expect(EmailField.isEmailField(FieldDescriptor(role: "AXTextField", title: "Work email")))
        #expect(EmailField.isEmailField(FieldDescriptor(role: "AXTextField", title: "Электронная почта")))
        #expect(EmailField.isEmailField(FieldDescriptor(role: "AXTextField", placeholder: "you@example.com")))
    }

    @Test func rejectsOtherFields() {
        #expect(!EmailField.isEmailField(FieldDescriptor(role: "AXTextField", placeholder: "Username")))
        #expect(!EmailField.isEmailField(FieldDescriptor(role: "AXTextField", subrole: "AXSecureTextField",
                                                         title: "Email password")))
        #expect(!EmailField.isEmailField(FieldDescriptor(role: "AXTextField", title: "Email verification code")))
        #expect(!EmailField.isEmailField(FieldDescriptor(role: "AXButton", title: "Email")))
    }
}

@Suite struct CookieJarTests {
    @Test func sendsMatchingCookiesOnly() {
        let jar = CookieJar(cookies: [
            StoredCookie(name: "X-APPLE-WEBAUTH-TOKEN", value: "t", domain: ".icloud.com"),
            StoredCookie(name: "other", value: "x", domain: ".apple.com"),
            StoredCookie(name: "old", value: "y", domain: ".icloud.com", expires: Date(timeIntervalSince1970: 0)),
        ])
        let header = jar.headerValue(for: URL(string: "https://p68-maildomainws.icloud.com/v1/hme/generate")!)
        #expect(header == "X-APPLE-WEBAUTH-TOKEN=t")
    }

    @Test func mergeReplacesAndDeletes() {
        var jar = CookieJar(cookies: [StoredCookie(name: "a", value: "1", domain: ".icloud.com")])
        jar.merge([StoredCookie(name: "a", value: "2", domain: ".icloud.com")])
        #expect(jar.cookies.map(\.value) == ["2"])
        jar.merge([StoredCookie(name: "a", value: "", domain: ".icloud.com")])
        #expect(jar.isEmpty)
    }
}

@Suite struct ExportTests {
    @Test func csvEscapesAndNeutralizesFormulas() {
        let address = HMEAddress(anonymousId: "1", hme: "a@icloud.com", label: "=HYPERLINK(\"x\")",
                                 note: "line, with comma", forwardToEmail: "me@icloud.com",
                                 createTimestamp: 0)
        let lines = Export.csv([address]).components(separatedBy: "\r\n")
        #expect(lines[0] == "Address,Label,Note,Forward To,Active,Created")
        #expect(lines[1] == "a@icloud.com,\"'=HYPERLINK(\"\"x\"\")\",\"line, with comma\",me@icloud.com,yes,1970-01-01T00:00:00Z")
    }
}

/// Serves canned iCloud responses so the client runs end to end without a network.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    let responses: [String: (Int, String, [String: String])]

    init(_ responses: [String: (Int, String, [String: String])]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = responses.keys.first { request.url!.path.hasSuffix($0) } ?? ""
        let (status, body, headers) = responses[key] ?? (404, "{}", [:])
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                 headerFields: headers)!)
    }
}

@Suite struct ICloudClientTests {
    // Real responses include services without a URL, such as schoolwork.
    static let validate = """
    {"webservices":{"premiummailsettings":{"url":"https://p1-maildomainws.icloud.com","status":"active"},
    "schoolwork":{"status":"active"}}}
    """

    @Test func generatesWithOriginHeadersAndRotatedCookies() async throws {
        let transport = FakeTransport([
            "/validate": (200, Self.validate, ["Set-Cookie": "X-APPLE-WEBAUTH-TOKEN=new; Domain=.icloud.com; Path=/; Secure"]),
            "/v1/hme/generate": (200, #"{"success":true,"result":{"hme":"quiet.fern@icloud.com"}}"#, [:]),
        ])
        let client = ICloudClient(region: .global,
                                  jar: CookieJar(cookies: [StoredCookie(name: "X-APPLE-WEBAUTH-TOKEN", value: "old",
                                                                        domain: ".icloud.com")]),
                                  transport: transport)
        #expect(try await client.generate() == "quiet.fern@icloud.com")
        let generate = transport.requests.last!
        #expect(generate.value(forHTTPHeaderField: "Origin") == "https://www.icloud.com")
        #expect(generate.value(forHTTPHeaderField: "Cookie") == "X-APPLE-WEBAUTH-TOKEN=new")
    }

    @Test func mapsSessionRejectionToSignedOut() async {
        let client = ICloudClient(region: .global, jar: CookieJar(), transport: FakeTransport([
            "/validate": (421, "{}", [:]),
        ]))
        await #expect(throws: ICloudError.signedOut) { try await client.validate() }
    }

    @Test func surfacesServerErrorMessage() async {
        let client = ICloudClient(region: .global, jar: CookieJar(), transport: FakeTransport([
            "/validate": (200, Self.validate, [:]),
            "/v1/hme/reserve": (200, #"{"success":false,"error":{"errorMessage":"Label is too long"}}"#, [:]),
        ]))
        await #expect(throws: ICloudError.server("Label is too long")) {
            _ = try await client.reserve(hme: "a@icloud.com", label: "x", note: nil)
        }
    }
}
