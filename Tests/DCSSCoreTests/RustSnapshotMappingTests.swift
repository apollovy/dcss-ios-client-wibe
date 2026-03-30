import XCTest
import DCSSCore
import DCSSCoreFFI

final class RustSnapshotMappingTests: XCTestCase {
    func testMapsSnapshotJSONToGameState() {
        let json = """
        {
          "connectionState": { "type": "connected" },
          "gameState": {
            "grid": ["##########", "#..@.....#", "##########"],
            "statusLine": "HP 24/24 MP 3/3",
            "lastMessage": "You feel healthy."
          },
          "diagnostics": {
            "lastEventType": "frame",
            "reconnectAttempt": null,
            "lastError": null,
            "lastConnectedAt": "2026-03-30T12:00:00Z"
          }
        }
        """

        let (connection, game, diagnostics) = RustSnapshotMapper.mapSnapshotJSON(json)

        XCTAssertEqual(connection, .connected)
        XCTAssertEqual(game.grid, ["##########", "#..@.....#", "##########"])
        XCTAssertEqual(game.statusLine, "HP 24/24 MP 3/3")
        XCTAssertEqual(game.lastMessage, "You feel healthy.")

        XCTAssertEqual(diagnostics.lastEventType, "frame")
        XCTAssertNil(diagnostics.reconnectAttempt)
        XCTAssertNil(diagnostics.lastError)
        XCTAssertNotNil(diagnostics.lastConnectedAt)
    }
}

