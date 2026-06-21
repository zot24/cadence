import XCTest
@testable import CadenceCore

final class JobOrgTests: XCTestCase {
    func testKnownVendors() {
        XCTAssertEqual(JobOrg.organization(forLabel: "com.docker.socket"), "Docker")
        XCTAssertEqual(JobOrg.organization(forLabel: "com.adobe.ARMDC.Communicator"), "Adobe")
        XCTAssertEqual(JobOrg.organization(forLabel: "com.microsoft.autoupdate.helper"), "Microsoft")
        XCTAssertEqual(JobOrg.organization(forLabel: "org.openvpn.client"), "OpenVPN")
        XCTAssertEqual(JobOrg.organization(forLabel: "dev.orbstack.OrbStack.privhelper"), "OrbStack")
        XCTAssertEqual(JobOrg.organization(forLabel: "at.obdev.littlesnitch.daemon"), "Objective Development")
        XCTAssertEqual(JobOrg.organization(forLabel: "ai.hermes.gateway"), "Hermes")
    }

    func testHyphenSlugTitleCases() {
        XCTAssertEqual(JobOrg.organization(forLabel: "com.paragon-software.extfsd"), "Paragon Software")
    }

    func testGenericFallbackCapitalizes() {
        XCTAssertEqual(JobOrg.organization(forLabel: "com.acmecorp.daemon"), "Acmecorp")
    }

    func testNonReverseDNSIsOther() {
        XCTAssertEqual(JobOrg.organization(forLabel: "news-digest"), "Other")
        XCTAssertEqual(JobOrg.organization(forLabel: "backup"), "Other")
        XCTAssertEqual(JobOrg.organization(forLabel: ""), "Other")
    }
}
