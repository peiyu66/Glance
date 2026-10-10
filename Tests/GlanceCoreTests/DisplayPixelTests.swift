import Testing
@testable import GlanceCore

@Test func denseEvidenceRejectsSmallChangedDetailDespiteMatchingOverallLayout() {
    let side=64
    var anchor=[Float](repeating:0.9,count:side*side*3)
    for y in 15..<49 { for x in 15..<49 { for c in 0..<3 { anchor[(y*side+x)*3+c]=0.2 } } }
    var changed=anchor
    for y in 31..<34 { for x in 31..<34 { for c in 0..<3 { changed[(y*side+x)*3+c]=0.85 } } }
    let evidence=DisplayPixelEvidence(current:.init(rgb:changed,side:side),reference:.init(rgb:anchor,side:side))
    #expect(evidence.globalDistance < 0.035)
    #expect(evidence.maximumLocalDifference > 0.5)
    #expect(!evidence.matches)
}
@Test func denseEvidenceAcceptsExactImageAndSmallUniformExposureButRejectsColorChange() {
    let rgb: [Float] = (0..<3072).map { index -> Float in
        let value = (index / 3) % 13
        return Float(value) / Float(20) + Float(0.1)
    }
    let anchor=SceneFingerprint(rgb:rgb,side:32)
    #expect(DisplayPixelEvidence(current:anchor,reference:anchor).matches)
    #expect(DisplayPixelEvidence(current:.init(rgb:rgb.map{$0+0.03},side:32),reference:anchor).matches)
    let color=rgb.enumerated().map { i,v in i%3==0 ? min(1,v+0.4) : v }
    #expect(!DisplayPixelEvidence(current:.init(rgb:color,side:32),reference:anchor).matches)
}
