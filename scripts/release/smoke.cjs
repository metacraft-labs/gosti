// No mocked dependencies. The explicit noop backend checks CLI dispatch without
// allocating a VM; this is an archive smoke check, not a hypervisor qualification.
// SPDX-FileCopyrightText: 2026 Metacraft Labs
// SPDX-License-Identifier: Apache-2.0
const {execFileSync} = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [root, target] = process.argv.slice(2);
const suffix = target.startsWith('windows') ? '.exe' : '';
{
  const exe = path.join(root, 'bin', 'gosti' + suffix);
  const run = (...args) => execFileSync(exe, args, {encoding: 'utf8', timeout: 30000});
  assert.match(run('--help'), /provision/);
  assert.match(run('backends'), /noop/);
  run('provision', '--backend', 'noop', '--guest', 'linux', '--baseline', 'release-smoke');
  run('ephemeral-list', '--backend', 'noop');
}
// The retired command name is not shipped (no compatibility alias).
assert(!fs.existsSync(path.join(root, 'bin', 'vm-harness' + suffix)));
assert(fs.statSync(path.join(root, 'share/gosti/guest-scripts')).isDirectory());
assert(fs.statSync(path.join(root, 'share/gosti/guest-recipes')).isDirectory());
