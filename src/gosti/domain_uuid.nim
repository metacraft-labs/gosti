# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Backend-local UUID allocation, shared with durable instance receipts.
import std/[strutils, sysrand]

proc newDomainUuid*(): string =
  var bytes: array[16, byte]
  if not urandom(bytes): raise newException(IOError, "cannot generate instance UUID")
  bytes[6] = (bytes[6] and 0x0f) or 0x40
  bytes[8] = (bytes[8] and 0x3f) or 0x80
  for i, b in bytes:
    if i in [4, 6, 8, 10]: result.add('-')
    result.add(toHex(b, 2).toLowerAscii())

