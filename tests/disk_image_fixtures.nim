# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Minimal, byte-exact disk-image headers for the serve exec-policy tests.
## The policy parses only what a hypervisor would follow to ANOTHER file (a
## qcow2 backing file / data file, a VHD/VHDX parent), so each writer emits a
## structurally valid header and zeros: enough for the policy and for
## ``qemu-img info`` to agree on what the file references, nothing more.

import std/strutils

proc putBe(s: var string, off: int, v: uint64, n: int) =
  for i in 0 ..< n:
    s[off + i] = char((v shr (8 * (n - 1 - i))) and 0xff)

proc putLe(s: var string, off: int, v: uint64, n: int) =
  for i in 0 ..< n:
    s[off + i] = char((v shr (8 * i)) and 0xff)

proc qcow2Bytes*(backing = "", backingFmt = "", dataFile = false,
                 version = 3): string =
  ## A qcow2 image QEMU opens (64 KiB clusters, 1 MiB virtual size, nothing
  ## allocated): header in cluster 0, refcount table in 1, its block in 2,
  ## the L1 table in 3. Optional backing file name, backing-format
  ## extension and data-file bit.
  const cl = 0x10000
  result = repeat('\0', 4 * cl)
  for i, c in "QFI\xfb": result[i] = c
  result.putBe(4, version.uint64, 4)
  result.putBe(20, 16, 4)                     # cluster_bits
  result.putBe(24, 1'u64 shl 20, 8)           # virtual size
  result.putBe(36, 1, 4)                      # l1_size
  result.putBe(40, 3 * cl, 8)                 # l1_table_offset
  result.putBe(48, cl, 8)                     # refcount_table_offset
  result.putBe(56, 1, 4)                      # refcount_table_clusters
  result.putBe(cl, 2 * cl, 8)                 # refcount table -> block
  for i in 0 ..< 4:                           # clusters 0-3 in use
    result.putBe(2 * cl + 2 * i, 1, 2)
  var ext = 72
  if version >= 3:
    if dataFile: result.putBe(72, 4, 8)       # incompatible bit 2
    result.putBe(96, 4, 4)                    # refcount_order
    result.putBe(100, 104, 4)                 # header_length
    ext = 104
  if backingFmt.len > 0:
    result.putBe(ext, 0xE2792ACA'u64, 4)
    result.putBe(ext + 4, backingFmt.len.uint64, 4)
    for i, c in backingFmt: result[ext + 8 + i] = c
    ext += 8 + ((backingFmt.len + 7) and not 7)
  result.putBe(ext, 0, 8)                     # end-of-extensions
  if backing.len > 0:
    let off = 1024
    result.putBe(8, off.uint64, 8)
    result.putBe(16, backing.len.uint64, 4)
    for i, c in backing: result[off + i] = c

proc writeQcow2*(path: string, backing = "", backingFmt = "",
                 dataFile = false, version = 3) =
  writeFile(path, qcow2Bytes(backing, backingFmt, dataFile, version))

const
  VhdxMetadataGuid = "\x06\xA2\x7C\x8B\x90\x47\x9A\x4B\xB8\xFE\x57\x5F\x05\x0F\x88\x6E"
  VhdxParentLocatorGuid = "\x2D\x5F\xD3\xA8\x0B\xB3\x4D\x45\xAB\xF7\xD3\xD8\x48\x34\xAB\x0C"
  VhdxFileParamsGuid = "\x37\x67\xA1\xCA\x36\xFA\x43\x4D\xB3\xB6\x33\xF0\xAA\x44\xE7\x6B"

proc writeVhdx*(path: string, differencing = false) =
  ## A VHDX with its region table at 192 KiB naming a metadata region at
  ## 1 MiB, whose table lists file parameters (and, for a differencing disk,
  ## a parent locator).
  var b = repeat('\0', 0x100000 + 0x10000)
  for i, c in "vhdxfile": b[i] = c
  let rt = 0x30000
  for i, c in "regi": b[rt + i] = c
  b.putLe(rt + 8, 1, 4)                       # entry count
  for i, c in VhdxMetadataGuid: b[rt + 16 + i] = c
  b.putLe(rt + 32, 0x100000, 8)               # file offset
  b.putLe(rt + 40, 0x10000, 4)                # length
  b.putLe(rt + 44, 1, 4)                      # required
  let mt = 0x100000
  for i, c in "metadata": b[mt + i] = c
  let items = if differencing: 2 else: 1
  b.putLe(mt + 10, items.uint64, 2)
  for i, c in VhdxFileParamsGuid: b[mt + 32 + i] = c
  if differencing:
    for i, c in VhdxParentLocatorGuid: b[mt + 64 + i] = c
  writeFile(path, b)

proc writeVhdFixed*(path: string, differencing = false) =
  ## A 1 KiB VHD: 512 bytes of data, then the ``conectix`` footer (disk type
  ## 2 = fixed, 4 = differencing).
  var b = repeat('\0', 1024)
  for i, c in "conectix": b[512 + i] = c
  b.putBe(512 + 60, (if differencing: 4'u64 else: 2'u64), 4)
  writeFile(path, b)

proc writeIso*(path: string) =
  ## ``CD001`` where an ISO 9660 primary volume descriptor puts it.
  var bytes = repeat('\0', 0x8800)
  for i, c in "CD001": bytes[0x8001 + i] = c
  writeFile(path, bytes)
