import XCTest
@testable import UnsitCore

final class UpdateCheckTests: XCTestCase {
    func testComparesDottedNumbers() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.9"), "parts compare as numbers, not text")
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.99.99"))
    }

    func testIgnoresTagPrefixSuffixesAndMissingParts() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.3.0", than: "0.2.0"), "release tags start with v")
        XCTAssertFalse(UpdateCheck.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2.0-beta", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.2.1-beta", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("", than: "0.2.0"), "an empty version is never an update")
        XCTAssertFalse(UpdateCheck.isNewer("not a version", than: "0.2.0"))
    }

    func testDisplayDropsTheTagPrefix() {
        XCTAssertEqual(UpdateCheck.display("v0.3.0"), "0.3.0")
        XCTAssertEqual(UpdateCheck.display("0.3.0"), "0.3.0")
    }

    func testReadsTheLatestRelease() throws {
        let json = #"{"tag_name":"v0.3.0","html_url":"https://github.com/jorgesousa/Unsit/releases/tag/v0.3.0","name":"Walks"}"#
        let latest = try XCTUnwrap(UpdateCheck.latest(fromReleaseJSON: Data(json.utf8)))
        XCTAssertEqual(latest.version, "v0.3.0")
        XCTAssertEqual(latest.url?.absoluteString, "https://github.com/jorgesousa/Unsit/releases/tag/v0.3.0")

        XCTAssertNil(UpdateCheck.latest(fromReleaseJSON: Data(#"{"message":"Not Found"}"#.utf8)),
                     "a repo with no releases answers 404 with no tag_name")
        XCTAssertNil(UpdateCheck.latest(fromReleaseJSON: Data("not json".utf8)))
    }

    func testFindsTheAppZipInTheRelease() throws {
        let json = """
            {"tag_name":"v0.6.0","html_url":"https://github.com/jorgesousa/Unsit/releases/tag/v0.6.0","assets":[
              {"name":"Unsit.dmg","browser_download_url":"https://github.com/jorgesousa/Unsit/releases/download/v0.6.0/Unsit.dmg"},
              {"name":"Unsit.zip","browser_download_url":"https://github.com/jorgesousa/Unsit/releases/download/v0.6.0/Unsit.zip"}]}
            """
        let latest = try XCTUnwrap(UpdateCheck.latest(fromReleaseJSON: Data(json.utf8)))
        XCTAssertEqual(latest.appZip?.absoluteString, "https://github.com/jorgesousa/Unsit/releases/download/v0.6.0/Unsit.zip")

        let noZip = #"{"tag_name":"v0.6.0","assets":[{"name":"Unsit.dmg","browser_download_url":"https://x/Unsit.dmg"}]}"#
        XCTAssertNil(try XCTUnwrap(UpdateCheck.latest(fromReleaseJSON: Data(noZip.utf8))).appZip,
                     "without a zip, the app can't install the update itself")
        let noAssets = #"{"tag_name":"v0.6.0"}"#
        XCTAssertNil(try XCTUnwrap(UpdateCheck.latest(fromReleaseJSON: Data(noAssets.utf8))).appZip)
    }

    func testReadsTheVersionFromAnInfoPlist() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleName</key><string>Unsit</string>
                <key>CFBundleShortVersionString</key><string>0.4.2</string>
            </dict>
            </plist>
            """
        XCTAssertEqual(UpdateCheck.version(fromInfoPlist: Data(plist.utf8)), "0.4.2")
        XCTAssertNil(UpdateCheck.version(fromInfoPlist: Data("junk".utf8)))
    }
}
