import Foundation

/// Stand-ins for the scripts blocking removes.
///
/// Blocking a request is invisible to a page that never checks. A video player
/// is not that page: it loads Google's ad SDK, waits for `google.ima` to appear,
/// and hands the viewer to it. Refuse the script and the global never arrives,
/// so the player waits for a callback that cannot come — and the viewer, who
/// pressed play, watches nothing happen. The site is then free to call that an
/// ad blocker's fault, and often does.
///
/// A surrogate answers with a stub that behaves the way the real SDK behaves
/// when there are no ads to show: it exists, it accepts the request, and it
/// reports back that nothing is available. The player takes its own
/// no-ads path and plays the video, which is the outcome everyone involved
/// already has code for.
///
/// This is not a way of hiding that blocking happened. It is the difference
/// between a component that is absent and one that says it has nothing —
/// only the second is a state the player was written to survive.
public enum Surrogate: String, Sendable, CaseIterable {

    /// Google's Interactive Media Ads SDK: the video ad layer nearly every
    /// player on the web loads before it will play anything.
    case googleIMA

    /// Whether a script URL should be answered with a stub instead of blocked
    /// into silence.
    ///
    /// Matched on host *and* file, not on host alone. `imasdk.googleapis.com`
    /// serves more than the SDK, and standing in for something we haven't
    /// written a stand-in for would be worse than blocking it.
    public static func matching(_ url: String) -> Surrogate? {
        let lowered = url.lowercased()
        for surrogate in allCases where surrogate.matches(lowered) { return surrogate }
        return nil
    }

    func matches(_ loweredURL: String) -> Bool {
        switch self {
        case .googleIMA:
            return loweredURL.contains("imasdk.googleapis.com") && loweredURL.contains("ima3")
        }
    }

    /// The pattern the page-side interceptor tests, as a JavaScript regex body.
    var jsPattern: String {
        switch self {
        case .googleIMA: #"imasdk\.googleapis\.com\/.*ima3"#
        }
    }

    /// The stub itself.
    public var script: String {
        switch self {
        case .googleIMA: Self.googleIMAScript
        }
    }

    /// The interceptor's table, built from the cases above so the matching the
    /// page does and the matching Swift does can't drift apart.
    public static var javaScriptTable: String {
        let entries = allCases.map { surrogate in
            "{ pattern: /\(surrogate.jsPattern)/i, install: function () {\n\(surrogate.script)\n} }"
        }
        return "[\(entries.joined(separator: ",\n"))]"
    }

    /// A stub for Google IMA.
    ///
    /// Only the surface a player touches on the way to finding out there are no
    /// ads: build a container, build a loader, ask for ads, be told there are
    /// none. `requestAds` reports `AD_ERROR` asynchronously, because that is
    /// what the real SDK does when an ad request comes back empty and it is the
    /// path every player already handles — it is how they behave for viewers
    /// whose ad inventory simply didn't fill.
    ///
    /// Deliberately not a re-implementation. Anything a player calls that isn't
    /// here should do nothing rather than throw, so the last few lines make
    /// every unknown member a harmless no-op.
    static let googleIMAScript = """
    var win = window;
    if (win.google && win.google.ima && win.google.ima.__surf) { return; }

    var ima = {};

    function Emitter() { this._handlers = {}; }
    Emitter.prototype.addEventListener = function (type, handler) {
      (this._handlers[type] = this._handlers[type] || []).push(handler);
    };
    Emitter.prototype.removeEventListener = function (type, handler) {
      var list = this._handlers[type] || [];
      var index = list.indexOf(handler);
      if (index >= 0) { list.splice(index, 1); }
    };
    Emitter.prototype._emit = function (type, event) {
      var list = (this._handlers[type] || []).slice();
      for (var i = 0; i < list.length; i++) {
        try { list[i].call(this, event); } catch (error) { /* the player's problem */ }
      }
    };

    ima.AdDisplayContainer = function (container, video) {
      this.initialize = function () {};
      this.destroy = function () {};
      this.setClickThroughElement = function () {};
    };

    ima.AdError = function (message, code) {
      this.getErrorCode = function () { return code || 1009; };
      this.getVastErrorCode = function () { return 303; };
      this.getMessage = function () { return message || 'No ads available'; };
      this.getInnerError = function () { return null; };
      this.getType = function () { return 'adLoadError'; };
      this.toString = function () { return 'AdError ' + this.getMessage(); };
    };
    // 1009 is the SDK's own "no ads returned for this request", which is the
    // honest description of what happened and the code players special-case.
    ima.AdError.ErrorCode = { VAST_EMPTY_RESPONSE: 1009 };
    ima.AdError.Type = { AD_LOAD: 'adLoadError', AD_PLAY: 'adPlayError' };

    ima.AdErrorEvent = function (error) {
      this.type = 'adError';
      this.getError = function () { return error; };
      this.getUserRequestContext = function () { return {}; };
    };
    ima.AdErrorEvent.Type = { AD_ERROR: 'adError' };

    ima.AdEvent = function (type) { this.type = type; };
    ima.AdEvent.Type = {
      AD_BREAK_READY: 'adBreakReady', AD_BUFFERING: 'adBuffering',
      AD_CAN_PLAY: 'adCanPlay', AD_METADATA: 'adMetadata',
      AD_PROGRESS: 'adProgress', ALL_ADS_COMPLETED: 'allAdsCompleted',
      CLICK: 'click', COMPLETE: 'complete', CONTENT_PAUSE_REQUESTED: 'contentPauseRequested',
      CONTENT_RESUME_REQUESTED: 'contentResumeRequested', DURATION_CHANGE: 'durationChange',
      FIRST_QUARTILE: 'firstQuartile', IMPRESSION: 'impression',
      INTERACTION: 'interaction', LINEAR_CHANGED: 'linearChanged', LOADED: 'loaded',
      LOG: 'log', MIDPOINT: 'midpoint', PAUSED: 'pause', RESUMED: 'resume',
      SKIPPABLE_STATE_CHANGED: 'skippableStateChanged', SKIPPED: 'skip',
      STARTED: 'start', THIRD_QUARTILE: 'thirdQuartile', USER_CLOSE: 'userClose',
      VIDEO_CLICKED: 'videoClicked', VIDEO_ICON_CLICKED: 'videoIconClicked',
      VOLUME_CHANGED: 'volumeChange', VOLUME_MUTED: 'mute'
    };

    ima.AdsManagerLoadedEvent = function () { this.type = 'adsManagerLoaded'; };
    ima.AdsManagerLoadedEvent.Type = { ADS_MANAGER_LOADED: 'adsManagerLoaded' };

    ima.AdsLoader = function (container) {
      Emitter.call(this);
      var self = this;

      this.requestAds = function (request) {
        // Asynchronously, always. A player that registers its error handler on
        // the line after this one would otherwise never see the event, and
        // would wait for a callback that had already been and gone.
        setTimeout(function () {
          var event = new ima.AdErrorEvent(
            new ima.AdError('No ads available', ima.AdError.ErrorCode.VAST_EMPTY_RESPONSE)
          );
          self._emit('adError', event);
        }, 10);
      };

      this.getSettings = function () { return ima.settings; };
      this.getVersion = function () { return '3.677.0'; };
      this.contentComplete = function () {};
      this.destroy = function () {};
    };
    ima.AdsLoader.prototype = Object.create(Emitter.prototype);

    ima.AdsRequest = function () {
      this.setAdWillAutoPlay = function () {};
      this.setAdWillPlayMuted = function () {};
      this.setContinuousPlayback = function () {};
    };

    ima.AdsRenderingSettings = function () {};
    ima.AdsRenderingSettings.prototype = {};

    ima.CompanionAdSelectionSettings = function () {};
    ima.CompanionAdSelectionSettings.CreativeType = { ALL: 'All', FLASH: 'Flash', IMAGE: 'Image' };
    ima.CompanionAdSelectionSettings.ResourceType = { ALL: 'All', HTML: 'Html', STATIC: 'Static' };
    ima.CompanionAdSelectionSettings.SizeCriteria = {
      IGNORE: 'IgnoreSize', SELECT_EXACT_MATCH: 'SelectExactMatch',
      SELECT_NEAR_MATCH: 'SelectNearMatch'
    };

    ima.ImaSdkSettings = function () {
      this.setAutoPlayAdBreaks = function () {};
      this.setCookiesEnabled = function () {};
      this.setDisableCustomPlaybackForIOS10Plus = function () {};
      this.setLocale = function () {};
      this.setNumRedirects = function () {};
      this.setPlayerType = function () {};
      this.setPlayerVersion = function () {};
      this.setPpid = function () {};
      this.setVpaidAllowed = function () {};
      this.setVpaidMode = function () {};
      this.getPlayerType = function () { return 'surf'; };
      this.getPlayerVersion = function () { return '1.0'; };
    };
    ima.ImaSdkSettings.CompanionBackfillMode = { ALWAYS: 'always', ON_MASTER_AD: 'on_master_ad' };
    ima.ImaSdkSettings.VpaidMode = { DISABLED: 0, ENABLED: 1, INSECURE: 2 };
    ima.settings = new ima.ImaSdkSettings();

    ima.UiElements = { AD_ATTRIBUTION: 'adAttribution', COUNTDOWN: 'countdown' };
    ima.ViewMode = { FULLSCREEN: 'fullscreen', NORMAL: 'normal' };
    ima.VERSION = '3.677.0';
    ima.OmidVerificationVendor = { OTHER: 1 };

    ima.__surf = true;

    // Anything a player reaches for that isn't above answers as a no-op
    // constructor rather than throwing. A stub that breaks the page it was
    // meant to rescue is worse than no stub.
    var stubbed = new Proxy(ima, {
      get: function (target, name) {
        if (name in target) { return target[name]; }
        var noop = function () {};
        noop.prototype = {};
        return noop;
      }
    });

    win.google = win.google || {};
    win.google.ima = stubbed;
    """
}
