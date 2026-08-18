import Foundation
import Testing
@testable import SurfCore

@Suite("Domain names")
struct BlockDomainsTests {

    // MARK: - Registrable domain

    @Test("A host reduces to the site it belongs to")
    func registrable() {
        #expect(DomainName.registrable("pagead2.googlesyndication.com") == "googlesyndication.com")
        #expect(DomainName.registrable("example.com") == "example.com")
        #expect(DomainName.registrable("a.b.c.example.com") == "example.com")
    }

    @Test("Registrations under a two-label suffix keep three labels")
    func multiLabelSuffix() {
        // The reason the table exists: bbc.co.uk is a site, co.uk is not.
        #expect(DomainName.registrable("www.bbc.co.uk") == "bbc.co.uk")
        #expect(DomainName.registrable("news.bbc.co.uk") == "bbc.co.uk")
        #expect(DomainName.registrable("shop.example.com.au") == "example.com.au")
    }

    @Test("Case and trailing dots are not part of a host")
    func normalization() {
        #expect(DomainName.registrable("WWW.Example.COM.") == "example.com")
    }

    @Test("An address is never truncated to its last two octets")
    func addresses() {
        // Reducing 192.168.1.10 to "1.10" would group unrelated hosts together
        // and produce a rule against a domain that doesn't exist.
        #expect(DomainName.registrable("192.168.1.10") == "192.168.1.10")
        #expect(DomainName.registrable("[2001:db8::1]") == "[2001:db8::1]")
    }

    // MARK: - Third party

    @Test("A site's own subdomains are not third parties")
    func firstPartySubdomains() {
        #expect(!DomainName.isThirdParty("static.example.com", from: "www.example.com"))
        #expect(!DomainName.isThirdParty("example.com", from: "example.com"))
    }

    @Test("Anyone else is")
    func thirdParties() {
        #expect(DomainName.isThirdParty("doubleclick.net", from: "example.com"))
        #expect(DomainName.isThirdParty("ads.example.co.uk", from: "example.com"))
    }

    // MARK: - Set matching

    @Test("A domain in the set covers everything under it")
    func subdomainCoverage() {
        let set: Set<String> = ["doubleclick.net"]
        #expect(DomainName.matches(host: "doubleclick.net", in: set))
        #expect(DomainName.matches(host: "stats.g.doubleclick.net", in: set))
        #expect(DomainName.coveringDomain(host: "stats.g.doubleclick.net", in: set)
                == "doubleclick.net")
    }

    @Test("A name that merely ends in one does not")
    func suffixIsNotSubdomain() {
        // `hasSuffix` would have said yes to this, and blocked a site nobody
        // wrote a rule about.
        #expect(!DomainName.matches(host: "notdoubleclick.net", in: ["doubleclick.net"]))
        #expect(!DomainName.matches(host: "doubleclick.net.example.com", in: ["example.net"]))
    }

    // MARK: - Hosts out of URLs

    @Test("The host is read out of a URL string")
    func hostExtraction() {
        #expect(DomainName.host(ofURL: "https://ads.example.com/a?b=c") == "ads.example.com")
        #expect(DomainName.host(ofURL: "http://example.com:8080/") == "example.com")
        #expect(DomainName.host(ofURL: "https://example.com") == "example.com")
    }

    @Test("Credentials in a URL are not part of the host")
    func credentials() {
        // The password may itself contain a colon, so the port is cut after the
        // credentials rather than before them.
        #expect(DomainName.host(ofURL: "https://user:pa:ss@example.com/x") == "example.com")
    }

    @Test("Something that isn't a URL has no host")
    func notAURL() {
        #expect(DomainName.host(ofURL: "data:image/png;base64,AAAA") == nil)
        #expect(DomainName.host(ofURL: "") == nil)
    }
}
