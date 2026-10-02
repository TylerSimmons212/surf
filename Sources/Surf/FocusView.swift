import SurfCore
import SwiftUI

/// The reader: Focus Mode's overlay for one tab.
///
/// Rendered natively over the live web view rather than by re-styling the
/// page — the whole point of Focus. The web view stays mounted underneath, so
/// leaving is a fade rather than a reload, and playback and scroll state
/// survive the round trip.
struct FocusOverlay: View {
    let tab: Tab

    var body: some View {
        ZStack {
            // Opaque, deliberately: the page underneath is exactly what the
            // reader exists to quiet down. Except for the video stage, where
            // the page underneath *is* the show — and for a site lens, which
            // owns its own ground because it is opaque on two of its three
            // screens and transparent on the third.
            if !tab.focusVideoStage, tab.siteLens == nil {
                Color(nsColor: .textBackgroundColor)
            }

            switch tab.focusPhase {
            case .inactive:
                EmptyView()

            case .extracting:
                ProgressView()
                    .controlSize(.large)

            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "text.page.slash")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.title3.weight(.medium))
                    Button("Back to the Page") { tab.exitFocus() }
                        .buttonStyle(.glassProminent)
                }
                .padding(40)

            case .active:
                // A site lens first: it is chosen by address rather than by
                // classification, and on a site Surf knows it is always the
                // better answer than what extraction would have made.
                if let lens = tab.youtubeLens {
                    YouTubeLensView(tab: tab, lens: lens)
                } else if let lens = tab.amazonLens {
                    AmazonLensView(tab: tab, lens: lens)
                } else
                // Theater mode: the page's own video is the stage, so the
                // overlay must be transparent chrome, not a reader.
                if tab.focusVideoStage {
                    VideoLensView(tab: tab)
                } else
                // The recipe lens is the default face of a recipe page; the
                // article lens stays one toggle away, because a recipe page
                // still has prose someone may actually want.
                if let recipe = tab.focusRecipe, !tab.focusPrefersArticle {
                    RecipeLensView(tab: tab, recipe: recipe)
                } else if let article = tab.focusArticle {
                    ArticleLensView(tab: tab, article: article)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// The article lens: extracted blocks, set in real typography.
struct ArticleLensView: View {
    let tab: Tab
    let article: FocusArticle

    /// Body size in points. One preference for every article — comfortable
    /// type is a property of the eyes, not of the page.
    @AppStorage(PreferenceKeys.focusFontSize) private var fontSize = 18.0

    /// Which block sits at the top of the viewport, kept fresh by the scroll
    /// position API. This is what leaving Focus hands to `focus.reveal`, so
    /// the page lands on the passage being read.
    @State private var scroll = ScrollPosition(idType: Int.self)

    /// The passage under the pointer, carrying the read-from-here affordance.
    @State private var hoveredBlockID: Int?

    private static let sizeRange = 14.0...26.0

    private var narrator: Narrator { tab.narrator }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    // Identified so the scroll position has an answer at the
                    // very top; exiting from here reveals the first block.
                    .id(-1)
                ForEach(article.blocks) { block in
                    blockView(block)
                        .id(block.id)
                        .background {
                            // The whole passage glows while it has the voice
                            // and no finer range exists — a list read item by
                            // item, a caption. (Verbatim blocks get their
                            // lyric instead.) The hover wash underneath it is
                            // the read-from-here affordance.
                            if narrator.speakingBlockID == block.id,
                               narrator.speakingSentenceRange == nil {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.07))
                                    .padding(.horizontal, -10)
                            } else if hoveredBlockID == block.id, narrator.state != .idle {
                                // Only while a reading is underway: at rest
                                // the page is for reading with the eyes, and
                                // a seek affordance on every hover would
                                // dress it as a control panel.
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.045))
                                    .padding(.horizontal, -10)
                            }
                        }
                        // The affordance the hover promises: a play button in
                        // the gutter that moves the reading to this passage.
                        .overlay(alignment: .topLeading) {
                            if hoveredBlockID == block.id, narrator.state != .idle {
                                IconButton(
                                    systemName: "play.fill",
                                    size: 10, width: 22, height: 22, cornerRadius: 11,
                                    help: "Read from Here"
                                ) { narrator.read(article, fromBlock: block.id) }
                                .offset(x: -30)
                                .transition(.opacity)
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                hoveredBlockID = block.id
                            } else if hoveredBlockID == block.id {
                                hoveredBlockID = nil
                            }
                        }
                        // Seek by tapping the passage — only while already
                        // reading; `jump` guards idle so a stray tap can't
                        // start audio out of nowhere. Simultaneous rather
                        // than `.onTapGesture`: selectable text answers plain
                        // clicks itself, and the tap has to be heard through
                        // that, not instead of it.
                        .simultaneousGesture(TapGesture().onEnded {
                            narrator.jump(toBlock: block.id)
                        })
                        // The same deliberate action, one right-click away.
                        .contextMenu {
                            Button("Read from Here") {
                                narrator.read(article, fromBlock: block.id)
                            }
                        }
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 660)
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scroll, anchor: .top)
        .overlay(alignment: .topTrailing) { controls }
        .overlay(alignment: .bottom) { narrationBar }
        // Lyric mode: the passage being spoken keeps itself in the upper
        // third, so the eye follows the voice without a hand on the wheel.
        .onChange(of: narrator.speakingBlockID) { _, blockID in
            guard let blockID, blockID >= 0, narrator.state == .speaking else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                scroll.scrollTo(id: blockID, anchor: UnitPoint(x: 0, y: 0.22))
            }
        }
    }

    // MARK: - Chrome

    private var controls: some View {
        HStack(spacing: 8) {
            FocusShareLink(tab: tab, title: article.title)

            Divider().frame(height: 16)

            if tab.media?.hasVideo == true {
                IconButton(
                    systemName: "play.rectangle",
                    size: 12, width: 24, height: 24, cornerRadius: 7,
                    help: "Watch the Video in Theater"
                ) { tab.enterVideoStage() }

                Divider().frame(height: 16)
            }

            if tab.focusRecipe != nil {
                IconButton(
                    systemName: "fork.knife",
                    size: 12, width: 24, height: 24, cornerRadius: 7,
                    help: "Back to the Recipe"
                ) { tab.focusPrefersArticle = false }

                Divider().frame(height: 16)
            }

            IconButton(
                systemName: "textformat.size.smaller",
                size: 12, width: 24, height: 24, cornerRadius: 7,
                isEnabled: fontSize > Self.sizeRange.lowerBound,
                help: "Smaller Text"
            ) { fontSize = max(Self.sizeRange.lowerBound, fontSize - 1) }

            IconButton(
                systemName: "textformat.size.larger",
                size: 12, width: 24, height: 24, cornerRadius: 7,
                isEnabled: fontSize < Self.sizeRange.upperBound,
                help: "Larger Text"
            ) { fontSize = min(Self.sizeRange.upperBound, fontSize + 1) }

            Divider().frame(height: 16)

            IconButton(
                systemName: "xmark",
                size: 11, weight: .bold, width: 24, height: 24, cornerRadius: 7,
                help: "Leave Focus (⇧⌘F)"
            ) {
                // Mid-narration the voice's position beats the viewport's;
                // otherwise -1 is the header and the top is block 0.
                let top = narrator.speakingBlockID
                    ?? scroll.viewID(type: Int.self).map { max(0, $0) }
                tab.exitFocus(revealingBlock: top.map { max(0, $0) })
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(.top, 14)
        .padding(.trailing, 14)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !article.siteName.isEmpty || article.wordCount > 0 {
                Text(dekLine)
                    .font(Typeface.figtree(size: 12, weight: 500))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.6)
            }
            if !article.title.isEmpty {
                Text(article.title)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            if !article.byline.isEmpty {
                Text(article.byline)
                    .font(Typeface.figtree(size: 13, weight: 500))
                    .foregroundStyle(.secondary)
            }
            if !article.heroImage.isEmpty {
                remoteImage(article.heroImage, caption: "")
                    .padding(.top, 8)
            }
            Divider()
                .padding(.vertical, 12)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dekLine: String {
        var parts: [String] = []
        if !article.siteName.isEmpty { parts.append(article.siteName) }
        parts.append("\(article.readingMinutes) min read")
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: FocusBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(lyricText(block))
                .font(.system(size: fontSize, design: .serif))
                .lineSpacing(fontSize * 0.42)
                .textSelection(.enabled)
                .padding(.bottom, fontSize * 0.9)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading:
            Text(lyricText(block))
                .font(.system(size: headingSize(block.level ?? 2),
                              weight: .semibold, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.top, fontSize * 0.7)
                .padding(.bottom, fontSize * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote:
            Text(lyricText(block))
                .font(.system(size: fontSize, design: .serif))
                .italic()
                .lineSpacing(fontSize * 0.4)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                }
                .padding(.bottom, fontSize * 0.9)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code:
            // Its own horizontal scroller, so a long line never stretches the
            // reading column.
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(size: max(11, fontSize - 5), design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, fontSize * 0.9)

        case .list:
            VStack(alignment: .leading, spacing: fontSize * 0.35) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(block.ordered == true ? "\(index + 1)." : "•")
                            .font(.system(size: fontSize, design: .serif))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(item)
                            .font(.system(size: fontSize, design: .serif))
                            .lineSpacing(fontSize * 0.35)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.bottom, fontSize * 0.9)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .image:
            if let src = block.src {
                remoteImage(src, caption: block.caption ?? "")
                    .padding(.vertical, fontSize * 0.4)
            }
        }
    }

    // MARK: - Narration

    /// A block's text with the lyric lit in two grains: the sentence being
    /// spoken in a faint wash, the word — when the engine reports words —
    /// bright inside it. A voice with no word timings still shows a moving
    /// sentence rather than nothing.
    ///
    /// Built by concatenating slices rather than by converting index types
    /// in place: the engine's ranges are UTF-16 (that is what synthesisers
    /// count in), and `NSRange → Range<String.Index>` is the one conversion
    /// Foundation gets right on every emoji and ligature.
    private func lyricText(_ block: FocusBlock) -> AttributedString {
        guard narrator.speakingBlockID == block.id,
              let sentence = stringRange(narrator.speakingSentenceRange, in: block.text)
        else { return AttributedString(block.text) }

        let text = block.text
        var result = AttributedString()
        func append(_ range: Range<String.Index>, wash: Bool = false, bright: Bool = false) {
            guard !range.isEmpty else { return }
            var part = AttributedString(String(text[range]))
            if bright { part.backgroundColor = Color.accentColor.opacity(0.32) }
            else if wash { part.backgroundColor = Color.accentColor.opacity(0.10) }
            result += part
        }

        if let word = stringRange(narrator.speakingRange, in: text),
           sentence.lowerBound <= word.lowerBound, word.upperBound <= sentence.upperBound {
            append(text.startIndex..<sentence.lowerBound)
            append(sentence.lowerBound..<word.lowerBound, wash: true)
            append(word, bright: true)
            append(word.upperBound..<sentence.upperBound, wash: true)
            append(sentence.upperBound..<text.endIndex)
        } else {
            append(text.startIndex..<sentence.lowerBound)
            append(sentence, wash: true)
            append(sentence.upperBound..<text.endIndex)
        }
        return result
    }

    private func stringRange(_ utf16: Range<Int>?, in text: String) -> Range<String.Index>? {
        guard let utf16 else { return nil }
        return Range(
            NSRange(location: utf16.lowerBound, length: utf16.count), in: text
        )
    }

    /// The transport: a quiet "Listen" pill at rest, the full deck while
    /// reading. Bottom-centre, where every player on every platform puts it.
    @ViewBuilder
    private var narrationBar: some View {
        Group {
            if narrator.state == .idle {
                Button {
                    narrator.toggle(reading: article)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Listen")
                            .font(Typeface.figtree(size: 13, weight: 600))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    // The whole capsule is the button. Without this, a plain
                    // button style hit-tests the glyphs themselves, and the
                    // word "Listen" is mostly the gaps between its letters.
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Read this article aloud")
            } else {
                HStack(spacing: 8) {
                    IconButton(
                        systemName: "backward.fill",
                        size: 11, width: 26, height: 24, cornerRadius: 7,
                        isEnabled: narrator.utteranceIndex > 0,
                        help: "Previous Passage"
                    ) { narrator.skip(-1) }

                    if narrator.isPreparing {
                        // The voice is synthesising its first audio. Same
                        // footprint as the button it stands in for, so the
                        // deck doesn't shuffle when sound starts.
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 30, height: 26)
                    } else {
                        IconButton(
                            systemName: narrator.state == .speaking ? "pause.fill" : "play.fill",
                            size: 13, width: 30, height: 26, cornerRadius: 8,
                            help: narrator.state == .speaking ? "Pause" : "Resume"
                        ) { narrator.toggle(reading: article) }
                    }

                    IconButton(
                        systemName: "forward.fill",
                        size: 11, width: 26, height: 24, cornerRadius: 7,
                        help: "Next Passage"
                    ) { narrator.skip(1) }

                    Text(narrator.progressLabel)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52)

                    Divider().frame(height: 16)

                    Menu {
                        ForEach(Narrator.rateChoices, id: \.self) { choice in
                            Button {
                                narrator.rate = choice
                            } label: {
                                if narrator.rate == choice {
                                    Label(rateLabel(choice), systemImage: "checkmark")
                                } else {
                                    Text(rateLabel(choice))
                                }
                            }
                        }
                    } label: {
                        Text(rateLabel(narrator.rate))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Reading Speed")

                    Divider().frame(height: 16)

                    IconButton(
                        systemName: "stop.fill",
                        size: 11, width: 26, height: 24, cornerRadius: 7,
                        help: "Stop Reading"
                    ) { narrator.stop() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        .glassEffect(
            .regular.interactive(),
            in: Capsule(style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: narrator.state)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded()
            ? "\(Int(rate))×"
            : String(format: "%g×", rate)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        // The article's own H1 is the title above; in-body headings step down
        // from just above the text size.
        switch level {
        case 1, 2: return fontSize + 7
        case 3: return fontSize + 4
        default: return fontSize + 2
        }
    }

    private func remoteImage(_ src: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: src)) { phase in
                switch phase {
                case .success(let image):
                    // Height-capped: a portrait photo at column width fills
                    // several screens of a page that exists for the text.
                    // Fitted, so the cap letterboxes nothing — a tall image
                    // just gets narrower.
                    image.resizable().scaledToFit()
                        .frame(maxHeight: 420, alignment: .leading)
                case .failure:
                    // A picture that won't load takes its space with it —
                    // a broken-image placeholder is chrome, not content.
                    EmptyView()
                default:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .frame(height: 200)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !caption.isEmpty {
                Text(caption)
                    .font(Typeface.figtree(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The native share sheet, for whichever lens is up. The page's address is
/// the thing shared — a reader-mode rendering is Surf's view of the page,
/// but the page is what a recipient can open.
struct FocusShareLink: View {
    let tab: Tab
    let title: String

    var body: some View {
        if let address = tab.currentURL, let url = URL(string: address) {
            ShareLink(item: url, subject: Text(title)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Share")
        }
    }
}

/// The quiet affordance: shows when the classifier is confident the page has
/// an article lens worth offering, and gets out of the way otherwise.
struct FocusPill: View {
    let tab: Tab

    var body: some View {
        Button {
            tab.enterFocus()
        } label: {
            HStack(spacing: 6) {
                // The pill says which lens it's offering: a recipe page gets
                // the fork and a video page the screen, not a promise of prose.
                // A site lens says the site, because "Focus" on youtube.com
                // promises a reader and delivers something else entirely.
                if let site = tab.focusOfferSite {
                    SiteMark(site: site, height: 13)
                    // A wordmark already says the name. Setting the label
                    // beside it would print "amazon Amazon".
                    if SiteMarkArt.kind(for: site) == .glyph {
                        Text(site.displayName)
                            .font(Typeface.figtree(size: 12, weight: 600))
                    }
                } else {
                    Image(systemName: pillIcon)
                        .font(.system(size: 11, weight: .semibold))
                    Text("Focus")
                        .font(Typeface.figtree(size: 12, weight: 600))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // The whole capsule is the button. A plain button style hit-tests
            // the glyphs themselves, and padding isn't glyphs.
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: Capsule(style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .help("Enter Focus (⇧⌘F)")
    }

    private var pillIcon: String {
        switch tab.focusOfferKind {
        case .recipe: return "fork.knife"
        case .video: return "play.rectangle"
        default: return "text.page"
        }
    }
}
