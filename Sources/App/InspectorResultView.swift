import AppKit
import SwiftUI

struct CallOutcomeView: View {
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch record.outcome {
            case let .result(result):
                ToolResultView(result: result, duration: record.duration)
            case let .failure(error):
                ErrorCallout(error: error)
                FieldMessage(text: "The call failed after \(formatDuration(record.duration)).", tone: .neutral)
            }
        }
    }
}

struct ToolResultView: View {
    let result: MCPToolResult
    let duration: Duration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if result.isError {
                    Chip(text: "Tool error", tone: .red)
                } else {
                    Chip(text: "Success", tone: .green)
                }
                Text("Took \(formatDuration(duration))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedStrong)
                Spacer()
            }
            if result.isError {
                Banner(title: "Tool error",
                       message: "The tool ran and reported this error itself. The connection is fine.", tone: .red)
            }
            if result.content.isEmpty, result.structuredContent == nil {
                FieldMessage(text: "The tool returned no content.", tone: .neutral)
            }
            ForEach(Array(result.content.enumerated()), id: \.offset) { _, content in
                ContentBlockView(content: content)
            }
            if let structured = result.structuredContent {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Structured content")
                    CodeBlock(text: structured.jsonString(pretty: true))
                }
            }
        }
    }
}

struct ContentBlockView: View {
    let content: MCPContent

    var body: some View {
        switch content {
        case let .text(text):
            TextContentView(text: text)
        case let .image(data, mimeType):
            ImageContentView(base64: data, mimeType: mimeType)
        case let .audio(data, mimeType):
            MediaCaption(kind: "Audio", mimeType: mimeType, bytes: decodedSize(data))
        case let .resourceLink(link):
            ResourceLinkView(link: link)
        case let .resource(contents):
            ResourceContentsView(contents: contents)
        case let .unknown(json):
            VStack(alignment: .leading, spacing: 4) {
                Chip(text: "Unknown content: \(json["type"]?.stringValue ?? "no type")")
                CodeBlock(text: json.jsonString(pretty: true))
            }
        }
    }
}

/// Base64 decodes to three bytes per four characters, less padding.
func decodedSize(_ base64: String) -> Int {
    let padding = base64.reversed().prefix { $0 == "=" }.count
    return max(0, base64.count / 4 * 3 - padding)
}

struct TextContentView: View {
    let text: String
    @State private var pretty = true

    /// Pretty-printed form when the text is a JSON object or array.
    private var prettyJSON: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let value = try? JSONValue.parse(trimmed) else { return nil }
        let formatted = value.jsonString(pretty: true)
        return formatted == text ? nil : formatted
    }

    var body: some View {
        let formatted = prettyJSON
        VStack(alignment: .leading, spacing: 4) {
            if formatted != nil {
                Toggle("Pretty-print JSON", isOn: $pretty)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            }
            CodeBlock(text: pretty ? (formatted ?? text) : text)
        }
    }
}

struct ImageContentView: View {
    let base64: String
    let mimeType: String

    var body: some View {
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        VStack(alignment: .leading, spacing: 4) {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(image.size.width, 480), maxHeight: 320, alignment: .leading)
                    .accessibilityLabel("Image returned by the tool")
                MediaCaption(kind: "Image", mimeType: mimeType, bytes: data.count,
                             extra: "\(Int(image.size.width)) × \(Int(image.size.height))")
            } else {
                MediaCaption(kind: "Image", mimeType: mimeType, bytes: decodedSize(base64))
                FieldMessage(text: "MCP Manager couldn't decode this image.", tone: .yellow)
            }
        }
    }
}

struct MediaCaption: View {
    let kind: String
    let mimeType: String?
    let bytes: Int
    var extra: String?

    var body: some View {
        HStack(spacing: 6) {
            Chip(text: kind)
            Text([mimeType ?? "unknown type", formatBytes(bytes), extra].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.mutedStrong)
                .textSelection(.enabled)
        }
    }
}

struct ResourceLinkView: View {
    let link: MCPResourceLink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Chip(text: "Resource link")
                if let name = link.title ?? link.name {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.heading)
                }
                if let mimeType = link.mimeType {
                    Text(mimeType).font(Theme.mono(11.5)).foregroundStyle(Theme.mutedStrong)
                }
            }
            Text(link.uri)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            if let description = link.description {
                FieldMessage(text: description, tone: .neutral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 10)
    }
}

struct ResourceContentsView: View {
    let contents: MCPResourceContents

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Chip(text: "Resource")
                Text(contents.uri)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let text = contents.text {
                if let mimeType = contents.mimeType {
                    Text(mimeType).font(Theme.mono(11.5)).foregroundStyle(Theme.mutedStrong)
                }
                TextContentView(text: text)
            } else if let blob = contents.blob {
                if contents.mimeType?.hasPrefix("image/") == true {
                    ImageContentView(base64: blob, mimeType: contents.mimeType ?? "image")
                } else {
                    MediaCaption(kind: "Binary", mimeType: contents.mimeType, bytes: decodedSize(blob))
                }
            } else {
                FieldMessage(text: "No text or data.", tone: .neutral)
            }
        }
    }
}
