import Foundation

/// The pure rules islands obey, kept away from WebKit so they can be tested.
///
/// Sibling of `TabSelection`: index arithmetic and validity checks live here,
/// the objects that act on them live in the app target.
public enum IslandLayout {

    /// Whether WebKit will accept this as a data store identifier.
    ///
    /// The all-zeros UUID is rejected because `WKWebsiteDataStore(forIdentifier:)`
    /// raises an Objective-C exception on it rather than returning nil — so an
    /// island created from a zeroed UUID wouldn't fail to isolate, it would
    /// terminate the app. `UUID()` never produces one, but a decoded session
    /// file is not something we generated, and neither is a value that survived
    /// a partial write.
    public static func isValidDataStoreIdentifier(_ identifier: UUID) -> Bool {
        identifier != zeroIdentifier
    }

    static let zeroIdentifier = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
