import ContinuityKit
import XCTest

final class BearerTokenValidatorTests: XCTestCase {
    func testAcceptsCorrectToken() {
        let token = BearerTokenValidator.mintToken()
        let validator = BearerTokenValidator(token: token)
        XCTAssertTrue(validator.validate(authorizationHeader: "Bearer \(token)"))
    }

    func testRejectsWrongToken() {
        let validator = BearerTokenValidator(token: BearerTokenValidator.mintToken())
        XCTAssertFalse(validator.validate(authorizationHeader: "Bearer \(BearerTokenValidator.mintToken())"))
    }

    func testRejectsMalformedHeaders() {
        let token = BearerTokenValidator.mintToken()
        let validator = BearerTokenValidator(token: token)
        XCTAssertFalse(validator.validate(authorizationHeader: nil))
        XCTAssertFalse(validator.validate(authorizationHeader: ""))
        XCTAssertFalse(validator.validate(authorizationHeader: token))
        XCTAssertFalse(validator.validate(authorizationHeader: "Basic \(token)"))
        XCTAssertFalse(validator.validate(authorizationHeader: "bearer \(token)"))
    }

    func testMintedTokensAreUniqueAndURLSafe() {
        let tokens = (0..<100).map { _ in BearerTokenValidator.mintToken() }
        XCTAssertEqual(Set(tokens).count, tokens.count)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for token in tokens {
            XCTAssertTrue(token.unicodeScalars.allSatisfy(allowed.contains), "token not URL-safe: \(token)")
        }
    }
}
