import Foundation
@testable import PluralismCore
import XCTest

final class UnattendTests: XCTestCase {
    func makeInput(password: String = "geheim", language: String? = "de-DE") -> UnattendBuilder.Input {
        var settings = UnattendSettings(userName: "Musti")
        settings.computerName = "Pluralism-Win"
        return UnattendBuilder.Input(settings: settings, password: password, mediaLanguage: language, enableRemoteDesktop: true)
    }

    func testXMLContainsAllPasses() {
        let xml = UnattendBuilder.makeAutounattendXML(makeInput())
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>"))
        for pass in ["windowsPE", "specialize", "oobeSystem"] {
            XCTAssertTrue(xml.contains("<settings pass=\"\(pass)\">"), pass)
        }
        XCTAssertTrue(xml.contains("processorArchitecture=\"arm64\""))
        XCTAssertFalse(xml.contains("amd64"))
        XCTAssertEqual(xml.components(separatedBy: "<unattend ").count, 2)
        XCTAssertTrue(xml.hasSuffix("</unattend>\n"))
    }

    func testHardwareChecksAreBypassed() {
        let xml = UnattendBuilder.makeAutounattendXML(makeInput())
        for check in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck"] {
            XCTAssertTrue(xml.contains("/v \(check) /t REG_DWORD /d 1 /f"), check)
        }
        XCTAssertTrue(xml.contains("BypassNRO"))

        var input = makeInput()
        input.settings.bypassHardwareChecks = false
        XCTAssertFalse(UnattendBuilder.makeAutounattendXML(input).contains("BypassTPMCheck"))
    }

    func testAccountDiskAndEdition() {
        let xml = UnattendBuilder.makeAutounattendXML(makeInput())
        XCTAssertTrue(xml.contains("<Name>Musti</Name>"))
        XCTAssertTrue(xml.contains("<Group>Administrators</Group>"))
        XCTAssertTrue(xml.contains("<HideOnlineAccountScreens>true</HideOnlineAccountScreens>"))
        XCTAssertTrue(xml.contains("<ComputerName>Pluralism-Win</ComputerName>"))
        XCTAssertTrue(xml.contains("<Type>EFI</Type>"))
        XCTAssertTrue(xml.contains("<Type>MSR</Type>"))
        XCTAssertTrue(xml.contains("<Value>Windows 11 Pro</Value>"))
        XCTAssertTrue(xml.contains(UnattendSettings.windows11ProKMSClientKey))
        XCTAssertTrue(xml.contains("<UILanguage>de-DE</UILanguage>"))
        XCTAssertTrue(xml.contains("<InputLocale>0407:00000407</InputLocale>"))
        XCTAssertTrue(xml.contains("<TimeZone>W. Europe Standard Time</TimeZone>"))
    }

    func testUnknownMediaLanguageIsOmitted() {
        let xml = UnattendBuilder.makeAutounattendXML(makeInput(language: nil))
        XCTAssertFalse(xml.contains("SetupUILanguage"))
        XCTAssertFalse(xml.contains("<UILanguage>"))
        XCTAssertTrue(xml.contains("<SystemLocale>de-DE</SystemLocale>"))
    }

    func testPasswordIsEscaped() {
        let xml = UnattendBuilder.makeAutounattendXML(makeInput(password: "a<b>&\"c'"))
        XCTAssertTrue(xml.contains("<Value>a&lt;b&gt;&amp;&quot;c&apos;</Value>"))
        XCTAssertFalse(xml.contains("a<b>"))
    }

    func testFirstLogonRunsSetupScript() {
        let xml = UnattendBuilder.makeAutounattendXML(makeInput())
        XCTAssertTrue(xml.contains("<FirstLogonCommands>"))
        XCTAssertTrue(xml.contains("call %i:\\pluralism-setup.cmd"))
    }

    func testSetupScript() {
        let script = UnattendBuilder.makeSetupScript(makeInput())
        XCTAssertTrue(script.hasPrefix("@echo off\r\n"))
        XCTAssertTrue(script.contains("pnputil /add-driver \"%PLURALISMSRC%\\pluralism-drivers\\*.inf\" /subdirs /install"))
        XCTAssertFalse(script.contains("guest-tools"))
        XCTAssertTrue(script.contains("fDenyTSConnections"))
        XCTAssertTrue(script.contains("@FirewallAPI.dll,-28752"))
        XCTAssertFalse(script.contains("\n\n"))

        var input = makeInput()
        input.enableRemoteDesktop = false
        input.settings.installGuestDrivers = false
        let minimal = UnattendBuilder.makeSetupScript(input)
        XCTAssertFalse(minimal.contains("fDenyTSConnections"))
        XCTAssertFalse(minimal.contains("pnputil"))
    }

    func testComputerNameSanitizing() {
        XCTAssertEqual(UnattendBuilder.sanitizedComputerName("Mein Rechner!"), "MeinRechner")
        XCTAssertEqual(UnattendBuilder.sanitizedComputerName("ein-sehr-langer-rechnername"), "ein-sehr-langer")
        XCTAssertEqual(UnattendBuilder.sanitizedComputerName("12345"), "PLURALISM-WIN")
        XCTAssertEqual(UnattendBuilder.sanitizedComputerName("--"), "PLURALISM-WIN")
    }

    func testUserNameSanitizing() {
        XCTAssertEqual(UnattendBuilder.sanitizedUserName("Musti"), "Musti")
        XCTAssertEqual(UnattendBuilder.sanitizedUserName("mu/sti@home"), "mustihome")
        XCTAssertEqual(UnattendBuilder.sanitizedUserName("Administrator"), "Benutzer")
        XCTAssertEqual(UnattendBuilder.sanitizedUserName("   "), "Benutzer")
    }

    func testLangIniParsing() {
        let ini = "[Available UI Languages]\r\nde-DE = 3\r\n\r\n[Fallback Languages]\r\nde-DE = en-us\r\n"
        XCTAssertEqual(UnattendBuilder.parseLanguage(fromLangIni: ini), "de-DE")
        XCTAssertNil(UnattendBuilder.parseLanguage(fromLangIni: "[Other]\nx = 1"))
    }

    func testDriverPaths() {
        XCTAssertEqual(UnattendBuilder.virtioDriverPath("NetKVM"), "NetKVM/w11/ARM64")
        XCTAssertTrue(UnattendBuilder.virtioDriverFolders.contains("NetKVM"))
        XCTAssertTrue(UnattendBuilder.virtioDriverFolders.contains("viogpudo"))
        // Isolation: kein Treiber für Kanäle zwischen Mac und Gast
        XCTAssertFalse(UnattendBuilder.virtioDriverFolders.contains("vioserial"))
        XCTAssertFalse(UnattendBuilder.virtioDriverFolders.contains("viofs"))
    }

}
