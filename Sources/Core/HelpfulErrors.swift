import Foundation

// Placeholder until T-04 lands the full catalogue; signatures are the contract.

extension MCPClientError {
    public var helpful: HelpfulError {
        HelpfulError(title: "Something went wrong", message: String(describing: self))
    }
}

extension HelpfulError {
    /// Any error the client can hit, including config errors from `MCPManagerError`.
    public init(_ error: Error) {
        if let client = error as? MCPClientError {
            self = client.helpful
        } else {
            self.init(title: "Something went wrong",
                      message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
