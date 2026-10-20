import Foundation

enum LocalGitExecutableChoice: String, CaseIterable, Identifiable {
    case system = "/usr/bin/git"
    case xcode = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
    case commandLineTools = "/Library/Developer/CommandLineTools/usr/bin/git"
    var id: String { rawValue }
    var label: String {
        switch self { case .system: "System Git"; case .xcode: "Xcode Git"; case .commandLineTools: "Command Line Tools Git" }
    }
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: rawValue) }
}
