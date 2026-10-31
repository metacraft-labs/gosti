# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Socket handles shared by the acceptor and request workers.
## Fixed POD storage belongs to the queue, not to a sending thread's ORC heap.
## Open before spawning threads and close only after every user has joined.
import std/locks

const DispatchCapacity* = 32

type DispatchQueue* = object
  lock: Lock
  readable, writable: Cond
  handles: array[DispatchCapacity, int]
  head, tail, count: int

proc open*(queue: var DispatchQueue) =
  initLock(queue.lock)
  initCond(queue.readable)
  initCond(queue.writable)
  queue.head = 0
  queue.tail = 0
  queue.count = 0

proc close*(queue: var DispatchQueue) =
  doAssert queue.count == 0, "dispatch queue must be drained before close"
  deinitCond(queue.readable)
  deinitCond(queue.writable)
  deinitLock(queue.lock)

proc send*(queue: var DispatchQueue; handle: int) =
  withLock queue.lock:
    while queue.count == DispatchCapacity:
      wait(queue.writable, queue.lock)
    queue.handles[queue.tail] = handle
    queue.tail = (queue.tail + 1) mod DispatchCapacity
    inc queue.count
    signal(queue.readable)

proc recv*(queue: var DispatchQueue): int =
  withLock queue.lock:
    while queue.count == 0:
      wait(queue.readable, queue.lock)
    result = queue.handles[queue.head]
    queue.head = (queue.head + 1) mod DispatchCapacity
    dec queue.count
    signal(queue.writable)

proc pending*(queue: var DispatchQueue): int =
  withLock queue.lock:
    result = queue.count
