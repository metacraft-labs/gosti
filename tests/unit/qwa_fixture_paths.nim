# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Paths and serial fixture bytes shared by portable contracts and lifecycle tests.
import std/os

const
  FakeFirmwareBanner* =
    "UEFI firmware (version edk2-fake built at 00:00:00 on Jan 1 1980)\n"
    ## One per firmware boot, carrying ``QwaFirmwareBannerMarker`` verbatim.

proc recipeDir*(): string =
  currentSourcePath().parentDir.parentDir.parentDir /
    "guest-recipes" / "windows-arm-base"

proc repoRoot*(): string =
  currentSourcePath().parentDir.parentDir.parentDir

