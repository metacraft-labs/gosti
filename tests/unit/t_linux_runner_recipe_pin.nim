# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Gates on the actions-runner pin of the Linux runner recipe
## (guest-recipes/linux-x64-runner/build-runner-image.sh).
##
## GitHub stops dispatching jobs to runner releases it has deprecated. The
## listener still connects and prints "Listening for Jobs", then exits with
## "Runner version vX is deprecated and cannot receive messages". GARM uses the
## runner CACHED in the image, so a stale default pin produces an image whose
## every runner dies seconds after registering. These tests hold the recipe's
## side of that:
##
##   * the version helpers the recipe uses to warn about a stale pin, and to
##     resolve `VMH_RUNNER_VERSION=latest`, compute what they claim to —
##     exercised by running the recipe's OWN function bodies under bash, with a
##     fake `curl` on PATH (hermetic: no network);
##   * the default pin is a well-formed version and is not the release that
##     was found deprecated in the field;
##   * the recipe refuses an image whose staged runner is not the pinned
##     version, can verify the tarball digest, and stamps the version as a
##     machine-readable image property.
##
## No mocks of the system under test: the fake `curl` stands in for
## api.github.com only, because a unit gate must not depend on the network.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]
import ../native_command_fixture

const RecipePath = "guest-recipes/linux-x64-runner/build-runner-image.sh"

proc recipeText(): string =
  readFile(RecipePath)

proc functionBody(text, name: string): string =
  ## The full text of `name() { ... }` as defined at column 0 of the recipe.
  let start = text.find("\n" & name & "() {")
  doAssert start >= 0, "function " & name & " not found in the recipe"
  let finish = text.find("\n}\n", start + 1)
  doAssert finish > start, "unterminated function " & name
  text[start + 1 .. finish + 2]

proc runBash(script: string, path = ""): tuple[output: string, code: int] =
  let dir = getTempDir() / "t_linux_runner_recipe_pin"
  createDir(dir)
  let file = dir / "probe.sh"
  writeFile(file, script)
  let env = newStringTable(when defined(windows): modeCaseInsensitive
                           else: modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  if path.len > 0:
    env["PATH"] = path & $PathSep & getEnv("PATH")
  let bash = findExe("bash")
  let child = startProcess(bash, args = @[file.replace('\\', '/')],
    env = env, options = {poStdErrToStdOut})
  defer: child.close()
  var output = ""
  var buffer: array[4096, char]
  while true:
    let count = child.outputStream.readData(addr buffer[0], buffer.len)
    if count == 0: break
    for i in 0 ..< count: output.add(buffer[i])
  let code = child.waitForExit()
  if code notin [0, 1]:
    echo "bash fixture failed: executable=", bash, " exit=", code,
      " output=", output
  (output, code)

proc fakeCurlDir(body: string): string =
  ## A directory holding a `curl` that prints `body` (a canned GitHub API
  ## response) regardless of its arguments.
  result = getTempDir() / "t_linux_runner_recipe_pin_curl"
  createDir(result)
  let bodyFile = result / "body.json"
  writeFile(bodyFile, body)
  discard commandFixture(result / "curl", %*{"output": body & "\n"})

suite "linux runner recipe: version helpers":
  let text = recipeText()
  let lag = functionBody(text, "runner_minor_lag")
  let latest = functionBody(text, "latest_runner_release")

  test "minor lag between two versions of the same major":
    let r = runBash(lag & """
runner_minor_lag 2.335.1 2.337.0
runner_minor_lag 2.336.0 2.337.0
runner_minor_lag 2.337.0 2.337.0
""")
    check r.code == 0
    check r.output.strip.splitLines == @["2", "1", "0"]

  test "no lag is reported across a major change or for garbage":
    let r = runBash(lag & """
echo "[$(runner_minor_lag 2.337.0 3.0.0)]"
echo "[$(runner_minor_lag latest 2.337.0)]"
echo "[$(runner_minor_lag '' 2.337.0)]"
""")
    check r.code == 0
    check r.output.strip.splitLines == @["[]", "[]", "[]"]

  test "latest release is parsed from the GitHub API response":
    let body = """{
  "url": "https://api.github.com/repos/actions/runner/releases/1",
  "tag_name": "v2.337.0",
  "name": "v2.337.0",
  "prerelease": false
}
"""
    let r = runBash(latest & "latest_runner_release\n", fakeCurlDir(body))
    check r.code == 0
    check r.output.strip == "2.337.0"

  test "an unusable API response yields an empty version":
    let r = runBash(latest & "echo \"[$(latest_runner_release)]\"\n",
                    fakeCurlDir("{\"message\": \"API rate limit exceeded\"}\n"))
    check r.code == 0
    check r.output.strip == "[]"

suite "linux runner recipe: pin hygiene":
  let text = recipeText()

  test "the default pin is a release version, not the deprecated 2.335.1":
    let marker = "RUNNER_VERSION_DEFAULT=\""
    let at = text.find(marker)
    check at >= 0
    let value = text[at + marker.len ..< text.find('"', at + marker.len)]
    let parts = value.split('.')
    check parts.len == 3
    for p in parts:
      check p.len > 0 and p.allCharsInSet(Digits)
    check value != "2.335.1"

  test "the staged runner must report the pinned version":
    check "staged_version\" != \"$RUNNER_VERSION\"" in text

  test "a supplied tarball digest is verified":
    check "VMH_RUNNER_SHA256" in text
    check "actual_sha256\" != \"$RUNNER_SHA256\"" in text

  test "the runner version is stamped as an image property":
    check "set-property \"$ALIAS\" vmh.runner_version \"$RUNNER_VERSION\"" in text
