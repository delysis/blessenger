import XCTest
@testable import CallGemma

final class WakeNameRoutingTests: XCTestCase {
    func testApproximateNameWithinAQuestionAndAmbiguousNames() throws {
        let gabor = UUID(), peter = UUID()
        let head = try WakeNameClassifier.train([
            .init(text: "GABOR", label: gabor.uuidString), .init(text: "GABBER", label: gabor.uuidString),
            .init(text: "PETER", label: peter.uuidString), .init(text: "PEETER", label: peter.uuidString),
            .init(text: "PLEASE CONTINUE", label: "other"), .init(text: "HOW ARE YOU", label: "other"),
            .init(text: "THE GARDEN IS QUIET", label: "other")])
        let model = WakeNameModel(fingerprint: "test", names: [.init(id: gabor, name: "Gabor"), .init(id: peter, name: "Peter")], classifier: head, accepted: true)
        XCTAssertEqual(try model.recipient("GABBER ARE YOU THERE", roster: [gabor, peter]), gabor)
        XCTAssertEqual(try model.recipient("GABBER WHAT DID PETER SAY", roster: [gabor, peter]), gabor)
        XCTAssertEqual(try model.recipient("HEY PEETER WHAT DID GABOR SAY", roster: [gabor, peter]), peter)
        XCTAssertNil(try model.recipient("GABBER AND PETER", roster: [gabor, peter]))
        XCTAssertNil(try model.recipient("GABBER WHAT DID PETER SAY", roster: [peter]))
        XCTAssertNil(try model.recipient("THE GARDEN IS QUIET", roster: [gabor, peter]))
        XCTAssertNil(try model.recipient("GABBER AND PEETER", roster: [gabor, peter]))
        XCTAssertNil(try model.recipient("GABBER ARE YOU THERE", roster: [peter]))
    }
    func testUnsupportedSpeechCannotUseAnOverconfidentHead() throws {
        let original = try WakeNameClassifier.train([
            .init(text: "FRANCINE", label: "name"), .init(text: "FRAN SENE", label: "name"),
            .init(text: "THANK YOU", label: "other"), .init(text: "PLEASE CONTINUE", label: "other")])
        var weights = [Float](repeating: 0, count: original.weights.count)
        let row = try XCTUnwrap(original.labels.firstIndex(of: "name"))
        weights[(row + 1) * (original.vocabulary.count + 1) - 1] = 100
        let head = WakeNameClassifier(vocabulary: original.vocabulary, idf: original.idf,
            labels: original.labels, weights: weights, margin: original.margin, prototypes: original.prototypes)
        XCTAssertEqual(try head.prediction("FRANCIN").label, "name")
        XCTAssertEqual(try head.prediction("MY FRIEND CALLED THIS MORNING").label, "other")
        XCTAssertEqual(try head.prediction("THE WEATHER WILL BE BETTER TOMORROW").label, "other")
    }
    func testExactGroupAddressWorksWithoutAnEnrolledHead() throws {
        let peter = UUID(), gabor = UUID()
        let names = [WakeNameModel.Name(id: peter, name: "Peter"), .init(id: gabor, name: "Gabor")]
        let roster: Set<UUID> = [peter, gabor]
        XCTAssertEqual(try WakeNameModel.recipient("Gabor can you answer", names: names, roster: roster, classifier: nil), gabor)
        XCTAssertNil(try WakeNameModel.recipient("the gate is open", names: names, roster: roster, classifier: nil))
        XCTAssertNil(try WakeNameModel.recipient("Peter and Gabor", names: names, roster: roster, classifier: nil))
    }
    private func model() throws -> WakeNameModel {
        let head = try WakeNameClassifier.train([
            .init(text: "PETER", label: "peter"), .init(text: "HEY PETER", label: "peter"),
            .init(text: "HELLO THERE", label: "other"), .init(text: "THE HEATER IS RUNNING", label: "other")])
        return WakeNameModel(fingerprint: "test", names: [.init(id: UUID(), name: "Peter"), .init(id: UUID(), name: "Ad de Jongh")], classifier: head, accepted: true)
    }
    func testCompleteNamesCannotSelectOutsideRosterOrResolveAmbiguousNames() throws {
        let model = try model(), peter = model.names[0].id, ad = model.names[1].id
        XCTAssertEqual(try model.recipient("HEY PETER", roster: [peter]), peter)
        XCTAssertNil(try model.recipient("HEY PETER", roster: [ad]))
        XCTAssertNil(try model.recipient("PETER AND AD DE JONGH", roster: [peter, ad]))
        XCTAssertNil(try model.recipient("THE HEATER IS RUNNING", roster: [peter, ad]))
        XCTAssertNil(try model.recipient("ADD SOME WATER", roster: [peter, ad]))
        XCTAssertEqual(try model.recipient("AD DE JONGH", roster: [ad]), ad)
    }
}

extension WakeNameRoutingTests {
    @MainActor func testImmediatePauseLoadsAcceptedCacheBeforeDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contact = Persona(name: "Peter", prompt: "Test", wakeName: "Peter")
        let identity = try WakeNameTraining.fingerprint([contact])
        let classifier = try WakeNameClassifier.train([
            .init(text: "PETER", label: contact.id.uuidString), .init(text: "HEY PETER", label: contact.id.uuidString),
            .init(text: "HELLO", label: "other"), .init(text: "PLEASE CONTINUE", label: "other")])
        let model = WakeNameModel(fingerprint: identity, names: [.init(id: contact.id, name: "Peter")], classifier: classifier, accepted: true)
        let result = WakeNameTraining.Result(model: model, receipt: .init(positives: 1, correct: 1, negatives: 24))
        try JSONEncoder().encode(result).write(to: directory.appending(path: identity + ".json"))
        let enrollment = WakeNameEnrollment(directory: directory)
        enrollment.update([contact])
        await enrollment.pause()
        XCTAssertEqual(enrollment.model?.fingerprint, identity)
        XCTAssertEqual(enrollment.state, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Features").path))
    }
    @MainActor func testPausePreventsQueuedEnrollmentFromStarting() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let enrollment = WakeNameEnrollment(directory: directory)
        let contact = Persona(name: "Test", prompt: "Test", wakeName: "Test")
        enrollment.update([contact])
        await enrollment.pause()
        XCTAssertEqual(enrollment.state, .queued)
        XCTAssertNil(enrollment.model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        enrollment.resume()
        await enrollment.pause()
        XCTAssertNil(enrollment.model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
