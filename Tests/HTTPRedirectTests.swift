import Foundation

func runHTTPRedirectTests() {
    let original = URL(string: "https://mcp.example.com/mcp")!
    let configured = ["X-Api-Key": "KEY456", "Authorization": "Bearer configured"]

    func redirect(to target: String) -> URLRequest {
        var request = URLRequest(url: URL(string: target)!)
        request.setValue("KEY456", forHTTPHeaderField: "X-Api-Key")
        request.setValue("Bearer configured", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    test("http redirect: same origin keeps configured headers") {
        let followed = HTTPExchange.guardedRedirect(redirect(to: "https://MCP.example.com:443/mcp/"),
                                                    from: original, configuredHeaders: configured)
        expectEqual(followed?.value(forHTTPHeaderField: "X-Api-Key"), "KEY456")
        expectEqual(followed?.value(forHTTPHeaderField: "Authorization"), "Bearer configured")
    }

    test("http redirect: another origin drops configured headers and Authorization") {
        let followed = HTTPExchange.guardedRedirect(redirect(to: "https://elsewhere.example.net/mcp"),
                                                    from: original, configuredHeaders: configured)
        expectEqual(followed?.url?.host, "elsewhere.example.net")
        expectEqual(followed?.value(forHTTPHeaderField: "X-Api-Key"), nil)
        expectEqual(followed?.value(forHTTPHeaderField: "Authorization"), nil)
        expectEqual(followed?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    test("http redirect: another port on the same host counts as another origin") {
        let followed = HTTPExchange.guardedRedirect(redirect(to: "https://mcp.example.com:8443/mcp"),
                                                    from: original, configuredHeaders: configured)
        expectEqual(followed?.value(forHTTPHeaderField: "X-Api-Key"), nil)
    }

    test("http redirect: https to http is refused") {
        let followed = HTTPExchange.guardedRedirect(redirect(to: "http://mcp.example.com/mcp"),
                                                    from: original, configuredHeaders: configured)
        expectTrue(followed == nil, "a downgrade to plain HTTP must not be followed")
    }
}
