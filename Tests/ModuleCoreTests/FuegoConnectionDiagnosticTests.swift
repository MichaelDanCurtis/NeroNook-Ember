import XCTest
@testable import ModuleCore

final class FuegoConnectionDiagnosticTests: XCTestCase {
    let company = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private func projection(_ kind: String = "humanWebSession", _ status: Any = 200,
                            catalog: String = "eligible", catalogStatus: Any = 200) -> [String: Any] {
        ["sessionKind": kind, "sessionHTTPStatus": status, "catalogRead": catalog, "catalogHTTPStatus": catalogStatus]
    }
    func testClosedDiagnosticPreservesSelectedCompanyWithoutAuthorityFields() {
        let value = FuegoConnectionDiagnostic.decode(projection(), company: company)
        XCTAssertEqual(value.selectedCompany, company); XCTAssertEqual(value.sessionKind, .humanWebSession)
        XCTAssertEqual(value.catalogRead, .eligible)
        XCTAssertEqual(value.checked(company: company, samePage: true), value)
    }
    func testNoCompanyStaysUnknownForCatalogAndNeverChoosesOne() {
        let value = FuegoConnectionDiagnostic.decode(projection(catalog: "unknown", catalogStatus: 0), company: nil)
        XCTAssertNil(value.selectedCompany); XCTAssertEqual(value.sessionKind, .humanWebSession)
        XCTAssertEqual(value.catalogRead, .unknown); XCTAssertEqual(value.catalogHTTPStatus, 0)
        XCTAssertEqual(FuegoConnectionDiagnostic.decode(projection(), company: nil), .unknown(company: nil))
    }
    func testNavigationCancellationOrSelectionChangeDropsOldProjection() {
        let value = FuegoConnectionDiagnostic.decode(projection(), company: company)
        XCTAssertEqual(value.checked(company: company, samePage: false), .unknown(company: company))
        XCTAssertEqual(value.checked(company: nil, samePage: true), .unknown(company: nil))
        let other = UUID()
        XCTAssertEqual(value.checked(company: other, samePage: true), .unknown(company: other))
    }
    func testKeysImplicitProfilesAndUnknownResponsesCannotClaimEligible() {
        for kind in ["boardKey", "localImplicit", "unknown"] {
            XCTAssertEqual(FuegoConnectionDiagnostic.decode(projection(kind), company: company), .unknown(company: company))
        }
        var extra = projection(); extra["credential"] = "AUTHORED_NOT_A_SECRET"
        XCTAssertEqual(FuegoConnectionDiagnostic.decode(extra, company: company), .unknown(company: company))
        for status: Any in [true, 200.5, -1, 600, "200"] {
            XCTAssertEqual(FuegoConnectionDiagnostic.decode(projection("humanWebSession", status), company: company), .unknown(company: company))
        }
    }
    func testCatalogFailureIsNotOwnerOrRegistrationAuthority() {
        let forbidden = FuegoConnectionDiagnostic.decode(projection(catalog: "denied", catalogStatus: 403), company: company)
        XCTAssertEqual(forbidden.sessionKind, .humanWebSession); XCTAssertEqual(forbidden.catalogRead, .denied)
        let missing = FuegoConnectionDiagnostic.decode(projection(catalog: "unavailable", catalogStatus: 404), company: company)
        XCTAssertEqual(missing.catalogRead, .unavailable)
        let expired = FuegoConnectionDiagnostic.decode(projection("signedOut", catalog: "denied", catalogStatus: 401), company: company)
        XCTAssertEqual(expired.sessionKind, .signedOut); XCTAssertEqual(expired.catalogRead, .denied)
        XCTAssertEqual(FuegoConnectionDiagnostic.decode(projection("humanWebSession", 401), company: company), .unknown(company: company))
    }
}
