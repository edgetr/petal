#!/usr/bin/env bash
# Checks the window maths (tiling and parking), when the dock looks at the windows, and which controls Petal AI is
# told about (UIMap), where AI sticky notes show and sit (NoteLayout), and the vault's pure side (sites, 2FA codes,
# exports, when it fills by itself), without running Petal, moving any window or touching the Keychain:
#   macos/checks/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -O -o "$out/check" Sources/Petal/WindowLayout.swift checks/WindowLayoutCheck.swift
"$out/check"
swiftc -parse-as-library -O -o "$out/look" Sources/Petal/LookSchedule.swift checks/LookScheduleCheck.swift
"$out/look"
swiftc -parse-as-library -O -o "$out/uimap" Sources/Petal/UIMap.swift checks/UIMapCheck.swift
"$out/uimap"
swiftc -parse-as-library -O -o "$out/notes" Sources/Petal/NoteLayout.swift checks/NoteLayoutCheck.swift
"$out/notes"
swiftc -parse-as-library -O -o "$out/vault" Sources/Petal/Vault.swift Sources/Petal/UIMap.swift checks/VaultCheck.swift
"$out/vault"
