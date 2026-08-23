import Foundation

/// What the page says was under the pointer when a right-click happened.
///
/// Pushed by the page rather than asked for: WebKit builds its context menu in
/// the UI process, synchronously, while the DOM `contextmenu` event is
/// dispatched over in the web process. There is no round trip to be had at the
/// moment the menu is being built, so the answer has to already be in hand.
///
/// Every field is optional or empty-able because a right-click on bare page
/// background is the common case and carries none of them.
public struct ContextHit: Decodable, Equatable, Sendable {
    public var linkURL: String?
    public var linkText: String?
    public var imageURL: String?
    public var mediaURL: String?
    public var mediaIsVideo: Bool
    public var selection: String
    /// A text field, textarea or contenteditable. Surf's own items are
    /// withheld here — WebKit's stock editing menu is the right one.
    public var editable: Bool

    public init(
        linkURL: String? = nil,
        linkText: String? = nil,
        imageURL: String? = nil,
        mediaURL: String? = nil,
        mediaIsVideo: Bool = false,
        selection: String = "",
        editable: Bool = false
    ) {
        self.linkURL = linkURL
        self.linkText = linkText
        self.imageURL = imageURL
        self.mediaURL = mediaURL
        self.mediaIsVideo = mediaIsVideo
        self.selection = selection
        self.editable = editable
    }

    /// Nothing Surf would add an item for. A right-click on empty background
    /// still gets the page-wide items; this is about the targeted ones.
    public var isBare: Bool {
        linkURL == nil && imageURL == nil && mediaURL == nil && selection.isEmpty
    }

    /// For the log, so a run can be read without a debugger attached.
    public var summary: String {
        var parts: [String] = []
        if let linkURL { parts.append("link=\(linkURL)") }
        if let imageURL { parts.append("image=\(imageURL)") }
        if let mediaURL { parts.append("media=\(mediaURL)\(mediaIsVideo ? " (video)" : "")") }
        if !selection.isEmpty { parts.append("selection=\(selection.count) chars") }
        if editable { parts.append("editable") }
        return parts.isEmpty ? "bare" : parts.joined(separator: " ")
    }
}
