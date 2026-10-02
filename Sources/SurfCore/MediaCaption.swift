import Foundation

/// The second line of a now-playing row: where it came from, and how far in.
///
/// Its own function because the rule that matters is a negative one, and
/// negative rules are the ones that come back. Both lines of the row fall back
/// through the same candidates, so a video with no artist and no host printed
/// the tab's title on top and the tab's title again underneath — and once a
/// time was added beside it, the row read as the title, then the title.
public enum MediaCaption {

    /// `artist · 2:14 / 10:03`, or whichever parts actually say something.
    ///
    /// `title` is what the row is already showing on its first line. Anything
    /// equal to it is dropped rather than repeated: a caption's whole job is
    /// to add, and a line that agrees with the one above it is noise wearing
    /// the shape of information.
    ///
    /// Empty when there is nothing left to say, so the caller can leave the
    /// line out rather than reserve space for it.
    public static func text(
        besides title: String,
        artist: String,
        host: String?,
        position: String?
    ) -> String {
        let source: String? = {
            let trimmedArtist = artist.trimmingCharacters(in: .whitespaces)
            if !trimmedArtist.isEmpty { return trimmedArtist }
            let trimmedHost = host?.trimmingCharacters(in: .whitespaces)
            return (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        }()

        let kept = [source, position]
            .compactMap { $0 }
            .filter { $0.caseInsensitiveCompare(title) != .orderedSame }

        return kept.joined(separator: " · ")
    }
}
