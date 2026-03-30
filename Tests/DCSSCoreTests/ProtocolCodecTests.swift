import DCSSCore
import Foundation
import XCTest

final class ProtocolCodecTests: XCTestCase {
    private let codec = ProtocolCodec()

    func testDecodeHelloFixture() throws {
        let data = try fixture(named: "hello")
        let event = try codec.decode(data: data)

        XCTAssertEqual(event, .hello(serverVersion: "0.32-webtiles"))
    }

    func testDecodeFrameFixture() throws {
        let data = try fixture(named: "frame")
        let event = try codec.decode(data: data)

        XCTAssertEqual(
            event,
            .gameFrame(grid: ["##########", "#..@.....#", "##########"], statusLine: "HP 24/24 MP 3/3")
        )
    }

    func testDecodeFlattenedMessageFormat() throws {
        let data = Data("{\"msg\":\"msg\",\"message\":\"You feel healthy.\"}".utf8)
        let event = try codec.decode(data: data)

        XCTAssertEqual(event, .message(text: "You feel healthy."))
    }

    func testEncodeInputCommand() throws {
        let data = try codec.encode(command: .input(command: "o"))
        let envelope = try JSONDecoder().decode(DCSSWireEnvelope.self, from: data)

        XCTAssertEqual(envelope.type, "input")
        XCTAssertEqual(envelope.payload["command"], .string("o"))
    }

    private func fixture(named: String) throws -> Data {
        let bundle = Bundle.module
        let url = try XCTUnwrap(bundle.url(forResource: named, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
