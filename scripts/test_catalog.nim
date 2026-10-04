# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Shared test inventory for the native runner and Reprobuild recipe.
import std/[os, sets, strutils]

type TestSpec* = object
  source*, binary*, tier*, platform*: string

proc loadTestCatalog*(root: string): seq[TestSpec] =
  var sources, binaries: HashSet[string]
  for raw in lines(root / "scripts/test-catalog.txt"):
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = line.splitWhitespace()
    if fields.len != 3 or fields[0] notin ["test", "host", "specialized"] or
        fields[1] notin ["all", "posix", "linux"]:
      raise newException(ValueError, "Malformed test catalog entry: " & line)
    let source = fields[2]
    let parts = source.split('/')
    if parts.len != 3 or parts[0] != "tests" or
        parts[1] notin ["unit", "integration", "e2e"] or
        not parts[2].startsWith("t_") or not parts[2].endsWith(".nim"):
      raise newException(ValueError, "Invalid test source: " & source)
    if not fileExists(root / source):
      raise newException(ValueError, "Missing test source: " & source)
    let binary = source.splitFile.name
    if source in sources or binary in binaries:
      raise newException(ValueError, "Duplicate test source or binary: " & source)
    sources.incl(source)
    binaries.incl(binary)
    result.add TestSpec(source: source, binary: binary,
      tier: fields[0], platform: fields[1])
  if result.len == 0:
    raise newException(ValueError, "Empty test catalog")
  for dir in ["unit", "integration", "e2e"]:
    for kind, path in walkDir(root / "tests" / dir):
      let name = path.extractFilename
      if kind in {pcFile, pcLinkToFile} and name.startsWith("t_") and
          name.endsWith(".nim"):
        let source = "tests/" & dir & "/" & name
        if source notin sources:
          raise newException(ValueError, "Unregistered test source: " & source)

proc selectedTests*(specs: seq[TestSpec]; tier: string): seq[TestSpec] =
  for spec in specs:
    if spec.tier == tier and (spec.platform == "all" or
        (spec.platform == "posix" and defined(posix)) or
        (spec.platform == "linux" and defined(linux))):
      result.add(spec)
