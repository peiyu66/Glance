import Foundation

/// Only hashes and case labels are compiled. The four private bodies remain external.
enum FixedTextTrialCatalog {
    static let build = "48"
    static let cases: [TextTrialCase] = [
        .init(sequence: 152, bodySHA256: "7f68d5b8719e1510c8fba516711b4d7caa3c98ac8264c8bc16986e6e4b370a24", byteCount: 16982),
        .init(sequence: 153, bodySHA256: "2ef6d70f7699b17d279caf86edea42e406205f62f52d5f1c91b0ea54ced01feb", byteCount: 15234),
        .init(sequence: 149, bodySHA256: "22c8a0182f9c7998318cd1339ae6e3305504799b550cf93b71e9b60e7870a171", byteCount: 11616),
        .init(sequence: 147, bodySHA256: "ff602de102070119471415aefa034c5b980e816d2263a95021d60d9ec4e3218d", byteCount: 18190),
    ]
}
