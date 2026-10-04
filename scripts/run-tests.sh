#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Metacraft Labs / Schelling Point Labs
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
exec nim r --hints:off scripts/run_tests.nim test
