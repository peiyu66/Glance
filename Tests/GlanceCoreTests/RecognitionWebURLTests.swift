import Foundation
import Testing
@testable import GlanceCore

struct RecognitionWebURLTests {
    @Test func explicitWebAddressesPreserveSchemeHostAndPayload() throws {
        for raw in [
            "http://60.251.161.196/RegDegree/RegisterDegree.aspx",
            "https://example.com/path?x=1&y=two%20words#part",
            "http://[2001:db8::1]:8080/a",
            "HTTPS://example.com/a",
            "https://example.com/%E5%8F%B0%E7%81%A3"
        ] {
            let url = try #require(RecognitionWebURL.parse(raw))
            #expect(url.absoluteString == raw)
        }
    }

    @Test func nonWebAndAmbiguousPayloadsRemainText() {
        for raw in [
            "0012345678905", "0800-388-100", "example.com", "www.example.com",
            "javascript:alert(1)", "file:///tmp/example", "data:text/html,test",
            "mailto:test@example.com", "tel:0800388100", "glance-text-control://original",
            "//example.com", "https://", "https:///path", "https://.",
            " https://example.com", "https://example.com\n",
            "https://example.com/a b", "https://example.com/%ZZ",
            "https://name:password@example.com", "https://example.com:99999",
            "https://example.com\\@another.example", "https://example.com/\u{202E}abc",
            "https://example.com/<script>", "https://example.com/\"value\""
        ] {
            #expect(RecognitionWebURL.parse(raw) == nil, "\(raw)")
        }
    }

    @Test func unicodePathsAreEncodedForOpeningWithoutChangingDisplayedText() throws {
        let text = "https://example.com/臺灣"
        let url = try #require(RecognitionWebURL.parse(text))
        #expect(url.absoluteString == "https://example.com/%E8%87%BA%E7%81%A3")
        let match = try #require(RecognitionWebURL.matches(in: "原文：" + text).first)
        #expect(match.url == url)
        #expect((("原文：" + text) as NSString).substring(with: match.range) == text)
    }

    @Test func proseLinksKeepUnicodeRangesAndDoNotInferSchemes() {
        let http = "http://60.251.161.196/RegDegree/RegisterDegree.aspx"
        let https = "https://example.com/a?x=1&y=2#part"
        let text = "👩🏽‍🔬 台灣（\(http)）\n網址：\(https)\n0012345678905 0800-388-100 example.com test@example.com"
        let matches = RecognitionWebURL.matches(in: text)
        #expect(matches.map(\.url.absoluteString) == [http, https])
        #expect(matches.map { (text as NSString).substring(with: $0.range) } == [http, https])
    }

    @Test func embeddedNonWebSchemesCannotBecomeLinks() {
        for text in [
            "javascript:https://example.com", "file://https://example.com",
            "custom:https://example.com", "namehttps://example.com",
            "https://name:password@example.com", "https://example.com/%ZZ"
        ] {
            #expect(RecognitionWebURL.matches(in: text).isEmpty, "\(text)")
        }
    }

    @Test func parsingNeverRewritesRecognitionOrShareText() {
        let raw = "http://60.251.161.196/RegDegree/RegisterDegree.aspx"
        let result = RecognitionResult(names: ["網址測試"], summary: raw,
                                       text: [raw, "0012345678905"], barcodes: [raw, "0012345678905"])
        let before = result.shareText
        _ = RecognitionWebURL.matches(in: result.summary)
        _ = result.barcodes.map(RecognitionWebURL.parse)
        #expect(result.shareText == before)
        #expect(result.shareText.contains(raw))
        #expect(result.shareText.contains("0012345678905"))
        #expect(!result.shareText.contains("<a "))
    }
}
