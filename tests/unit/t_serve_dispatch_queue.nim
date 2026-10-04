# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
## Real threads exercise the production socket-handle queue. No mocks.
## Handles are integer data here; the daemon integration tests use real sockets.
## The sender must block at capacity, preserve FIFO across wraparound, and may
## exit before another thread drains and closes the queue without owning its heap.
import std/[atomics, monotimes, os, times, unittest]
import vm_harness/serve/dispatch_queue

var finished: Atomic[bool]

proc sendMany(queue: ptr DispatchQueue) {.thread.} =
  for i in 0 ..< DispatchCapacity * 3:
    queue[].send(i)
  finished.store(true)

proc sendOne(queue: ptr DispatchQueue) {.thread.} =
  queue[].send(17)

suite "serve dispatch queue ownership":
  test "bounded backpressure preserves FIFO through ring wraparound":
    var queue: DispatchQueue
    queue.open()
    defer: queue.close()
    finished.store(false)
    var sender: Thread[ptr DispatchQueue]
    createThread(sender, sendMany, addr queue)
    let started = getMonoTime()
    while queue.pending() < DispatchCapacity and
        (getMonoTime() - started).inMilliseconds < 5000:
      sleep(1)
    check queue.pending() == DispatchCapacity
    check not finished.load()
    for i in 0 ..< DispatchCapacity * 3:
      check queue.recv() == i
    joinThread(sender)
    check finished.load()
    check queue.pending() == 0

  test "drain and close remain valid after the sender exits":
    for _ in 0 ..< 32:
      var queue: DispatchQueue
      queue.open()
      var sender: Thread[ptr DispatchQueue]
      createThread(sender, sendOne, addr queue)
      joinThread(sender)
      check queue.recv() == 17
      check queue.pending() == 0
      queue.close()
