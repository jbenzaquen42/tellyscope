// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TellyscopeCore

final class TransferNameTests: XCTestCase {
    func testTransferPreservesExistingFiles() {
        XCTAssertEqual(availableTransferName("movie.mp4", existing: ["movie.mp4", "movie (1).mp4"]), "movie (2).mp4")
        XCTAssertEqual(availableTransferName("README", existing: ["README"]), "README (1)")
        XCTAssertEqual(availableTransferName("new.txt", existing: []), "new.txt")
    }
}
