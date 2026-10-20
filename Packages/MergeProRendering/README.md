# Native code rendering

`CodeTokenizer.shared` serializes parser and JavaScriptCore work and returns Sendable UTF-16 ranges/scopes/symbols. `NativeCodeSurface` is a read-only selectable AppKit/TextKit 2 scroll surface. No browser, Node, runtime grammar download, filesystem/network bridge or credentials enter tokenization. Entire source is parsed; diff callers map tokens back onto canonical hunk rows. Plain text survives unknown language, grammar/query/ABI errors and bounds.

First Tree-sitter language families: Swift, JavaScript/JSX, TypeScript/TSX, Python, JSON, YAML, Bash and Markdown. JSONC, full zsh/fish and arbitrary custom grammars are not advertised. A bundled application-owned INI/CFG TextMate grammar exercises the real fallback engine, including multiline state. CSS and HTML use an application-owned lexical scanner for comments, strings, declarations, tags and attributes; embedded script/style parsing is not advertised. CJS/MTS/CTS reuse the JavaScript/TypeScript grammars, and zsh files use the Bash grammar for common shell syntax. Unsupported languages retain native plain text.

Exact sources are recorded in `Package.resolved` and `upstream-inventory.json`. The latter gives original upstream paths, revision, license and SHA-256 for every vendored upstream source/query/bundle/license. Run `python3 Tools/verify-upstream.py` from this package. `Vendor` generated parsers/scanners and regex sources are unmodified upstream; application-owned export headers and `Vendor/oniguruma/src/config.h` are listed separately below.

| Component | Exact revision | License |
| --- | --- | --- |
| SwiftTreeSitter 0.25.0 | 08ef81eb8620617b55b08868126707ad72bf754f | BSD-3-Clause |
| Tree-sitter 0.25.10 | da6fe9beb4f7f67beb75914ca8e0d48ae48d6406 | MIT |
| Swift 0.7.3-with-generated-files | 31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5 | MIT |
| JavaScript 0.25.0 | 44c892e0be055ac465d5eeddae6d3e194424e7de | MIT |
| TypeScript/TSX 0.23.2 | f975a621f4e7f532fe322e13c4f79495e0a7b2e7 | MIT |
| Python 0.25.0 | 293fdc02038ee2bf0e2e206711b69c90ac0d413f | MIT |
| JSON 0.24.8 | ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24 | MIT |
| YAML 0.7.2 | 7708026449bed86239b1cd5bce6e3c34dbca6415 | MIT |
| Bash 0.25.1 | a06c2e4415e9bc0346c6b86d401879ffb44058f7 | MIT |
| Markdown 0.5.3 | f969cd3ae3f9fbd4e43205431d0ae286014c05b5 | MIT |
| vscode-textmate 9.3.2 | 25b68dad91920b1ed79d357534b8c4582f62d80d | MIT |
| Oniguruma 6.9.10 | 4ef89209a239c1aea328cf13c05a2807e5c146d1 | BSD-2-Clause |

SwiftPM builds compatible exact products. TS/JSON manifests use the older ChimeHQ wrapper identity; The initial integrated JS/Python/YAML link produced undefined external-scanner symbols. Their conditional relative-path manifest source selection was inspected; a later standalone dump includes scanner.c, so the exact manifest-working-directory cause remains unproven. Those exact generated sources are narrowly vendored instead. No engine version was substituted. `include/*.h`, `tsx-include/tsx.h` are application-owned exported grammar declarations. The Oniguruma `config.h` is an application-owned Darwin LP64 configuration, separate from archived upstream sources; shipping another ABI requires validation. All redistribution notices are bundled with resources, including `TextMate-LICENSE.md`.

`Resources/vscode-textmate.js` is the release UMD artifact, with npm artifact hash/integrity recorded in the inventory. Only that immutable bundle and the application facade execute in local JavaScriptCore. Source/grammar strings are passed as data. Scanner/context pointers and rule stacks stay within a synchronous serialized worker turn. No unchecked Sendable pointer ownership is used. The C adapter owns regex sets, uses explicit UTF-8 lengths, translates Unicode positions to UTF-16 and bounds retries/stack/capture count. Oniguruma is archived; continued vulnerability monitoring and patch ownership are required.

Bounds: source 2 MB, TextMate line 32,768 UTF-16 units, per-line 20 ms/full-document 2 s, scanner input 128 KB, 512 patterns, 16 KB/pattern, 256 captures, native regex retry/stack limits. Tree-sitter parse/query/symbol traversal has time/count bounds. These are graceful fallback budgets, not measured worst-case latency guarantees.

`Tools/generate-conformance.cjs` generates exact scope/range fixtures against pinned vscode-textmate 9.3.2 plus vscode-oniguruma 2.0.1 (reference revision 184a6e2d4603c5a31efc0a33f544be1545d9ec6b, MIT; its WASM uses Oniguruma 6.9.8). This is a test reference only, not shipped runtime code. Nine semantic fixtures cover multiline state, begin/while, captures/contentName/retokenization, heredoc backreferences, repository/external/$self/$base includes, injections, end-pattern priority, zero-width, CRLF/NUL/Unicode. Native 6.9.10 matching these fixtures is not a claim of all-regex equivalence. Run `swift test --package-path Packages/MergeProRendering` from the repository root.

`CodeDocument` retains the exact source and indexes physical UTF-16 line ranges, including CRLF and a trailing empty line. Repository browsing uses these for a separate line-number ruler, repeated line jumps and capped literal case-insensitive find navigation. Blob decoding, line indexing, search and tokenization run away from the main actor. Search debounces typing and cancels superseded work; highlight results carry a source/path/language identity so they cannot style a newly selected file. Native installation skips unchanged text/style/token updates, and an overlap-aware token index restricts viewport styling without changing token precedence. Syntax colors preserve the selected theme with readable light/dark variants.

## Markdown and review gutters

`NativeMarkdownWorker.shared` parses Markdown on a serialized actor using swift-markdown 0.7.3 (`7d9a5ce307528578dfa777d505496bd5f544ad94`, Apache-2.0 with Swift exception) and its exact swift-cmark 0.9.0 runtime (`08ddb528923cc1a6527e02b7a1aee9e516ca749a`, BSD-2-Clause/MIT; complete COPYING bundled). Both are exact SwiftPM products; upstream source is unchanged. Only immutable Sendable presentation values cross to SwiftUI. Tables, reference links/images, task lists, nested lists/quotes, emphasis/strong/strike/code and fences use the AST. Raw HTML is literal text. Relative, credential-bearing and non-HTTP(S) URLs remain inert. Images use the separate explicit-user-action anonymous approved-origin asset policy.

The parser accepts at most 262,144 UTF-8 bytes, then conversion allows 4,096 nodes/emitted runs and depth 24; tables allow 16 columns and 128 body rows. Oversized/deep input falls back to bounded source plus the exact web link. These bound input and presentation work, not worst-case parser latency. Foundation link detection operates only on plain AST text runs outside existing links/images and code; HTTP(S)/www links are supported with detector punctuation handling, while email/mailto and other schemes remain literal. This native layer does not claim byte-for-byte cmark autolink-extension equivalence.

`CodeReviewGutter` is a native TextKit 2 ruler. It maps UTF-16 source ranges to actual viewport line fragments, including wrapped Unicode, and exposes change/comment/annotation markers and selection without switching to TextKit 1. `DiffPresentation` supplies revision-bound content coordinates; `DiffContext` separately verifies decoded full sources against every hunk and omitted gap before incremental expansion. Provider comment writes must use `DiffDocument.providerCommentLocation(for:)`, not a rendering anchor's LEFT blob path or SHA: the result uses the canonical changed-file path and reviewed PR head. This local mapping requires original-patch eligibility and does not provide a server-side current-head/base guarantee.
