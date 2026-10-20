#!/usr/bin/env python3
"""Run actual App model QA against the separately built, offline fixture app."""
import os
from pathlib import Path
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parent.parent
os.chdir(root)
derived = root / ".build/xcode-fixtures"
products = derived / "Build/Products/Debug"
binary_dir = products / "MergeProFixtures.app/Contents/MacOS"
if sys.argv[1:] not in [[], ["--local-folders"], ["--local-workspace"]]:
    raise SystemExit("Usage: python3 scripts/qa-workspace-models.py [--local-folders|--local-workspace]")
local_folders = sys.argv[1:] == ["--local-folders"]
local_workspace = sys.argv[1:] == ["--local-workspace"]
harness = "LocalFolderQAHarness.swift" if local_folders else "LocalWorkspaceQAHarness.swift" if local_workspace else "WorkspaceQAHarness.swift"
evidence = root / (".build/evidence/local-folder-qa" if local_folders else ".build/evidence/local-workspace-qa" if local_workspace else ".build/evidence/workspace-model-qa")
evidence.mkdir(parents=True, exist_ok=True)
if not (binary_dir / "MergeProFixtures.debug.dylib").exists():
    raise SystemExit("Build the separate fixture app first: scripts/build-local.sh --fixtures")

args = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macos26.0",
        "-I", str(products), "-I", str(products / "include")]
if local_folders:
    args += ["-D", "LOCAL_FOLDER_VERIFICATION"]
for include in ["GRDB.swift/Sources/GRDBSQLite", "Yams/Sources/CYaml/include",
                "swift-cmark/src/include", "swift-cmark/extensions/include",
                "swift-markdown/Sources/CAtomic/include"]:
    args += ["-I", str(derived / "SourcePackages/checkouts" / include)]
for module in sorted((derived / "Build/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap")):
    if module.stem.startswith("TreeSitter") or module.stem in {"COnigBridge", "Oniguruma"}:
        args += ["-Xcc", "-fmodule-map-file=" + str(module)]
args += ["-F", str(products / "PackageFrameworks"),
         "Tests/MergeProModelTests/" + harness,
         str(binary_dir / "MergeProFixtures.debug.dylib"),
         "-Xlinker", "-rpath", "-Xlinker", str(binary_dir),
         "-o", str(evidence / "workspace-model-qa")]
with (evidence / "compile.log").open("w") as log:
    result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print((evidence / "compile.log").read_text())
    raise SystemExit(result.returncode)

environment = dict(os.environ, MERGEPRO_UI_TEST_NAMESPACE=str(uuid.uuid4()),
                   MERGEPRO_PHASE23_FIXTURES="1", MERGEPRO_PHASE23_REPO_COUNT="120")
result = subprocess.run([str(evidence / "workspace-model-qa")], env=environment,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(evidence / "run.log").write_text(result.stdout)
print(result.stdout, end="")
raise SystemExit(result.returncode)
