import XCTest

@testable import MergeProCore

/// Label chip text is chosen against the colours actually drawn: the label fill and either white or the chip's
/// soft dark gray (sRGB 0.08), falling back to pure black, so every fill reaches WCAG AA 4.5:1.
final class LabelContrastTests: XCTestCase {
  private func luminance(gray: Double) -> Double {
    gray <= 0.04045 ? gray / 12.92 : pow((gray + 0.055) / 1.055, 2.4)
  }
  private func contrast(_ hex: String, gray: Double) throws -> Double {
    let fill = try XCTUnwrap(RepositoryLabel.relativeLuminance(hex: hex))
    let text = luminance(gray: gray)
    return (max(fill, text) + 0.05) / (min(fill, text) + 0.05)
  }

  func testMidLuminanceGitHubColorsReachAA() throws {
    // With the soft 0.08 gray these drew about 4.1:1; the chip now draws white or black where the gray fails.
    for hex in ["0e8a16", "d93f0b"] {
      let choice = try XCTUnwrap(RepositoryLabel.chipText(hex: hex))
      XCTAssertGreaterThanOrEqual(try contrast(hex, gray: choice.gray), 4.5, hex)
      XCTAssertEqual(choice.contrast, try contrast(hex, gray: choice.gray), accuracy: 1e-9)
      XCTAssertLessThan(try contrast(hex, gray: 0.08), 4.5, "\(hex) is the case the soft gray could not cover")
    }
  }

  func testEveryFillReachesAAAndSoftGrayIsKeptWhereItSuffices() throws {
    let palette = ["b60205", "d93f0b", "fbca04", "0e8a16", "006b75", "1d76db", "0052cc", "5319e7",
                   "e99695", "f9d0c4", "fef2c0", "c2e0c6", "bfdadc", "c5def5", "bfd4f2", "d4c5f9", "ededed", "000000", "ffffff"]
    var sweep: [String] = palette
    for r in stride(from: 0, through: 255, by: 15) {
      for g in stride(from: 0, through: 255, by: 15) {
        for b in stride(from: 0, through: 255, by: 15) { sweep.append(String(format: "%02x%02x%02x", r, g, b)) }
      }
    }
    for hex in sweep {
      let choice = try XCTUnwrap(RepositoryLabel.chipText(hex: hex), hex)
      XCTAssertTrue([1, 0.08, 0].contains(choice.gray), hex)
      XCTAssertGreaterThanOrEqual(choice.contrast, 4.5, hex)
      XCTAssertEqual(choice.contrast, try contrast(hex, gray: choice.gray), accuracy: 1e-9, hex)
      if choice.gray == 0 { XCTAssertLessThan(try contrast(hex, gray: 0.08), 4.5, "black only replaces a failing soft gray: \(hex)") }
      XCTAssertEqual(RepositoryLabel.prefersDarkText(hex: hex), choice.isDark, hex)
    }
  }

  func testIncreasedContrastPrefersTheStrongerExtreme() throws {
    // At 7:1 no mid-luminance fill qualifies, so the higher of white and black is used.
    let choice = try XCTUnwrap(RepositoryLabel.chipText(hex: "0e8a16", minimumContrast: 7))
    XCTAssertEqual(choice.gray, 0)
    XCTAssertEqual(try XCTUnwrap(RepositoryLabel.chipText(hex: "ffffff", minimumContrast: 7)).gray, 0.08)
    XCTAssertEqual(try XCTUnwrap(RepositoryLabel.chipText(hex: "000000", minimumContrast: 7)).gray, 1)
    XCTAssertNil(RepositoryLabel.chipText(hex: "nothex"))
  }
}
