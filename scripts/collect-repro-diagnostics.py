# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
"""Collect the failure report and nonempty action logs without PATH utilities."""
import os
from pathlib import Path
import shutil

root = Path(".repro/build")
destination = Path("test-logs/repro-diagnostics")
destination.mkdir(parents=True, exist_ok=True)
collected = 0
for output in sorted(root.glob("*")):
    if not output.is_dir():
        continue
    files = [output / "build-failure-report.json"]
    files += sorted((output / "build-engine-cache/actions").rglob("*.log"))
    for source in files:
        try:
            if not source.is_file() or source.stat().st_size == 0:
                continue
            relative = source.relative_to(output)
            target = destination / output.name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            collected += 1
        except OSError as error:
            print(f"::warning::Cannot collect {source}: {error}")
listing = "\n".join(str(path) for path in sorted(destination.rglob("*")) if path.is_file())
(destination / "collection-summary.txt").write_text(
    f"job: {os.getenv('GITHUB_JOB', '?')} runner: {os.getenv('RUNNER_OS', '?')}/{os.getenv('RUNNER_ARCH', '?')}\n"
    f"collected: {collected}\n{listing}\n")
print(f"Collected {collected} Reprobuild diagnostic files")
if collected == 0:
    print("::warning::No failure report or nonempty action logs were found")
