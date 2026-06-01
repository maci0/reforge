#!/usr/bin/env bash
# Run ShellCheck over ReForge's own shell scripts.
#
# Candidates are selected from `git ls-files`, so vendor submodules
# (vendor/buildroot, vendor/kernels/*) and gitignored trees (build/,
# lab/scratch/, tools/recovery/archive/, ...) are excluded automatically —
# they are not tracked. The one tracked script under vendor/ is vendor/fetch.sh,
# which is ours and IS linted.
#
# A file is a shell-script candidate if any of:
#   - its name ends in .sh
#   - its first line is a shell shebang (#!/bin/sh, #!.*bash, #!.*dash)
#   - it lives at a known shell path (*/etc/init.d/S*, */.shell/*,
#     */services/*, */start.sh, */stop.sh)
#
# Files with no/ambiguous shebang are linted as POSIX sh (-s sh). SC1091 is
# disabled so un-followable source/. of sibling files doesn't fail the run.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SEVERITY="${SHELLCHECK_SEVERITY:-warning}"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "shellcheck: not installed — skipping shell lint."
	echo "  install it (e.g. apt-get install -y shellcheck) to enable 'make lint'."
	exit 0
fi

# Decide whether a tracked file is one of our shell scripts.
is_shell_candidate() {
	f="$1"
	case "$f" in
		# *.sh already covers */start.sh and */stop.sh.
		*.sh) return 0 ;;
		*/etc/init.d/S*|*/.shell/*|*/services/*) return 0 ;;
	esac
	# No matching name/path — inspect the shebang. Read raw bytes and strip NULs
	# so binary files don't trip "ignored null byte" warnings.
	[ -f "$f" ] || return 1
	first="$(head -c 256 -- "$f" 2>/dev/null | tr -d '\0' | head -n1 || true)"
	case "$first" in
		'#!/bin/sh'|'#!/bin/sh '*) return 0 ;;
		'#!'*bash*|'#!'*dash*) return 0 ;;
	esac
	return 1
}

# Gather + dedup candidates.
candidates=()
while IFS= read -r f; do
	is_shell_candidate "$f" && candidates+=("$f")
done < <(git ls-files | sort -u)

if [ "${#candidates[@]}" -eq 0 ]; then
	echo "shellcheck: no shell scripts found."
	exit 0
fi

fail=0
checked=0
for f in "${candidates[@]}"; do
	[ -f "$f" ] || continue
	checked=$((checked + 1))

	# Pick a shell dialect when the file has no usable shebang.
	args=(-S "$SEVERITY" -x -e SC1091)
	first="$(head -c 256 -- "$f" 2>/dev/null | tr -d '\0' | head -n1 || true)"
	case "$first" in
		# bash/dash both contain "sh", so '#!'*sh* covers all three.
		'#!'*sh*) : ;;  # shebang present, let shellcheck decide
		*)
			# No usable shebang. Default to POSIX sh, unless the file declares
			# its own dialect via a `# shellcheck shell=...` directive (a CLI
			# -s would override that directive, so we must not pass one).
			if ! grep -qE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]].*shell=' -- "$f"; then
				args+=(-s sh)
			fi
			;;
	esac

	if shellcheck "${args[@]}" -- "$f"; then
		printf 'PASS  %s\n' "$f"
	else
		printf 'FAIL  %s\n' "$f"
		fail=$((fail + 1))
	fi
done

echo "----------------------------------------"
echo "shellcheck: ${checked} script(s) checked, ${fail} with findings (severity: ${SEVERITY})."

[ "$fail" -eq 0 ] || exit 1
