// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name:"MergeProRendering",platforms:[.macOS("26.0")],
    products:[.library(name:"MergeProRendering",targets:["MergeProRendering"])],
    dependencies:[
        .package(url:"https://github.com/swiftlang/swift-cmark.git",exact:"0.9.0"),
        .package(url:"https://github.com/swiftlang/swift-markdown",exact:"0.7.3"),
        .package(url:"https://github.com/tree-sitter/swift-tree-sitter",exact:"0.25.0"),
        .package(url:"https://github.com/tree-sitter/tree-sitter",exact:"0.25.10"),
        .package(url:"https://github.com/alex-pinkus/tree-sitter-swift",exact:"0.7.3-with-generated-files"),
        .package(url:"https://github.com/tree-sitter/tree-sitter-bash",exact:"0.25.1"),
        .package(url:"https://github.com/tree-sitter-grammars/tree-sitter-markdown",exact:"0.5.3")
    ],
    targets:[
        .target(name:"Oniguruma",path:"Vendor/oniguruma",exclude:["COPYING"],sources:["src/regparse.c", "src/regcomp.c", "src/regexec.c", "src/regenc.c", "src/regerror.c", "src/regext.c", "src/regsyntax.c", "src/regtrav.c", "src/regversion.c", "src/st.c", "src/reggnu.c", "src/unicode.c", "src/unicode_unfold_key.c", "src/unicode_fold1_key.c", "src/unicode_fold2_key.c", "src/unicode_fold3_key.c", "src/ascii.c", "src/utf8.c", "src/utf16_be.c", "src/utf16_le.c", "src/utf32_be.c", "src/utf32_le.c", "src/euc_jp.c", "src/euc_jp_prop.c", "src/sjis.c", "src/sjis_prop.c", "src/iso8859_1.c", "src/iso8859_2.c", "src/iso8859_3.c", "src/iso8859_4.c", "src/iso8859_5.c", "src/iso8859_6.c", "src/iso8859_7.c", "src/iso8859_8.c", "src/iso8859_9.c", "src/iso8859_10.c", "src/iso8859_11.c", "src/iso8859_13.c", "src/iso8859_14.c", "src/iso8859_15.c", "src/iso8859_16.c", "src/euc_tw.c", "src/euc_kr.c", "src/big5.c", "src/gb18030.c", "src/koi8_r.c", "src/cp1251.c", "src/onig_init.c"],publicHeadersPath:"include",cSettings:[.headerSearchPath("src")]),
        .target(name:"TreeSitterJavaScript",path:"Vendor/javascript",sources:["src/parser.c","src/scanner.c"],publicHeadersPath:"include",cSettings:[.headerSearchPath("src")]),
        .target(name:"TreeSitterPython",path:"Vendor/python",sources:["src/parser.c","src/scanner.c"],publicHeadersPath:"include",cSettings:[.headerSearchPath("src")]),
        .target(name:"TreeSitterYAML",path:"Vendor/yaml",sources:["src/parser.c","src/scanner.c"],publicHeadersPath:"include",cSettings:[.headerSearchPath("src")]),
        .target(name:"COnigBridge",dependencies:["Oniguruma"]),
        .target(name:"TreeSitterTypeScript",path:"Vendor/typescript",sources:["typescript/src/parser.c","typescript/src/scanner.c"],publicHeadersPath:"include",cSettings:[.headerSearchPath("typescript/src")]),
        .target(name:"TreeSitterTSX",path:"Vendor/typescript",sources:["tsx/src/parser.c","tsx/src/scanner.c"],publicHeadersPath:"tsx-include",cSettings:[.headerSearchPath("tsx/src")]),
        .target(name:"TreeSitterJSON",path:"Vendor/json",sources:["src/parser.c"],publicHeadersPath:"include",cSettings:[.headerSearchPath("src")]),
        .target(name:"MergeProRendering",dependencies:[.product(name:"Markdown",package:"swift-markdown"),"COnigBridge","TreeSitterTypeScript","TreeSitterTSX","TreeSitterJSON",
            .product(name:"TreeSitter",package:"tree-sitter"),.product(name:"SwiftTreeSitter",package:"swift-tree-sitter"),.product(name:"TreeSitterSwift",package:"tree-sitter-swift"),
            "TreeSitterJavaScript","TreeSitterPython",
            "TreeSitterYAML",.product(name:"TreeSitterBash",package:"tree-sitter-bash"),.product(name:"TreeSitterMarkdown",package:"tree-sitter-markdown")],
            resources:[.copy("Resources")],linkerSettings:[.linkedFramework("JavaScriptCore")]),
        .testTarget(name:"MergeProRenderingTests",dependencies:["MergeProRendering"],resources:[.copy("Fixtures")])
    ],swiftLanguageModes:[.v6],cLanguageStandard:.c11
)
