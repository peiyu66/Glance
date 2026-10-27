import Foundation
import Testing
@testable import GlanceCore

@Test func structuredSchemaValidNullsAndFullObjectHaveDistinctSafeDiagnostics() throws {
    // Legacy v11 objects remain parseable but cannot validate against the outbound v13 schema.
    let schema = CameraAnswerSchema.format["schema"] as! [String: Any]
    func validates(_ value: Any, _ schema: [String: Any]) -> Bool {
        if let options = schema["anyOf"] as? [[String: Any]] { return options.contains { validates(value, $0) } }
        if let choices = schema["enum"] as? [Any] {
            guard choices.contains(where: { String(describing: $0) == String(describing: value) }) else { return false }
        }
        switch schema["type"] as? String {
        case "null": return value is NSNull
        case "object":
            guard let object = value as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]],
                  Set(object.keys) == Set(schema["required"] as? [String] ?? []) else { return false }
            return object.allSatisfy { key, value in properties[key].map { validates(value, $0) } == true }
        case "array":
            guard let array = value as? [Any], array.count <= (schema["maxItems"] as? Int ?? Int.max),
                  let item = schema["items"] as? [String: Any] else { return false }
            return array.allSatisfy { validates($0, item) }
        case "string": return (value as? String).map { $0.unicodeScalars.count <= (schema["maxLength"] as? Int ?? Int.max) } ?? false
        case "boolean": return value is Bool
        case "integer": return value is Int
        default: return false
        }
    }
    for metadata: Any in [policyIdentity(), NSNull()] {
        let raw = try raw(metadata, version: 11)
        #expect(!validates(try JSONSerialization.jsonObject(with: Data(raw.utf8)), schema))
        let result = try CameraAnswer.parse(raw, expectingStructured: true)
        #expect(result.searchRestriction == nil)
        #expect(result.searchDiagnostic?.version == .expected11)
        #expect(result.searchDiagnostic?.reason == .null)
        #expect(result.searchDiagnostic?.missingRootFields.isEmpty == true)
        #expect(result.searchDiagnostic?.validationFailure == nil)
        #expect(result.searchDiagnostic?.identityOutcome == (metadata is NSNull ? .null : .decoded))
    }
}

@Test func structuredMissingNoneNullAndWrongTypesAreNotConflated() throws {
    let object = try JSONSerialization.jsonObject(with: Data(raw().utf8)) as! [String: Any]
    for field in ["schema_version", "search_identity", "search_block_reason", "summary"] {
        var incomplete = object; incomplete.removeValue(forKey: field)
        let result = try CameraAnswer.parse(String(decoding: JSONSerialization.data(withJSONObject: incomplete), as: UTF8.self), expectingStructured: true)
        #expect(result.searchRestriction == .invalidRestriction)
        #expect(result.searchDiagnostic?.missingRootFields.contains { $0.rawValue == field } == true)
    }
    for reason: Any in ["none", "null", "", false, 0, []] {
        let result = try answer(reason: reason)
        #expect(result.searchRestriction == .invalidRestriction && result.searchDiagnostic?.reason == .invalid)
    }
    for reason in ["sensitive", "conflict", "uncertain"] {
        let result = try answer(reason: reason)
        #expect(result.searchDiagnostic?.reason.rawValue == reason)
        #expect(result.searchIdentity == nil && result.searchQuery == nil && result.wikipediaTopics == nil)
    }
    var wrong = identity(); wrong["automatic_wikipedia"] = "private-user-value-do-not-save"
    let wrongResult = try answer(wrong)
    #expect(wrongResult.searchDiagnostic?.identityOutcome == .decodingFailed)
    #expect(wrongResult.searchDiagnostic?.decodingField == .automatic_wikipedia)
    let encoded = String(decoding: try JSONEncoder().encode(wrongResult.searchDiagnostic), as: UTF8.self)
    #expect(!encoded.contains("private-user-value") && !encoded.contains("樂事") && !encoded.contains("Lay"))
    var missingEntity = identity(); missingEntity.removeValue(forKey: "manufacturer")
    let missing = try answer(missingEntity)
    #expect(missing.searchRestriction == .invalidRestriction)
    #expect(missing.searchDiagnostic?.missingIdentityFields == [.manufacturer])
}

@Test func structuredSemanticRejectionKeepsDistinctReasonsWithoutRelaxingProtection() throws {
    let cases: [(String, Any, SearchIdentity.ValidationFailure)] = [
        ("brand", entity("樂事", ["address@example.test"]), .entityFields),
        ("manufacturer", entity("合成原廠", [], ["logo"]), .manufacturerBasis),
        ("google_keywords", ["無依據型號"], .keywordOrigin),
        ("wikipedia_candidates", [["topic": "別人姓名", "kind": "brand"]], .candidateRoleOrTopic)
    ]
    for (key, value, failure) in cases {
        var metadata = identity(); metadata[key] = value
        let result = try answer(metadata)
        if failure == .keywordOrigin {
            #expect(result.searchRestriction == nil && result.wikipediaCandidateStatus == .modelProvided)
            #expect(result.searchIdentity != nil && result.wikipediaTopics != nil)
        } else {
            #expect(result.searchRestriction == .invalidRestriction && result.wikipediaCandidateStatus == .malformed)
            #expect(result.wikipediaTopics == nil)
        }
        #expect(result.searchDiagnostic?.identityOutcome == .decoded)
        #expect(result.searchDiagnostic?.validationFailure == failure)
        if key == "brand" {
            #expect(result.searchDiagnostic?.entityField == .brand)
            #expect(result.searchDiagnostic?.entityFailure == .aliasSafety)
        }
        #expect((result.searchQuery != nil) == (failure == .keywordOrigin))
    }
    // Cards 92/93 only stored these broad flags. Both missing schema version and
    // a decoded-but-rejected identity can produce them; neither is their proven wire.
    let oldWire = #"{"names":["樂連連原味洋芋片"],"summary":"","text":[]}"#
    let missing = try CameraAnswer.parse(oldWire, expectingStructured: true)
    #expect(missing.searchRestriction == .invalidRestriction && missing.wikipediaCandidateStatus == .malformed)
    #expect(missing.searchDiagnostic?.version == .missing)
}

@Test func structuredSafeDiagnosticSurvivesCameraPhotoRetryArchiveAndImageDecoration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var invalid = identity(); invalid["brand"] = "invalid"
    for source: ArchivedRecognition.ImageSource in [.camera, .photoLibrary] {
        let archive = RecognitionArchive(root: root.appendingPathComponent(source.rawValue)), id = UUID()
        let result = try answer(invalid)
        _ = try await archive.create(id: id, jpeg: Data([1,2]), capturedAt: Date(), imageSource: source)
        _ = try await archive.complete(id: id, result: nil, message: "generated")
        let attempt = UUID()
        _ = try await archive.beginRetry(id: id, attemptID: attempt)
        _ = try await archive.complete(id: id, result: result.withBarcodes(["00123"]).withSourceImage(id), message: nil, attemptID: attempt)
        let saved = try #require(try await RecognitionArchive(root: root.appendingPathComponent(source.rawValue)).load().records.first)
        #expect(saved.result?.searchDiagnostic == result.searchDiagnostic)
        #expect(saved.result?.searchDiagnostic?.decodingField == .brand)
        #expect(!saved.shareText().contains("searchDiagnostic") && saved.result?.sourceImageID == id)
    }
}

private func entity(_ name: String, _ aliases: [String] = [], _ basis: [String] = ["text"]) -> [String: Any] {
    ["name": name, "aliases": aliases, "basis": basis]
}

// Exact safe search fields from Build23 card 98's keywordEvidence, captured
// 2026-10-15 11:21:14 UTC. This replays SEARCH METADATA only: the original summary,
// OCR and full model wire were not exported and are not reconstructed here.
private func card98Identity() -> [String: Any] {
    ["category":"product", "subject":NSNull(), "brand":entity("樂事", ["Lay's", "樂事"], ["text", "logo"]),
     "manufacturer":NSNull(), "series":entity("樂連連"), "product":entity("樂事樂連連原味"),
     "model_version":NSNull(), "formal_name":NSNull(), "disambiguation":["馬鈴薯零食"],
     "google_keywords":["Lay's 樂事", "樂連連原味", "馬鈴薯零食"],
     "automatic_wikipedia":false, "wikipedia_candidates":[]]
}

@Test func card98SafeSearchMetadataReplaysActualDuplicateAliasFailure() throws {
    let result = try answer(card98Identity(), names: ["樂事樂連連原味"], text: [])
    #expect(result.searchDiagnostic?.entityField == nil && result.searchDiagnostic?.entityFailure == nil)
    #expect(result.searchRestriction == nil)
    #expect(result.searchQuery?.query == "Lay's 樂事 樂連連原味 馬鈴薯零食")
    #expect(result.searchIdentity?.brand?.aliases == ["Lay's"])
    #expect(result.searchDiagnostic?.normalizationFields == [.brand])
    #expect(result.searchDiagnostic?.keywordEvidence?.keywords.map(\.match) == [.composedSources, .singleSource, .singleSource])
    #expect(result.searchDiagnostic?.keywordEvidence?.sources.contains { $0.field == .brand && $0.kind == .alias && $0.text == "樂事" } == true)
    #expect(result.wikipediaTopics == nil && result.wikipediaCandidateStatus == .disabled)
    #expect(result.searchIdentity?.automaticWikipedia == false)
}

@Test func search97OldDiagnosticRemainsReadableAndKnownCompositionBugIsFixed() throws {
    // Card 97 persisted only this closed diagnostic, not the rejected identity
    // or keywords. The two answers below are synthetic counterexamples, not a
    // reconstruction of that card's model response.
    let observed = try JSONDecoder().decode(SearchParseDiagnostic.self, from: Data(#"{"contentWithinBounds":true,"identityOutcome":"decoded","identityShape":"object","missingIdentityFields":[],"missingRootFields":[],"parserRevision":22,"reason":"null","validationFailure":"keywordOrigin","version":"expected10"}"#.utf8))
    #expect(observed.parserRevision == 22 && observed.keywordEvidence == nil)
    let baseline = try answer()
    #expect(baseline.searchQuery != nil && baseline.searchIdentity != nil)
    #expect(baseline.searchDiagnostic?.validationFailure == nil)
    for keywords in [["樂事 樂連連原味洋芋片"], ["樂事", "無依據型號"]] {
        var metadata = identity(); metadata["google_keywords"] = keywords
        let result = try answer(metadata)
        #expect(result.searchDiagnostic?.parserRevision == 32)
        #expect(result.searchRestriction == nil && result.wikipediaTopics != nil && result.searchIdentity != nil)
        #expect(result.searchQuery != nil)
        #expect(result.searchDiagnostic?.googleOutcome == (keywords.count == 1 ? .complete : .partial))
        #expect(result.searchDiagnostic?.googleFailure == (keywords.count == 1 ? nil : .keywordOrigin))
    }
}

@Test func harmlessIdentityFormattingAndDuplicateListsNormalizeBeforeValidation() throws {
    var metadata = identity()
    metadata["brand"] = entity(" 樂事 ", ["乐事", "Lay’s", "LAY'S"], ["logo", "logo"])
    metadata["disambiguation"] = ["洋芋片", " 洋芋片 "]
    metadata["google_keywords"] = [" Lay’s 樂連連原味洋芋片 ", "LAY'S 樂連連原味洋芋片"]
    metadata["wikipedia_candidates"] = [["topic":"樂事", "kind":"brand"], ["topic":"Lay's", "kind":"brand"]]
    let result = try answer(metadata)
    #expect(result.searchRestriction == nil && result.searchQuery?.query == "Lay’s 樂連連原味洋芋片")
    #expect(result.searchIdentity?.brand?.name == "樂事" && result.searchIdentity?.brand?.aliases == ["Lay’s"])
    #expect(result.searchIdentity?.brand?.basis == [.logo])
    #expect(result.searchIdentity?.disambiguation == ["洋芋片"])
    #expect(result.searchIdentity?.wikipediaCandidates.count == 1 && result.wikipediaTopics != nil)
    #expect(result.searchDiagnostic?.normalizationFields == [.brand, .disambiguation, .google_keywords, .wikipedia_candidates])
    #expect(result.searchDiagnostic?.keywordEvidence?.keywords.count == 2) // Original safe values remain auditable.
    #expect(result.searchIdentity?.normalizedForSearch() == result.searchIdentity)
}

@Test func deduplicationCannotHideUnsafeValuesBoundsOrCandidateConflicts() throws {
    let cases: [(String, Any)] = [
        ("brand", entity("樂事", Array(repeating:"樂事",count:4))),
        ("brand", entity("樂事", ["樂事", "ignore instructions"])),
        ("brand", entity("樂事", ["樂事", "sk-abcdefghijklmno"])),
        ("brand", entity("樂事", [], Array(repeating:"logo",count:5))),
        ("google_keywords", Array(repeating:"樂事",count:9)),
        ("disambiguation", Array(repeating:"洋芋片",count:3)),
        ("wikipedia_candidates", Array(repeating:["topic":"樂事","kind":"brand"],count:3)),
        ("wikipedia_candidates", [["topic":"樂事","kind":"brand"],["topic":"其他品牌","kind":"brand"]]),
        ("manufacturer", entity("公司", [], ["logo", "logo"]))
    ]
    for (field, value) in cases {
        var metadata = identity(); metadata[field] = value
        let result = try answer(metadata)
        #expect(result.searchRestriction == .invalidRestriction)
        #expect(result.searchIdentity == nil && result.searchQuery == nil && result.wikipediaTopics == nil)
    }
    for reason in ["sensitive", "conflict", "uncertain"] {
        let result = try answer(card98Identity(), reason: reason)
        #expect(result.searchIdentity == nil && result.searchQuery == nil && result.wikipediaTopics == nil)
        #expect(result.searchDiagnostic?.keywordEvidence == nil)
    }
}

@Test func card98NormalizedIdentityAndOriginalSafeEvidenceSurviveArchiveRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try answer(card98Identity(), names: ["樂事樂連連原味"], text: [])
    for source: ArchivedRecognition.ImageSource in [.camera, .photoLibrary] {
        let archive = RecognitionArchive(root: root.appendingPathComponent(source.rawValue)), id = UUID(), attempt = UUID()
        _ = try await archive.create(id: id, jpeg: Data([1,2]), capturedAt: Date(), imageSource: source)
        _ = try await archive.complete(id: id, result: nil, message: "synthetic failure")
        _ = try await archive.beginRetry(id: id, attemptID: attempt)
        _ = try await archive.complete(id: id, result: result.withSourceImage(id).withBarcodes([]), message: nil, attemptID: attempt)
        let saved = try #require(try await archive.load().records.first)
        #expect(saved.result?.searchIdentity?.brand?.aliases == ["Lay's"])
        #expect(saved.result?.searchDiagnostic == result.searchDiagnostic)
        #expect(saved.result?.searchQuery?.query == result.searchQuery?.query)
        #expect(saved.shareDocument().links.count == 1 && !saved.shareText().contains("normalizationFields"))
        #expect(saved.result?.wikipediaCandidateStatus == .disabled && saved.wikipedia == nil)
    }
}
private func identity() -> [String: Any] {
    ["category": "product", "subject": entity("樂連連原味洋芋片"), "brand": entity("樂事", ["Lay's"], ["logo"]),
     "manufacturer": NSNull(), "series": NSNull(), "product": entity("樂連連原味洋芋片"),
     "model_version": NSNull(), "formal_name": NSNull(), "disambiguation": [],
     "google_keywords": ["Lay's", "樂事", "樂連連原味洋芋片"], "automatic_wikipedia": true,
     "wikipedia_candidates": [["topic": "樂事", "kind": "brand"]]]
}
private func raw(_ metadata: Any? = identity(), names: [String] = ["樂連連原味洋芋片"],
                 text: [String] = ["Lay's樂事", "樂連連", "原味"], reason: Any = NSNull(), version: Int = 10) throws -> String {
    var object: [String: Any] = ["schema_version": version, "names": names, "summary": "", "text": text, "search_block_reason": reason]
    if let metadata { object["search_identity"] = metadata }
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}
private func answer(_ metadata: Any? = identity(), names: [String] = ["樂連連原味洋芋片"], text: [String] = ["Lay's樂事", "樂連連", "原味"], reason: Any = NSNull()) throws -> RecognitionResult {
    try CameraAnswer.parse(raw(metadata, names: names, text: text, reason: reason), expectingStructured: true)
}
private func page(_ title: String = "乐事", _ extract: String = "樂事（Lay's）是一個洋芋片品牌，提供多種包裝食品。", categories: [String] = []) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["query": ["pages": [["title": title, "ns": 0, "pageid": 123,
        "canonicalurl": "https://zh.wikipedia.org/wiki/" + title, "extract": extract,
        "categories": categories.map { ["title": "Category:" + $0] }]]]])
}

@Test func structuredActualCardText88And90DoesNotNeedBrandInNameOrOCRSpacing() throws {
    // These are the necessary deidentified texts from cards 88/90. Identity is a
    // NEW synthetic answer, not a reconstruction of either original model wire.
    for (name, text) in [("樂事樂連連原味", ["Lay's 樂事", "樂連連", "原味"]),
                         ("樂連連原味洋芋片", ["Lay's樂事", "樂連連", "原味"]),
                         ("樂連連原味洋芋片", [String]())] {
        let result = try answer(names: [name], text: text)
        #expect(result.names == [name] && result.text == text && result.barcodes.isEmpty)
        #expect(result.wikipediaCandidateStatus == .modelProvided)
        #expect(result.wikipediaTopics?.matchScope == .structuredIdentity)
        #expect(result.searchIdentity?.manufacturer == nil)
        let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
        let reference = try #require(subject.reference(from: page(), at: Date()))
        #expect(reference.isCurrent(for: result) && reference.displayTitle == "樂事（品牌）")
    }
}
@Test func structuredBrandIsNotASubstringHeuristicOrManufacturer() throws {
    var input = identity(); input["brand"] = NSNull(); input["manufacturer"] = entity("樂事")
    let noBrand = try answer(input)
    #expect(noBrand.wikipediaTopics == nil && noBrand.searchRestriction != nil)
    input = identity(); input["manufacturer"] = entity("不明原廠", [], ["logo"])
    #expect(try answer(input).searchIdentity == nil)
    input = identity(); input["manufacturer"] = entity("合成製造公司")
    #expect(try answer(input).searchIdentity?.manufacturer?.name == "合成製造公司")
    input = identity(); input["wikipedia_candidates"] = [["topic":"合成製造公司","kind":"brand"]]
    #expect(try answer(input).wikipediaTopics == nil)
    // A new-format omission cannot activate the old OCR fallback.
    for metadata: Any? in [nil, NSNull()] {
        let result = try answer(metadata, names: ["樂事樂連連原味"], text: ["Lay's 樂事"])
        #expect(result.wikipediaTopics == nil && WikipediaSubject.matching(result, allowLegacy: false) == nil)
    }
}
@Test func structuredWrongBrandAliasPersonCompanyAndDisambiguationPagesAreRejected() throws {
    let result = try answer(), subject = try #require(WikipediaSubject.matching(result))
    for extract in ["樂事（Other）是一個洋芋片品牌，提供多種包裝食品。", "樂事是一家公司，生產洋芋片及其他食品。", "樂事是一位作家，喜歡評論Lay's品牌。", "樂事是一個評論Lay's品牌的網站。", "樂事可能指多個人名與食品品牌。", "樂事（Lay's）不是一個食品品牌。"] {
        #expect(try subject.reference(from: page("乐事", extract), at: Date()) == nil)
    }
    #expect(try subject.reference(from: page("其他品牌"), at: Date()) == nil)
    #expect(try subject.reference(from: page(categories: ["人物"]), at: Date()) == nil)
}
@Test func structuredPlantsFormalNameAndGenericObjectsUseTypedSubjectAndDefinition() throws {
    for (name, formal, category, term, extract) in [
        ("龜背芋", "Monstera deliciosa", "species", "植物", "龜背芋（Monstera deliciosa）是天南星科的植物，常栽培於室內。"),
        ("雨傘", "雨傘", "object", "工具", "雨傘是一種遮蔽雨水的工具，也可用於遮陽。")
    ] {
        var input = identity(); input["category"] = category
        input["subject"] = entity(name, [], ["appearance"]); input["formal_name"] = entity(formal)
        for key in ["brand", "product", "manufacturer", "series", "model_version"] { input[key] = NSNull() }
        input["disambiguation"] = [term]; input["google_keywords"] = [formal]
        input["wikipedia_candidates"] = [["topic": name, "kind": "subject"]]
        let result = try answer(input, names: [name], text: [])
        let subject = try #require(WikipediaSubject.matching(result))
        #expect(try subject.reference(from: page(name, extract), at: Date())?.isCurrent(for: result) == true)
        #expect(try subject.reference(from: page(name, name + "是一部以植物為題材的電影作品。"), at: Date()) == nil)
    }
}
@Test func structuredMissingWrongTypesAndBoundsKeepCardButDoNotRecoverUnsafeSearch() throws {
    var invalid: [Any] = ["wrong", 3, [], [:], ["category":"person"]]
    for (key, value): (String, Any) in [("brand", "樂事"), ("automatic_wikipedia", "true"), ("google_keywords", [123]),
        ("wikipedia_candidates", [["topic":"樂事","kind":"manufacturer"]]), ("disambiguation", [String(repeating:"詞",count:25)]),
        ("google_keywords", ["address@example.test"]), ("brand", entity("樂事", [], ["memory"]))] {
        var item = identity(); item[key] = value; invalid.append(item)
    }
    for metadata in invalid {
        let result = try answer(metadata)
        #expect(result.names == ["樂連連原味洋芋片"] && result.text == ["Lay's樂事", "樂連連", "原味"])
        #expect(result.searchIdentity == nil && result.searchQuery == nil && result.wikipediaTopics == nil)
        #expect(result.searchRestriction == .invalidRestriction && result.wikipediaCandidateStatus == .malformed)
        #expect(GoogleSearchQuery.resolve(result: result, decodedBarcodes: [], productBarcodes: []) == nil)
    }
    var duplicate = identity(); duplicate["brand"] = entity("樂事", ["Other", "Other"])
    let normalized = try answer(duplicate)
    #expect(normalized.searchIdentity?.brand?.aliases == ["Other"])
    #expect(normalized.searchDiagnostic?.googleFailure == .keywordOrigin) // Lay's was not declared in this answer.
    #expect(normalized.searchQuery != nil && normalized.wikipediaTopics != nil)
    #expect(normalized.searchDiagnostic?.googleOutcome == .partial)
    var missing = identity(); missing.removeValue(forKey: "manufacturer")
    #expect(try answer(missing).searchIdentity?.manufacturer == nil)
    missing.removeValue(forKey: "automatic_wikipedia")
    #expect(try answer(missing).wikipediaTopics == nil)
    for reason: Any in ["sensitive", "conflict", "uncertain", "unknown", true] {
        let result = try answer(reason: reason)
        #expect(result.searchIdentity == nil && result.wikipediaTopics == nil && result.searchQuery == nil)
    }
    let unknownVersion = try raw().replacingOccurrences(of: "\"schema_version\":10", with: "\"schema_version\":99")
    #expect(try CameraAnswer.parse(unknownVersion, expectingStructured: true).searchRestriction != nil)
}

@Test func structuredKeywordCompositionsAliasesAndFormattingPreserveSourceCoverage() throws {
    for query in ["樂事 樂連連原味洋芋片", "樂事樂連連原味洋芋片", "Lay’s 乐连连原味洋芋片",
                  "LAY'S   樂連連原味洋芋片", "Ｌａｙ's 樂連連原味洋芋片", "樂事（Lay’s）樂連連原味洋芋片"] {
        var metadata = identity(); metadata["google_keywords"] = [query]
        let result = try answer(metadata)
        #expect(result.searchQuery?.query == query && result.wikipediaTopics != nil)
        let evidence = try #require(result.searchDiagnostic?.keywordEvidence)
        #expect(evidence.keywords.first?.match == .composedSources)
        #expect(evidence.keywords.first?.sourceIndices.isEmpty == false)
        #expect(evidence.sources.contains { $0.field == .brand && $0.kind == .alias && $0.text == "Lay's" && $0.basis == [.logo] })
    }
    var metadata = identity(); metadata["model_version"] = entity("AB-123")
    metadata["google_keywords"] = ["樂事 AB 123"]
    #expect(try answer(metadata).searchQuery?.query == "樂事 AB 123")
    metadata["google_keywords"] = ["洋芋片"] // Existing contiguous single-source selection.
    #expect(try answer(metadata).searchQuery?.query == "洋芋片")
}

@Test func structuredUnsupportedWordsUseCompleteIdentityWithoutInvalidatingCheckedWiki() throws {
    let barcode = try #require(ProductBarcode(value: "0012345678905", symbology: .ean13))
    for query in ["樂事 無依據型號", "Layss 樂連連原味洋芋片", "Layz", "樂事 特辣", "樂事樂連片"] {
        var metadata = identity(); metadata["google_keywords"] = [query]
        let result = try answer(metadata)
        #expect(result.searchQuery?.query == "樂連連原味洋芋片" && result.searchRestriction == nil)
        #expect(result.searchIdentity?.brand?.name == "樂事" && result.wikipediaTopics != nil)
        #expect(result.searchDiagnostic?.googleFailure == .keywordOrigin && result.searchDiagnostic?.wikipediaFailure == nil)
        #expect(result.searchDiagnostic?.keywordEvidence?.keywords.first?.text == query)
        #expect(result.searchDiagnostic?.keywordEvidence?.keywords.first?.match == .unmatched)
        #expect(GoogleSearchQuery.resolve(result: result, decodedBarcodes: [barcode.value], productBarcodes: [barcode])?.query == "樂連連原味洋芋片 " + barcode.value)
        let subject = try #require(WikipediaSubject.matching(result))
        #expect(try subject.reference(from: page(), at: Date())?.isCurrent(for: result) == true)
    }
    var metadata = identity(); metadata["brand"] = entity("Acme"); metadata["product"] = entity("Widget")
    metadata["wikipedia_candidates"] = []; metadata["google_keywords"] = ["AcmeWidget"]
    #expect(try answer(metadata).searchQuery?.query == "Widget") // Never invent a Latin compound.
    metadata["google_keywords"] = ["Acme Widget"]
    #expect(try answer(metadata).searchQuery != nil)
    metadata["model_version"] = entity("C++")
    metadata["google_keywords"] = ["Acme C++"]
    #expect(try answer(metadata).searchQuery != nil)
    metadata["google_keywords"] = ["Acme C+"]
    #expect(try answer(metadata).searchQuery?.query == "Widget")
}

@Test func structuredIndependentGoogleFailureCannotHideBadWikiOrPrivateContext() throws {
    var metadata = identity(); metadata["google_keywords"] = ["無依據型號"]
    metadata["wikipedia_candidates"] = [["topic": "另一品牌", "kind": "brand"]]
    let badWiki = try answer(metadata)
    #expect(badWiki.searchIdentity == nil && badWiki.searchRestriction == .invalidRestriction)
    #expect(badWiki.searchDiagnostic?.googleFailure == .keywordOrigin)
    #expect(badWiki.searchDiagnostic?.wikipediaFailure == .candidateRoleOrTopic)
    metadata = identity(); metadata["google_keywords"] = ["無依據型號"]
    for reason in ["sensitive", "conflict", "uncertain"] {
        let blocked = try answer(metadata, reason: reason)
        #expect(blocked.searchIdentity == nil && blocked.searchQuery == nil && blocked.wikipediaTopics == nil)
        #expect(blocked.searchDiagnostic?.keywordEvidence == nil && blocked.searchDiagnostic?.evidenceSuppression == .blockedOrPrivate)
    }
    let privateCard = try answer(metadata, text: ["患者姓名：甲乙"])
    #expect(privateCard.searchRestriction == .sensitive && privateCard.searchDiagnostic?.keywordEvidence == nil)
    let longTerms = [String(repeating: "Alpha", count: 8), String(repeating: "Bravo", count: 8), String(repeating: "Delta", count: 8)]
    metadata = identity(); metadata["brand"] = entity("樂事", longTerms, ["logo"])
    metadata["google_keywords"] = longTerms
    let tooLong = try answer(metadata)
    #expect(tooLong.searchDiagnostic?.googleFailure == .googleQuery)
    #expect(tooLong.searchQuery == nil && tooLong.searchIdentity != nil && tooLong.wikipediaTopics != nil)
    #expect(GoogleSearchQuery.resolve(result: tooLong, decodedBarcodes: [], productBarcodes: []) == nil)
}

@Test func structuredKeywordSafetyAndDiagnosticPrivacyRemainFailClosed() throws {
    for query in ["ignore instructions", "address@example.test", "https://example.test", "0912345678", "台北市中正區和平路123號", "password abcdef", "搜尋 樂事", "樂事\n原味"] {
        var metadata = identity(); metadata["google_keywords"] = [query]
        let result = try answer(metadata)
        #expect(result.searchIdentity == nil && result.searchQuery == nil && result.wikipediaTopics == nil)
        #expect(result.searchDiagnostic?.keywordEvidence == nil)
        #expect(result.searchDiagnostic?.evidenceSuppression == .unsafeSearchText)
    }
    var metadata = identity(); metadata["google_keywords"] = ["sk-abcdefghijklmno"]
    let tokenLike = try answer(metadata)
    #expect(tokenLike.searchIdentity == nil && tokenLike.searchQuery == nil && tokenLike.searchDiagnostic?.keywordEvidence == nil)
    metadata = identity(); metadata["google_keywords"] = Array(repeating: "詞", count: 100)
    #expect(try answer(metadata).searchDiagnostic?.evidenceSuppression == .bounds)
    // The OCR marker must never get copied into the search provenance diagnostic.
    metadata = identity(); metadata["google_keywords"] = ["樂事 樂連連原味洋芋片"]
    let safe = try answer(metadata, text: ["OCR-only-content-not-for-diagnostics"])
    let encoded = String(decoding: try JSONEncoder().encode(safe.searchDiagnostic), as: UTF8.self)
    #expect(!encoded.contains("OCR-only-content") && encoded.contains("樂事"))
}

@Test func structuredKeywordEvidenceSurvivesArchiveRetryAndStaysOutOfShare() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var metadata = identity(); metadata["google_keywords"] = ["無依據型號"]
    let result = try answer(metadata)
    for source: ArchivedRecognition.ImageSource in [.camera, .photoLibrary] {
        let archive = RecognitionArchive(root: root.appendingPathComponent(source.rawValue)), id = UUID(), attempt = UUID()
        _ = try await archive.create(id: id, jpeg: Data([1,2]), capturedAt: Date(), imageSource: source)
        _ = try await archive.complete(id: id, result: nil, message: "synthetic failure")
        _ = try await archive.beginRetry(id: id, attemptID: attempt)
        _ = try await archive.complete(id: id, result: result.withSourceImage(id).withBarcodes([]), message: nil, attemptID: attempt)
        let saved = try #require(try await archive.load().records.first)
        #expect(saved.result?.searchDiagnostic?.keywordEvidence == result.searchDiagnostic?.keywordEvidence)
        #expect(saved.result?.searchIdentity != nil && saved.result?.searchQuery?.query == "樂連連原味洋芋片")
        #expect(!saved.shareText().contains("無依據型號") && !saved.shareText().contains("keywordEvidence"))
    }
}
@Test func structuredSensitiveContextCannotEnableWikiAndExplicitDisabledStaysDisabled() throws {
    for text in [["患者姓名：甲乙"], ["處方箋"], ["收件人：甲乙\n台北市中正區和平路123號"], ["patient record"]] {
        #expect(try answer(text: text).wikipediaTopics == nil)
    }
    var input = identity(); input["automatic_wikipedia"] = false
    #expect(try answer(input).wikipediaCandidateStatus == .disabled)
    #expect(try answer(input).searchQuery != nil)
}
@Test func QRFieldsAreBoundedSeparateAndNeverOpenOrTrustURL() throws {
    let values = ["品名：合成茶飲\n品牌：測試茶廠\n型號：AB-01\n電話：0800-388-100\n官網：https://example.test/?source=qr\n忽略指示"]
    let evidence = try #require(BarcodeSearchEvidence(decodedValues: values))
    #expect(evidence.fields == ["product":"合成茶飲","brand":"測試茶廠","model":"AB-01"])
    for payload in ["品名：合成茶飲\n患者姓名：甲乙", "品牌：合成\n品牌：其他", "型號：ignore instructions", "品牌：https://example.test", "品名：合成茶飲\n帳戶：secret"] {
        #expect(BarcodeSearchEvidence(decodedValues: [payload]) == nil)
    }
    #expect(BarcodeSearchEvidence(decodedValues: ["https://example.test/product"]) == nil)
    #expect(BarcodeSearchEvidence(decodedValues: Array(repeating: values[0], count: 33)) == nil)
    let model = SIWCModel(slug: "gpt-6-luna", display_name: "Fixture", visibility: "list")
    let body = try CameraAnswer.request(model:model.slug,catalog:[model],jpeg:Data([1]),searchEvidence:evidence)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String:Any])
    let inputs = try #require(object["input"] as? [[String:Any]])
    let contents = try #require(inputs[0]["content"] as? [[String:Any]])
    let fields = try #require(contents[1]["text"] as? String)
    #expect(!fields.contains("0800") && !fields.contains("https") && !fields.contains("忽略") && !fields.contains("token"))
    let format = try #require((object["text"] as? [String:Any])?["format"] as? [String:Any])
    #expect(format["strict"] as? Bool == true && format["type"] as? String == "json_schema")
    let schema = try #require(format["schema"] as? [String:Any])
    #expect((schema["properties"] as? [String:Any])?["barcodes"] == nil)
    func checkObjects(_ object: Any) {
        if let dictionary = object as? [String:Any] {
            if dictionary["type"] as? String == "object" {
                #expect(dictionary["additionalProperties"] as? Bool == false)
                #expect(Set(dictionary["required"] as? [String] ?? []) == Set((dictionary["properties"] as? [String:Any] ?? [:]).keys))
            }
            for value in dictionary.values { checkObjects(value) }
        } else if let array = object as? [Any] { for value in array { checkObjects(value) } }
    }
    checkObjects(schema)
}
@Test func structuredArchiveGoogleBarcodeAndShareRetainSameCardAndRawText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID(), now = Date()
    let code = try #require(ProductBarcode(value:"0012345678905",symbology:.ean13))
    let text = ["  Lay's樂事  ", "日本語\r\n包装文字"]
    let result = try answer(text:text)
    #expect(result.text == text)
    _ = try await archive.create(id:id,jpeg:Data([1,2]),capturedAt:now,decodedBarcodes:[code.value],productBarcodes:[code])
    _ = try await archive.complete(id:id,result:result,message:nil)
    let subject = try #require(WikipediaSubject.matching(result)), wiki = try #require(subject.reference(from:page(),at:now))
    _ = try await archive.attachWikipedia(id:id,reference:wiki,at:now)
    let saved = try #require(try await RecognitionArchive(root:root).load().records.first)
    #expect(saved.result?.searchIdentity == result.searchIdentity && saved.result?.text == text)
    #expect(saved.result?.sourceImageID == id && saved.barcodes == [code.value])
    let query = try #require(saved.googleSearch)
    #expect(query.query == "Lay's 樂事 樂連連原味洋芋片 0012345678905")
    let params = try #require(URLComponents(url:query.googleURL!,resolvingAgainstBaseURL:false)?.queryItems)
    #expect(params == [.init(name: "q", value: query.query), .init(name: "gl", value: "tw")])
    #expect(saved.shareDocument().links.count == 2 && saved.shareText().contains("[維基百科：樂事（品牌）]"))
    #expect(!saved.shareText().contains("search_identity") && saved.shareText().contains("日本語\r\n包装文字"))
    // Legacy data remains readable, without creating new metadata or new requests.
    let old = #"{"names":["舊卡"],"summary":"","text":[],"barcodes":[]}"#
    #expect(try JSONDecoder().decode(RecognitionResult.self,from:Data(old.utf8)).searchIdentity == nil)
}
@Test func structuredStreamingRequiresCompletedAndRejectsRefusalOrTruncation() throws {
    let answer = try raw()
    let delta = String(decoding:try JSONSerialization.data(withJSONObject:["type":"response.output_text.delta","delta":answer]),as:UTF8.self)
    func parse(_ tail:String) throws -> RecognitionResult {
        var stream = SIWCStream()
        for byte in ("data: " + delta + "\r\n\r\n" + tail).utf8 { try stream.byte(byte) }
        return try CameraAnswer.parse(stream.finish(),expectingStructured:true)
    }
    #expect(try parse("data: {\"type\":\"response.completed\"}\n\n").searchIdentity != nil)
    for tail in ["", "data: [DONE]\n\n", "data: {\"type\":\"response.completed\"}",
        "data: {\"type\":\"response.incomplete\"}\n\n", "data: {\"type\":\"response.failed\"}\n\n",
        "data: {\"type\":\"response.refusal.delta\",\"delta\":\"refused\"}\n\n", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\"}}\n\n"] {
        #expect(throws:(any Error).self) { try parse(tail) }
    }
    #expect(throws:(any Error).self) { try CameraAnswer.parse(String(answer.dropLast()),expectingStructured:true) }
}

@Test func structuredSeriesBrandRelationshipIsCorroboratedWithoutBrandAllowlist() throws {
    var input = identity()
    input["subject"] = entity("脆浪原味"); input["product"] = entity("脆浪原味")
    input["brand"] = entity("晴禾", ["Sungrain"], ["logo"]); input["series"] = entity("脆浪")
    input["google_keywords"] = ["Sungrain", "脆浪原味"]
    input["disambiguation"] = ["餅乾"]
    input["wikipedia_candidates"] = [["topic":"晴禾","kind":"brand"], ["topic":"脆浪","kind":"series"]]
    let result = try answer(input,names:["原味餅乾"],text:[]), subject = try #require(WikipediaSubject.matching(result))
    #expect(subject.query(at:0) == "脆浪" && subject.query(at:1) == "晴禾")
    #expect(try subject.reference(from:page("晴禾","晴禾（Sungrain）是一個餅乾品牌，販售多種包裝食品。"),at:Date(),candidateIndex:1) == nil)
    let reference = try #require(subject.reference(from:page("晴禾","晴禾（Sungrain）是一個餅乾品牌。晴禾推出脆浪餅乾系列。"),at:Date(),candidateIndex:1))
    #expect(reference.isCurrent(for:result) && reference.relation?.relatedTopic == "脆浪")
    #expect(try subject.reference(from:page("脆浪","脆浪是晴禾推出的餅乾系列，提供多種口味。"),at:Date(),candidateIndex:0)?.isCurrent(for:result) == true)
    #expect(try subject.reference(from:page("脆浪","別的商品是晴禾推出的餅乾系列。"),at:Date(),candidateIndex:0) == nil)
}
@Test func structuredPublicMedicineIsManualOnlyAndPrivateQRCodeStopsAllLookup() throws {
    var input = identity(); input["subject"] = entity("Actein 顆粒"); input["product"] = entity("Actein 顆粒")
    input["brand"] = NSNull(); input["google_keywords"] = ["Actein 顆粒"]
    input["automatic_wikipedia"] = false; input["wikipedia_candidates"] = []
    let result = try answer(input,names:["Actein 顆粒"],text:["Actein"])
    #expect(result.searchQuery?.query == "Actein 顆粒" && result.wikipediaTopics == nil)
    let privateResult = try answer(input,names:["Actein 顆粒"],text:["患者姓名：甲乙"])
    #expect(privateResult.searchRestriction == .sensitive && privateResult.searchQuery == nil)
    let privateQR = "品名：合成茶飲\n患者姓名：甲乙"
    let publicCard = try answer().withBarcodes([privateQR])
    #expect(WikipediaSubject.matching(publicCard) == nil)
    #expect(GoogleSearchQuery.resolve(result:publicCard,decodedBarcodes:[privateQR],productBarcodes:[]) == nil)
}
@Test func structuredUnsupportedFormatRemainsClosedDiagnosticWithoutRetryContract() {
    for field in ["text", "text.format", "text.format.type", "text.format.schema", "text.format.strict"] {
        #expect(SIWCSafeDiagnostic.parameter(field) == field)
    }
    #expect(SIWCSafeDiagnostic.parameter("text.format.private-user-value") == "unrecognized_parameter")
    #expect(SIWCSafeDiagnostic.code("subscription_sharing_unsupported_capability") == "subscription_sharing_unsupported_capability")
}

private func policyIdentity(_ policy: String = "allowed", base: [String: Any] = identity()) -> [String: Any] {
    var value = base
    value.removeValue(forKey: "automatic_wikipedia")
    value["wikipedia_policy"] = policy
    value["wikipedia_candidates"] = [] as [Any]
    return value
}
private func policyAnswer(_ metadata: [String: Any] = policyIdentity(), text: [String] = [], reason: Any = NSNull()) throws -> RecognitionResult {
    try CameraAnswer.parse(raw(metadata, text: text, reason: reason, version: 11), expectingStructured: true)
}

@Test func policy11ReplaysCard98FieldsWithExplicitlySyntheticNewPermission() throws {
    // Only identity search fields come from actual card 98. This new permission
    // is SYNTHETIC; card 98's historical false and its unknown reason are unchanged.
    let result = try policyAnswer(policyIdentity(base: card98Identity()))
    #expect(result.searchDiagnostic?.version == .expected11 && result.searchDiagnostic?.parserRevision == 32)
    #expect(result.searchRestriction == nil && result.searchIdentity?.brand?.aliases == ["Lay's"])
    #expect(result.searchQuery?.query == "Lay's 樂事 樂連連原味 馬鈴薯零食")
    #expect(result.searchIdentity?.wikipediaCandidates.isEmpty == true)
    #expect(result.searchIdentity?.wikipediaPolicy == .allowed && result.searchDiagnostic?.wikipediaPolicy == .allowed)
    #expect(result.searchDiagnostic?.keywordEvidence?.wikipediaPolicy == .allowed)
    #expect(result.wikipediaCandidateStatus == .structuredBrandFallback)
    let subject = try #require(WikipediaSubject.matching(result, allowLegacy: false))
    #expect(subject.searchTitle == "樂事" && subject.request(at: 0).url?.host == "zh.wikipedia.org")
    let wiki = try #require(subject.reference(from: page(), at: Date()))
    #expect(wiki.isCurrent(for: result) && wiki.displayTitle == "樂事（品牌）")
    let old = try answer(card98Identity())
    #expect(old.wikipediaTopics == nil && old.wikipediaCandidateStatus == .disabled && old.searchIdentity?.wikipediaPolicy == nil)
}

@Test func policy11FallbackUsesAnyDeclaredBrandAndPrefersChineseAliasWithoutGuessing() throws {
    for (brand, expected) in [(entity("Sungrain", ["晴禾"], ["logo"]), "晴禾"),
                             (entity("晴禾", ["Sungrain"], ["appearance"]), "晴禾"),
                             (entity("Sungrain", [], ["text"]), "Sungrain")] {
        var input = policyIdentity(); input["brand"] = brand; input["google_keywords"] = [expected]
        let result = try policyAnswer(input), subject = try #require(WikipediaSubject.matching(result))
        #expect(subject.searchTitle == expected && subject.request(at: 0).url?.host == "zh.wikipedia.org")
        #expect(result.wikipediaCandidateStatus == .structuredBrandFallback)
        #expect(result.searchDiagnostic?.keywordEvidence?.wikipediaCandidates.isEmpty == true)
        #expect(try subject.reference(from: page(expected, expected + "（晴禾／Sungrain）是一個餅乾品牌，提供多種包裝食品。"), at: Date())?.isCurrent(for: result) == true)
    }
}

@Test func policy11NoBrandNeverPromotesManufacturerProductOrOCR() throws {
    var input = policyIdentity(); input["brand"] = NSNull(); input["manufacturer"] = entity("樂事")
    let result = try policyAnswer(input, text: ["Lay's 樂事"])
    #expect(result.searchRestriction == nil && result.searchIdentity != nil && result.wikipediaTopics == nil)
    #expect(WikipediaSubject.matching(result, allowLegacy: false) == nil)
    input["category"] = "object"
    for field in ["manufacturer", "product", "series", "model_version"] { input[field] = NSNull() }
    input["subject"] = entity("雨傘"); input["google_keywords"] = ["雨傘"]; input["disambiguation"] = ["用品"]
    #expect(try policyAnswer(input).wikipediaTopics == nil)
    input["brand"] = entity("樂事") // Commercial role is invalid on a non-product.
    #expect(try policyAnswer(input).searchRestriction == .invalidRestriction)
}

@Test func policy11FallbackStillRequiresCorrectBrandDefinitionAndAlias() throws {
    let result = try policyAnswer(), subject = try #require(WikipediaSubject.matching(result))
    for extract in ["樂事（Other）是一個食品品牌。", "樂事是一家製造食品的公司。", "樂事是一位評論Lay's的作家。",
                    "樂事可能指不同人物或品牌。", "樂事（Lay's）不是一個食品品牌。", "樂事是一個評論Lay's品牌的網站。"] {
        #expect(try subject.reference(from: page("乐事", extract), at: Date()) == nil)
    }
    #expect(try subject.reference(from: page("另一個品牌"), at: Date()) == nil)
    var ambiguous = try JSONSerialization.jsonObject(with: page()) as! [String: Any]
    var query = ambiguous["query"] as! [String: Any]
    var pages = query["pages"] as! [[String: Any]]
    pages[0]["pageprops"] = ["disambiguation": ""]
    query["pages"] = pages; ambiguous["query"] = query
    #expect(try subject.reference(from: JSONSerialization.data(withJSONObject: ambiguous), at: Date()) == nil)
    var wrong = policyIdentity(); wrong["wikipedia_candidates"] = [["topic": "其他品牌", "kind": "brand"]]
    #expect(try policyAnswer(wrong).searchIdentity == nil) // Does not replace an invalid suggestion.
    var explicit = policyIdentity(); explicit["wikipedia_candidates"] = [["topic": "樂事", "kind": "brand"]]
    #expect(try policyAnswer(explicit).wikipediaCandidateStatus == .modelProvided)
}

@Test func policy11PrivacyConflictAndTrueUncertaintyRemainMaterialVetoes() throws {
    for policy in ["sensitive", "conflict", "uncertain"] {
        let result = try policyAnswer(policyIdentity(policy))
        #expect(result.wikipediaTopics == nil && WikipediaSubject.matching(result) == nil)
        #expect(result.searchDiagnostic?.wikipediaPolicy?.rawValue == policy)
        if policy != "sensitive" {
            #expect(result.searchRestriction?.rawValue == policy && result.searchQuery == nil)
            #expect(result.searchDiagnostic?.keywordEvidence == nil)
        } else { #expect(result.searchQuery != nil && result.wikipediaCandidateStatus == .disabled) }
    }
    for reason in ["sensitive", "conflict", "uncertain"] {
        let result = try policyAnswer(reason: reason)
        #expect(result.searchRestriction?.rawValue == reason && result.searchIdentity == nil && result.wikipediaTopics == nil)
    }
    for text in [["患者姓名：甲乙"], ["私人帳單"], ["處方箋"], ["收件人：甲乙\n台北市中正區和平路123號"]] {
        #expect(try policyAnswer(text: text).wikipediaTopics == nil)
    }
    var token = policyIdentity(); token["brand"] = entity("sk-synthetic123456789")
    let unsafe = try policyAnswer(token)
    #expect(unsafe.searchIdentity == nil && unsafe.searchDiagnostic?.keywordEvidence == nil)
    let qr = try policyAnswer().withBarcodes(["患者姓名：甲乙\n品牌：樂事"])
    #expect(WikipediaSubject.matching(qr) == nil)
}

@Test func policy11MissingUnknownAndMixedContractsNeverCreatePermission() throws {
    for value: Any? in [nil, NSNull(), "unknown", true, 0, ["allowed"]] {
        var input = policyIdentity(); input["wikipedia_policy"] = value
        let result = try policyAnswer(input)
        #expect(result.searchRestriction == .invalidRestriction && result.searchIdentity == nil && result.wikipediaTopics == nil)
    }
    for legacy in [false, true] {
        var mixed = policyIdentity(); mixed["automatic_wikipedia"] = legacy
        #expect(try policyAnswer(mixed).searchRestriction == .invalidRestriction)
        var old = identity(); old["automatic_wikipedia"] = legacy; old["wikipedia_candidates"] = []
        old["wikipedia_policy"] = "allowed" // Injection into schema 10 cannot opt in.
        let result = try answer(old)
        #expect(result.searchIdentity?.wikipediaPolicy == nil && result.wikipediaTopics == nil)
        #expect(result.searchIdentity?.automaticWikipedia == legacy)
    }
    let future = try raw(policyIdentity(), version: 18)
    #expect(try CameraAnswer.parse(future, expectingStructured: true).searchRestriction == .invalidRestriction)
}

@Test func policy11PublicMedicineRemainsManualOnlyAndPrivateRecordStopsBoth() throws {
    var input = policyIdentity("sensitive"); input["brand"] = NSNull(); input["subject"] = entity("Actein 顆粒")
    input["product"] = entity("Actein 顆粒"); input["google_keywords"] = ["Actein 顆粒"]
    let publicPackage = try policyAnswer(input)
    #expect(publicPackage.searchQuery?.query == "Actein 顆粒" && publicPackage.wikipediaTopics == nil)
    let record = try policyAnswer(input, text: ["患者姓名：甲乙"])
    #expect(record.searchRestriction == .sensitive && record.searchQuery == nil && record.wikipediaTopics == nil)
}

@Test func policy11ArchiveRetryShareKeepsPolicyOnSameCardWithoutUpgradingOldCards() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for source: ArchivedRecognition.ImageSource in [.camera, .photoLibrary] {
        let archive = RecognitionArchive(root: root.appendingPathComponent(source.rawValue)), id = UUID(), attempt = UUID()
        let result = try policyAnswer(policyIdentity(base: card98Identity()))
        _ = try await archive.create(id: id, jpeg: Data([1,2]), capturedAt: Date(), imageSource: source)
        _ = try await archive.complete(id: id, result: nil, message: "synthetic failure")
        _ = try await archive.beginRetry(id: id, attemptID: attempt)
        _ = try await archive.complete(id: id, result: result, message: nil, attemptID: attempt)
        let subject = try #require(WikipediaSubject.matching(result)), wiki = try #require(subject.reference(from: page(), at: Date()))
        _ = try await archive.attachWikipedia(id: id, reference: wiki)
        let saved = try #require(try await RecognitionArchive(root: root.appendingPathComponent(source.rawValue)).load().records.first)
        #expect(saved.id == id && saved.result?.sourceImageID == id && saved.result?.searchIdentity?.wikipediaPolicy == .allowed)
        #expect(saved.result?.searchDiagnostic == result.searchDiagnostic && saved.shareDocument().links.count == 2)
        #expect(saved.shareText().contains("維基百科：樂事（品牌）") && !saved.shareText().contains("wikipedia_policy"))
    }
    let old = try answer(card98Identity())
    let restored = try JSONDecoder().decode(RecognitionResult.self, from: JSONEncoder().encode(old))
    #expect(restored == old && restored.wikipediaCandidateStatus == .disabled && WikipediaSubject.matching(restored) == nil)
    // Status alone cannot claim generated provenance; identity is always rechecked.
    let forged = RecognitionResult(names: old.names, searchQuery: old.searchQuery, wikipediaTopics: try policyAnswer().wikipediaTopics,
        wikipediaCandidateStatus: .structuredBrandFallback, searchIdentity: old.searchIdentity)
    #expect(WikipediaSubject.matching(forged) == nil)
}

// Generic equivalent of a supported product phrase plus an unsupported translation.
// Actual card metadata replay is kept in the private delivery evidence, not this fixture.
private func partialGoogleIdentity(_ policy: String = "allowed") -> [String: Any] {
    var value = policyIdentity(policy)
    value["brand"] = entity("Acme", ["阿克米"], ["logo"])
    value["subject"] = entity("洋芋片")
    value["series"] = entity("金色包")
    value["product"] = entity("阿克米原味洋芋片")
    value["google_keywords"] = ["阿克米原味洋芋片", "Acme 阿克米 Original Flavor"]
    return value
}
@Test func partialGoogleKeepsSupportedWholePhrasesInOriginalOrder() throws {
    var metadata = partialGoogleIdentity()
    metadata["google_keywords"] = ["Acme", "Acme Original Flavor", "阿克米原味洋芋片", "金色包"]
    let result = try policyAnswer(metadata)
    #expect(result.searchQuery?.query == "Acme 阿克米原味洋芋片 金色包")
    #expect(result.searchIdentity?.googleKeywords.count == 4) // Original evidence is retained.
    #expect(result.searchDiagnostic?.googleFailure == .keywordOrigin && result.searchDiagnostic?.googleOutcome == .partial)
    #expect(result.searchDiagnostic?.keywordEvidence?.keywords.map(\.match) == [.singleSource, .unmatched, .singleSource, .singleSource])
    #expect(GoogleSearchQuery.resolve(result: result, decodedBarcodes: [], productBarcodes: [])?.query == result.searchQuery?.query)
    #expect(result.wikipediaTopics != nil)
}
@Test func partialGoogleDoesNotInferTranslationFromOCR() throws {
    let result = try policyAnswer(partialGoogleIdentity(), text: ["Original Flavor"])
    #expect(result.searchQuery?.query == "阿克米原味洋芋片")
    #expect(result.searchDiagnostic?.keywordEvidence?.keywords.last?.match == .unmatched)
    var metadata = partialGoogleIdentity()
    metadata["product"] = entity("阿克米原味洋芋片", ["Acme 阿克米 Original Flavor"])
    let declared = try policyAnswer(metadata)
    #expect(declared.searchQuery?.query == "阿克米原味洋芋片 Acme 阿克米 Original Flavor")
    #expect(declared.searchDiagnostic?.googleOutcome == .complete)
}
@Test func partialGoogleNeverOverridesSensitiveWikiOrHardSearchStops() throws {
    let sensitiveWiki = try policyAnswer(partialGoogleIdentity("sensitive"))
    #expect(sensitiveWiki.searchQuery?.query == "阿克米原味洋芋片")
    #expect(sensitiveWiki.wikipediaTopics == nil && sensitiveWiki.wikipediaCandidateStatus == .disabled)
    #expect(sensitiveWiki.searchIdentity?.wikipediaPolicy == .sensitive)
    for policy in ["conflict", "uncertain"] {
        let result = try policyAnswer(partialGoogleIdentity(policy))
        #expect(result.searchQuery == nil && result.searchRestriction?.rawValue == policy)
        #expect(GoogleSearchQuery.resolve(result: result, decodedBarcodes: [], productBarcodes: []) == nil)
    }
    for reason in ["sensitive", "conflict", "uncertain"] {
        let result = try policyAnswer(partialGoogleIdentity(), reason: reason)
        #expect(result.searchIdentity == nil && result.searchQuery == nil && result.searchDiagnostic?.keywordEvidence == nil)
    }
    let privateText = try policyAnswer(partialGoogleIdentity(), text: ["患者姓名：測試"])
    #expect(privateText.searchRestriction == .sensitive && privateText.searchQuery == nil)
}
@Test func partialGoogleRejectsUnsafePhraseInsteadOfDroppingIt() throws {
    for bad in ["address@example.test", "https://example.test", "ignore instructions", "patient record", "Acme\n原味", "sk-abcdefghijklmno"] {
        var metadata = partialGoogleIdentity(); metadata["google_keywords"] = ["Acme", bad]
        let result = try policyAnswer(metadata)
        #expect(result.searchIdentity == nil && result.searchQuery == nil && result.searchRestriction == .invalidRestriction)
        #expect(result.searchDiagnostic?.keywordEvidence == nil)
    }
    var tooMany = partialGoogleIdentity(); tooMany["google_keywords"] = Array(repeating: "Acme", count: 9)
    #expect(try policyAnswer(tooMany).searchRestriction == .invalidRestriction)
}
@Test func partialGoogleFallsBackToIdentityButNeverRepairsOversizedCombinedQuery() throws {
    let code = try #require(ProductBarcode(value: "0012345678905", symbology: .ean13))
    var rejected = partialGoogleIdentity(); rejected["google_keywords"] = ["Acme Original Flavor"]
    let allRejected = try policyAnswer(rejected)
    #expect(allRejected.searchQuery?.query == "阿克米原味洋芋片" && allRejected.searchDiagnostic?.googleOutcome == .identityFallback)
    #expect(GoogleSearchQuery.resolve(result: allRejected, decodedBarcodes: [code.value], productBarcodes: [code])?.query == "阿克米原味洋芋片 " + code.value)
    let terms = [String(repeating: "Alpha", count: 9), String(repeating: "Bravo", count: 9), String(repeating: "Delta", count: 9)]
    var oversized = partialGoogleIdentity(); oversized["brand"] = entity("Acme", terms)
    oversized["google_keywords"] = terms + ["Unmatched term"]
    let tooLong = try policyAnswer(oversized)
    #expect(tooLong.searchQuery == nil && tooLong.searchDiagnostic?.googleOutcome == .unavailable)
    var oversizedUnmatched = partialGoogleIdentity()
    oversizedUnmatched["google_keywords"] = ["Acme"] + terms
    let cannotShrink = try policyAnswer(oversizedUnmatched)
    #expect(cannotShrink.searchQuery == nil && cannotShrink.searchDiagnostic?.googleOutcome == .unavailable)
    #expect(GoogleSearchQuery.resolve(result: cannotShrink, decodedBarcodes: [code.value], productBarcodes: [code]) == nil)
}
@Test func partialGoogleOldSavedIdentityResolvesWithoutRewritingOrNetwork() throws {
    let parsed = try policyAnswer(partialGoogleIdentity("sensitive"))
    let old = RecognitionResult(names: parsed.names, searchIdentity: parsed.searchIdentity)
    let bytes = try JSONEncoder().encode(old)
    let restored = try JSONDecoder().decode(RecognitionResult.self, from: bytes)
    #expect(restored.searchQuery == nil && restored.searchDiagnostic == nil)
    #expect(GoogleSearchQuery.resolve(result: restored, decodedBarcodes: [], productBarcodes: [])?.query == "阿克米原味洋芋片")
    #expect(restored == old) // Pure local resolver does not migrate the persisted result.
    #expect(GoogleSearchQuery.resolve(result: restored, decodedBarcodes: ["患者姓名：測試"], productBarcodes: []) == nil)
}
@Test func partialGoogleArchiveRetryShareKeepSameQueryAndOriginalEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for source: ArchivedRecognition.ImageSource in [.camera, .photoLibrary] {
        let archive = RecognitionArchive(root: root.appendingPathComponent(source.rawValue)), id = UUID(), attempt = UUID()
        let result = try policyAnswer(partialGoogleIdentity("sensitive"))
        _ = try await archive.create(id: id, jpeg: Data([1,2]), capturedAt: Date(), imageSource: source)
        _ = try await archive.complete(id: id, result: nil, message: "synthetic failure")
        _ = try await archive.beginRetry(id: id, attemptID: attempt)
        _ = try await archive.complete(id: id, result: result, message: nil, attemptID: attempt)
        let saved = try #require(try await archive.load().records.first)
        #expect(saved.googleSearch?.query == "阿克米原味洋芋片")
        #expect(saved.result?.searchDiagnostic?.googleOutcome == .partial && saved.result?.searchIdentity?.googleKeywords.count == 2)
        #expect(saved.shareDocument().links.count == 1 && saved.shareText().contains("阿克米原味洋芋片"))
        #expect(!saved.shareText().contains("Original Flavor") && saved.wikipedia == nil && saved.attemptNumber == 2)
    }
}


@Test func fullImageFragmentsKeepOriginalWordingThroughArchiveAndShare() async throws {
    // Synthetic model output checks preservation, not the model's visual accuracy.
    let text = ["  SUNGRAIN  ", "背景告示\n雨日X7／散字", "包装文字・ア。", "R & D — 001", "雨日X7／散字"]
    let result = try CameraAnswer.parse(raw(NSNull(), names: ["餅乾包裝"], text: text, version: 11), expectingStructured: true)
    #expect(result.names == ["餅乾包裝"] && result.text == text)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecognitionArchive(root: root), id = UUID()
    _ = try await archive.create(id: id, jpeg: Data([1, 2]), capturedAt: Date(), decodedBarcodes: [])
    _ = try await archive.complete(id: id, result: result, message: nil)
    let saved = try #require(try await RecognitionArchive(root: root).load().records.first)
    #expect(saved.result?.text == text && saved.shareResult?.text == text)
    #expect(saved.shareText().contains("【原文】\n\n" + text.joined(separator: "\n")))
}

@Test func fullImageTextRetainsExistingExactSchemaBoundary() throws {
    let text = (0..<32).map { String($0) + String(repeating: "x", count: 1000 - String($0).count) }
    let result = try CameraAnswer.parse(raw(NSNull(), text: text, version: 11), expectingStructured: true)
    #expect(result.text == text && result.searchRestriction == nil)
    let schema = try #require(CameraAnswerSchema.format["schema"] as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    let field = try #require(properties["text"] as? [String: Any])
    #expect(field["maxItems"] as? Int == 32)
    #expect((field["items"] as? [String: Any])?["maxLength"] as? Int == 1000)
}

@Test func oversizedTextRemainsBoundedAndCannotEnableSearch() throws {
    for text in [(0..<33).map { "合成行\($0)" }, [String(repeating: "字", count: 1001)]] {
        let result = try CameraAnswer.parse(raw(NSNull(), text: text, version: 11), expectingStructured: true)
        #expect(result.text.count <= 32 && result.text.allSatisfy { $0.count <= 1000 })
        #expect(result.searchRestriction == .invalidRestriction && result.searchQuery == nil && result.wikipediaTopics == nil)
    }
}


@Test func fullImageTextCannotBypassWholeResponseByteBudget() throws {
    let text = (0..<32).map { String($0) + String(repeating: "字", count: 998) }
    let wire = try raw(NSNull(), text: text, version: 11)
    #expect(wire.utf8.count > 32768)
    #expect(throws: SIWCError.self) { try CameraAnswer.parse(wire, expectingStructured: true) }
}
