import CoreGraphics
import Foundation

/// The element's geometry, in CSS pixels relative to the viewport.
public struct BoxModel: Sendable, Equatable {
    /// The border box — what `getBoundingClientRect` reports.
    public var frame: CGRect
    /// Top, right, bottom, left.
    public var margin: [CGFloat]
    public var border: [CGFloat]
    public var padding: [CGFloat]
    public var tagName: String

    public init(
        frame: CGRect,
        margin: [CGFloat] = [0, 0, 0, 0],
        border: [CGFloat] = [0, 0, 0, 0],
        padding: [CGFloat] = [0, 0, 0, 0],
        tagName: String = ""
    ) {
        self.frame = frame
        self.margin = margin
        self.border = border
        self.padding = padding
        self.tagName = tagName
    }

    /// The box the margin occupies, which is what a highlight shades.
    public var marginFrame: CGRect {
        frame.inset(by: margin.map { -$0 })
    }

    /// Inside the border and padding: the content itself.
    public var contentFrame: CGRect {
        frame
            .inset(by: border)
            .inset(by: padding)
    }

    public var paddingFrame: CGRect {
        frame.inset(by: border)
    }

    /// `320 × 48` — the label a highlight carries.
    public var sizeLabel: String {
        "\(Self.trim(frame.width)) × \(Self.trim(frame.height))"
    }

    private static func trim(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.2f", rounded)
    }
}

extension CGRect {
    /// Insets by top/right/bottom/left, the order CSS uses.
    func inset(by sides: [CGFloat]) -> CGRect {
        guard sides.count == 4 else { return self }
        return CGRect(
            x: minX + sides[3],
            y: minY + sides[0],
            width: max(0, width - sides[1] - sides[3]),
            height: max(0, height - sides[0] - sides[2])
        )
    }
}

public enum DOMWire {

    public static func decodeNode(_ value: Any?) -> DOMNode? {
        guard let dict = value as? [String: Any], let id = dict["id"] as? Int else { return nil }

        return DOMNode(
            id: id,
            nodeType: DOMNodeType(rawValue: dict["nodeType"] as? String ?? "") ?? .element,
            nodeName: dict["nodeName"] as? String ?? "",
            attributes: (dict["attributes"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                return DOMAttribute(name: name, value: entry["value"] as? String ?? "")
            },
            childCount: max(0, dict["childCount"] as? Int ?? 0),
            // Absent means "not sent", which is different from "none" — the
            // tree uses exactly that distinction to know what it still owes.
            childIds: (dict["children"] as? [[String: Any]]).map { $0.compactMap { $0["id"] as? Int } },
            value: dict["value"] as? String ?? "",
            layout: dict["layout"] as? String ?? ""
        )
    }

    public static func decodeLayoutOverlay(_ value: Any?) -> LayoutOverlay? {
        guard let dict = value as? [String: Any],
              let kind = LayoutOverlay.Kind(rawValue: dict["kind"] as? String ?? ""),
              let nodeId = dict["nodeId"] as? Int,
              let bounds = decodeRect(dict["bounds"])
        else { return nil }

        func spans(_ value: Any?) -> [LayoutOverlay.Span] {
            (value as? [[String: Any]] ?? []).compactMap { entry in
                guard let start = entry["start"] as? Double,
                      let end = entry["end"] as? Double
                else { return nil }
                return LayoutOverlay.Span(start: start, end: end)
            }
        }

        return LayoutOverlay(
            kind: kind,
            nodeId: nodeId,
            bounds: bounds,
            columns: spans(dict["columns"]),
            rows: spans(dict["rows"]),
            items: (dict["items"] as? [Any] ?? []).compactMap(decodeRect)
        )
    }

    static func decodeRect(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// A node and everything sent with it, flattened. The tree stores nodes by
    /// id, so nesting on the wire is just a way to save round trips.
    public static func decodeSubtree(_ value: Any?) -> [DOMNode] {
        guard let dict = value as? [String: Any], let node = decodeNode(dict) else { return [] }
        var out = [node]
        for child in dict["children"] as? [[String: Any]] ?? [] {
            out.append(contentsOf: decodeSubtree(child).map { child in
                var copy = child
                if copy.parentId == nil { copy.parentId = node.id }
                return copy
            })
        }
        return out
    }

    public static func decodeMutations(_ value: Any?) -> [DOMMutation] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? Int else { return nil }
            switch entry["kind"] as? String {
            case "attribute":
                guard let name = entry["name"] as? String else { return nil }
                return .attributeChanged(id: id, name: name, value: entry["value"] as? String)
            case "text":
                return .characterDataChanged(id: id, value: entry["value"] as? String ?? "")
            case "children":
                return .childrenChanged(id: id, childCount: max(0, entry["childCount"] as? Int ?? 0))
            case "removed":
                return .nodeRemoved(id: id)
            default:
                return nil
            }
        }
    }

    public static func decodeBox(_ value: Any?) -> BoxModel? {
        guard let dict = value as? [String: Any],
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double
        else { return nil }

        func sides(_ key: String) -> [CGFloat] {
            let raw = (dict[key] as? [Double]) ?? []
            return raw.count == 4 ? raw.map { CGFloat($0) } : [0, 0, 0, 0]
        }

        return BoxModel(
            frame: CGRect(x: x, y: y, width: width, height: height),
            margin: sides("margin"),
            border: sides("border"),
            padding: sides("padding"),
            tagName: dict["tagName"] as? String ?? ""
        )
    }
}
