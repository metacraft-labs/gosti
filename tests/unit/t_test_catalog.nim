# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## No mocks: validate the checkout, then exercise drift rejection with actual
## catalog files and test sources in a private temporary directory.
import std/[os, tempfiles, unittest]
import ../../scripts/test_catalog

const root = currentSourcePath().parentDir.parentDir.parentDir

suite "shared test catalog":
  test "the checkout has no missing, duplicate or unregistered test programs":
    check loadTestCatalog(root).selectedTests("test").len > 0

  test "catalog drift fails before either runner can report success":
    let work = createTempDir("gosti-catalog-", "")
    defer: removeDir(work)
    for dir in ["scripts", "tests/unit", "tests/integration", "tests/e2e"]:
      createDir(work / dir)
    let catalog = work / "scripts/test-catalog.txt"
    writeFile(work / "tests/unit/t_example.nim", "discard\n")
    const entry = "test all tests/unit/t_example.nim\n"
    writeFile(catalog, entry)
    check loadTestCatalog(work).selectedTests("test").len == 1

    writeFile(work / "tests/unit/t_forgotten.nim", "discard\n")
    expect ValueError: discard loadTestCatalog(work)
    removeFile(work / "tests/unit/t_forgotten.nim")
    writeFile(catalog, entry & entry)
    expect ValueError: discard loadTestCatalog(work)
    writeFile(catalog, "test alll tests/unit/t_example.nim\n")
    expect ValueError: discard loadTestCatalog(work)
    writeFile(catalog, "test all tests/unit/t_missing.nim\n")
    expect ValueError: discard loadTestCatalog(work)
    writeFile(catalog, entry)
    check loadTestCatalog(work).selectedTests("test").len == 1
