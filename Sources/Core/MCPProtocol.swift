import Foundation

// MARK: JSON-RPC 2.0

public enum JSONRPCID: Hashable, Sendable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public init?(_ value: JSONValue) {
        switch value {
        case let .string(text): self = .string(text)
        default:
            guard let number = value.intValue else { return nil }
            self = .int(number)
        }
    }

    public var json: JSONValue {
        switch self {
        case let .int(number): return .int(number)
        case let .string(text): return .string(text)
        }
    }

    public var description: String {
        switch self {
        case let .int(number): return "#\(number)"
        case let .string(text): return "#\(text)"
        }
    }
}

public struct JSONRPCError: Error, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var json: JSONValue {
        var members: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { members["data"] = data }
        return .object(members)
    }
}

public struct JSONRPCDecodingError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

public enum JSONRPCMessage: Equatable, Sendable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONRPCID, result: JSONValue)
    /// `id` is nil when the server could not read the request's id.
    case errorResponse(id: JSONRPCID?, error: JSONRPCError)

    public var json: JSONValue {
        var members: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case let .request(id, method, params):
            members["id"] = id.json
            members["method"] = .string(method)
            if let params { members["params"] = params }
        case let .notification(method, params):
            members["method"] = .string(method)
            if let params { members["params"] = params }
        case let .response(id, result):
            members["id"] = id.json
            members["result"] = result
        case let .errorResponse(id, error):
            members["id"] = id?.json ?? .null
            members["error"] = error.json
        }
        return .object(members)
    }

    /// One line of JSON with no line breaks.
    public func encoded() -> Data { json.encoded() }

    public var method: String? {
        switch self {
        case let .request(_, method, _), let .notification(method, _): return method
        case .response, .errorResponse: return nil
        }
    }

    /// A single message or a batch array.
    public static func decode(_ data: Data) throws -> [JSONRPCMessage] {
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw JSONRPCDecodingError(description: "not JSON: \(error)")
        }
        return try decode(value)
    }

    public static func decode(_ value: JSONValue) throws -> [JSONRPCMessage] {
        if let items = value.arrayValue {
            guard !items.isEmpty else { throw JSONRPCDecodingError(description: "empty batch") }
            return try items.map(decodeOne)
        }
        return [try decodeOne(value)]
    }

    public static func decodeOne(_ value: JSONValue) throws -> JSONRPCMessage {
        guard let members = value.objectValue else {
            throw JSONRPCDecodingError(description: "expected a JSON object, got \(value.typeName)")
        }
        if let version = members["jsonrpc"], version != "2.0" {
            throw JSONRPCDecodingError(description: "jsonrpc is \(version.jsonString()), expected \"2.0\"")
        }
        let id = members["id"].flatMap(JSONRPCID.init)
        if let method = members["method"] {
            guard let name = method.stringValue else {
                throw JSONRPCDecodingError(description: "method is not a string")
            }
            let params = members["params"]
            if let id { return .request(id: id, method: name, params: params) }
            return .notification(method: name, params: params)
        }
        if let error = members["error"] {
            guard let code = error["code"]?.intValue else {
                throw JSONRPCDecodingError(description: "error has no integer code")
            }
            let message = error["message"]?.stringValue ?? ""
            return .errorResponse(id: id, error: JSONRPCError(code: code, message: message, data: error["data"]))
        }
        if let result = members["result"] {
            guard let id else { throw JSONRPCDecodingError(description: "result without an id") }
            return .response(id: id, result: result)
        }
        throw JSONRPCDecodingError(description: "neither a request, notification nor response")
    }
}

// MARK: MCP

public enum MCPProtocolVersion {
    /// The version MCP Manager asks for. Servers may answer with another one they support.
    public static let requested = "2025-06-18"
    public static let supported: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
}

public enum MCPClientIdentity {
    public static let name = "mcp-manager"
    public static let title = "MCP Manager"
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    public static var initializeParams: JSONValue {
        [
            "protocolVersion": .string(MCPProtocolVersion.requested),
            "capabilities": [:],
            "clientInfo": ["name": .string(name), "title": .string(title), "version": .string(version)],
        ]
    }
}

public struct MCPImplementation: Equatable, Sendable {
    public var name: String
    public var version: String
    public var title: String?

    public init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }
}

public struct MCPServerCapabilities: Equatable, Sendable {
    public var tools: Bool
    public var toolsListChanged: Bool
    public var resources: Bool
    public var resourcesSubscribe: Bool
    public var resourcesListChanged: Bool
    public var prompts: Bool
    public var promptsListChanged: Bool
    public var logging: Bool
    public var completions: Bool
    public var raw: JSONValue

    public init(_ raw: JSONValue) {
        self.raw = raw
        tools = raw["tools"] != nil
        toolsListChanged = raw["tools"]?["listChanged"]?.boolValue ?? false
        resources = raw["resources"] != nil
        resourcesSubscribe = raw["resources"]?["subscribe"]?.boolValue ?? false
        resourcesListChanged = raw["resources"]?["listChanged"]?.boolValue ?? false
        prompts = raw["prompts"] != nil
        promptsListChanged = raw["prompts"]?["listChanged"]?.boolValue ?? false
        logging = raw["logging"] != nil
        completions = raw["completions"] != nil
    }
}

public struct MCPInitializeResult: Equatable, Sendable {
    public var protocolVersion: String
    public var capabilities: MCPServerCapabilities
    public var serverInfo: MCPImplementation
    public var instructions: String?

    public init(protocolVersion: String, capabilities: MCPServerCapabilities, serverInfo: MCPImplementation,
                instructions: String? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }

    public static func decode(_ result: JSONValue) throws -> MCPInitializeResult {
        guard let version = result["protocolVersion"]?.stringValue else {
            throw MCPClientError.malformedResponse(method: "initialize", detail: "no protocolVersion")
        }
        let info = result["serverInfo"]
        return MCPInitializeResult(
            protocolVersion: version,
            capabilities: MCPServerCapabilities(result["capabilities"] ?? [:]),
            // Some servers omit serverInfo; the session still works without it.
            serverInfo: MCPImplementation(name: info?["name"]?.stringValue ?? "unnamed server",
                                          version: info?["version"]?.stringValue ?? "",
                                          title: info?["title"]?.stringValue),
            instructions: result["instructions"]?.stringValue
        )
    }
}

public struct MCPToolAnnotations: Equatable, Sendable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
                idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    init(_ json: JSONValue?) {
        self.init(title: json?["title"]?.stringValue, readOnlyHint: json?["readOnlyHint"]?.boolValue,
                  destructiveHint: json?["destructiveHint"]?.boolValue, idempotentHint: json?["idempotentHint"]?.boolValue,
                  openWorldHint: json?["openWorldHint"]?.boolValue)
    }
}

public struct MCPTool: Identifiable, Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: MCPToolAnnotations

    public var id: String { name }
    public var displayTitle: String { title ?? annotations.title ?? name }

    public init(name: String, title: String? = nil, description: String? = nil, inputSchema: JSONValue = ["type": "object"],
                outputSchema: JSONValue? = nil, annotations: MCPToolAnnotations = MCPToolAnnotations()) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }

    static func decode(_ json: JSONValue) throws -> MCPTool {
        guard let name = json["name"]?.stringValue else {
            throw MCPClientError.malformedResponse(method: "tools/list", detail: "a tool has no name")
        }
        return MCPTool(name: name, title: json["title"]?.stringValue, description: json["description"]?.stringValue,
                       inputSchema: json["inputSchema"] ?? ["type": "object"], outputSchema: json["outputSchema"],
                       annotations: MCPToolAnnotations(json["annotations"]))
    }
}

public struct MCPPage<Item: Equatable & Sendable>: Equatable, Sendable {
    public var items: [Item]
    public var nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// Reads `result[key]` with `decodeItem`, keeping the cursor only when it is a non-empty string.
    public static func decode(_ result: JSONValue, key: String, method: String,
                              _ decodeItem: (JSONValue) throws -> Item) throws -> MCPPage<Item> {
        guard let raw = result[key]?.arrayValue else {
            throw MCPClientError.malformedResponse(method: method, detail: "no \(key) array")
        }
        let cursor = result["nextCursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return MCPPage(items: try raw.map(decodeItem), nextCursor: cursor)
    }
}

public extension MCPTool {
    static func page(_ result: JSONValue) throws -> MCPPage<MCPTool> {
        try MCPPage.decode(result, key: "tools", method: "tools/list", MCPTool.decode)
    }
}

public struct MCPResourceLink: Equatable, Sendable {
    public var uri: String
    public var name: String?
    public var title: String?
    public var description: String?
    public var mimeType: String?

    public init(uri: String, name: String? = nil, title: String? = nil, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
    }
}

public struct MCPResourceContents: Equatable, Sendable {
    public var uri: String
    public var mimeType: String?
    public var text: String?
    /// Base64, as sent.
    public var blob: String?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }

    static func decode(_ json: JSONValue, method: String) throws -> MCPResourceContents {
        guard let uri = json["uri"]?.stringValue else {
            throw MCPClientError.malformedResponse(method: method, detail: "resource contents without a uri")
        }
        return MCPResourceContents(uri: uri, mimeType: json["mimeType"]?.stringValue, text: json["text"]?.stringValue,
                                   blob: json["blob"]?.stringValue)
    }
}

public enum MCPContent: Equatable, Sendable {
    case text(String)
    /// `data` is base64, as sent.
    case image(data: String, mimeType: String)
    case audio(data: String, mimeType: String)
    case resourceLink(MCPResourceLink)
    case resource(MCPResourceContents)
    /// A content type this client does not know, kept so it can still be shown as JSON.
    case unknown(JSONValue)

    public static func decode(_ json: JSONValue) -> MCPContent {
        switch json["type"]?.stringValue {
        case "text":
            if let text = json["text"]?.stringValue { return .text(text) }
        case "image":
            if let data = json["data"]?.stringValue {
                return .image(data: data, mimeType: json["mimeType"]?.stringValue ?? "image/png")
            }
        case "audio":
            if let data = json["data"]?.stringValue {
                return .audio(data: data, mimeType: json["mimeType"]?.stringValue ?? "audio/wav")
            }
        case "resource_link":
            if let uri = json["uri"]?.stringValue {
                return .resourceLink(MCPResourceLink(uri: uri, name: json["name"]?.stringValue,
                                                     title: json["title"]?.stringValue,
                                                     description: json["description"]?.stringValue,
                                                     mimeType: json["mimeType"]?.stringValue))
            }
        case "resource":
            if let resource = json["resource"], let contents = try? MCPResourceContents.decode(resource, method: "") {
                return .resource(contents)
            }
        default:
            break
        }
        return .unknown(json)
    }
}

public struct MCPToolResult: Equatable, Sendable {
    public var content: [MCPContent]
    public var structuredContent: JSONValue?
    /// The tool ran and reported a failure; protocol failures throw instead.
    public var isError: Bool

    public init(content: [MCPContent], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    public static func decode(_ result: JSONValue) throws -> MCPToolResult {
        // 2024-11-05 servers may answer with `toolResult` instead of `content`.
        if result["content"] == nil, let legacy = result["toolResult"] {
            return MCPToolResult(content: [.text(legacy.stringValue ?? legacy.jsonString(pretty: true))])
        }
        guard let content = result["content"]?.arrayValue else {
            throw MCPClientError.malformedResponse(method: "tools/call", detail: "no content array")
        }
        return MCPToolResult(content: content.map(MCPContent.decode), structuredContent: result["structuredContent"],
                             isError: result["isError"]?.boolValue ?? false)
    }
}

public struct MCPResource: Identifiable, Equatable, Sendable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int?

    public var id: String { uri }

    public init(uri: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil,
                size: Int? = nil) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
    }

    public static func page(_ result: JSONValue) throws -> MCPPage<MCPResource> {
        try MCPPage.decode(result, key: "resources", method: "resources/list") { json in
            guard let uri = json["uri"]?.stringValue else {
                throw MCPClientError.malformedResponse(method: "resources/list", detail: "a resource has no uri")
            }
            return MCPResource(uri: uri, name: json["name"]?.stringValue ?? uri, title: json["title"]?.stringValue,
                               description: json["description"]?.stringValue, mimeType: json["mimeType"]?.stringValue,
                               size: json["size"]?.intValue)
        }
    }

    public static func contents(_ result: JSONValue) throws -> [MCPResourceContents] {
        guard let items = result["contents"]?.arrayValue else {
            throw MCPClientError.malformedResponse(method: "resources/read", detail: "no contents array")
        }
        return try items.map { try MCPResourceContents.decode($0, method: "resources/read") }
    }
}

public struct MCPResourceTemplate: Identifiable, Equatable, Sendable {
    public var uriTemplate: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?

    public var id: String { uriTemplate }

    public init(uriTemplate: String, name: String, title: String? = nil, description: String? = nil, mimeType: String? = nil) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
    }

    public static func page(_ result: JSONValue) throws -> MCPPage<MCPResourceTemplate> {
        try MCPPage.decode(result, key: "resourceTemplates", method: "resources/templates/list") { json in
            guard let template = json["uriTemplate"]?.stringValue else {
                throw MCPClientError.malformedResponse(method: "resources/templates/list",
                                                       detail: "a template has no uriTemplate")
            }
            return MCPResourceTemplate(uriTemplate: template, name: json["name"]?.stringValue ?? template,
                                       title: json["title"]?.stringValue, description: json["description"]?.stringValue,
                                       mimeType: json["mimeType"]?.stringValue)
        }
    }
}

public struct MCPPromptArgument: Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var required: Bool

    public init(name: String, title: String? = nil, description: String? = nil, required: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }
}

public struct MCPPrompt: Identifiable, Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [MCPPromptArgument]

    public var id: String { name }
    public var displayTitle: String { title ?? name }

    public init(name: String, title: String? = nil, description: String? = nil, arguments: [MCPPromptArgument] = []) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }

    public static func page(_ result: JSONValue) throws -> MCPPage<MCPPrompt> {
        try MCPPage.decode(result, key: "prompts", method: "prompts/list") { json in
            guard let name = json["name"]?.stringValue else {
                throw MCPClientError.malformedResponse(method: "prompts/list", detail: "a prompt has no name")
            }
            let arguments = (json["arguments"]?.arrayValue ?? []).compactMap { argument -> MCPPromptArgument? in
                guard let argName = argument["name"]?.stringValue else { return nil }
                return MCPPromptArgument(name: argName, title: argument["title"]?.stringValue,
                                         description: argument["description"]?.stringValue,
                                         required: argument["required"]?.boolValue ?? false)
            }
            return MCPPrompt(name: name, title: json["title"]?.stringValue, description: json["description"]?.stringValue,
                             arguments: arguments)
        }
    }
}

public struct MCPPromptMessage: Equatable, Sendable {
    public var role: String
    public var content: MCPContent

    public init(role: String, content: MCPContent) {
        self.role = role
        self.content = content
    }
}

public struct MCPPromptResult: Equatable, Sendable {
    public var description: String?
    public var messages: [MCPPromptMessage]

    public init(description: String? = nil, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }

    public static func decode(_ result: JSONValue) throws -> MCPPromptResult {
        guard let messages = result["messages"]?.arrayValue else {
            throw MCPClientError.malformedResponse(method: "prompts/get", detail: "no messages array")
        }
        return MCPPromptResult(
            description: result["description"]?.stringValue,
            messages: messages.map { message in
                MCPPromptMessage(role: message["role"]?.stringValue ?? "unknown",
                                 content: MCPContent.decode(message["content"] ?? .null))
            }
        )
    }
}

/// From `notifications/progress` for a request that sent a progress token.
public struct MCPProgress: Equatable, Sendable {
    public var progress: Double
    public var total: Double?
    public var message: String?

    public init(progress: Double, total: Double? = nil, message: String? = nil) {
        self.progress = progress
        self.total = total
        self.message = message
    }

    /// 0…1 when the server sent a positive total.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(max(progress / total, 0), 1)
    }
}
