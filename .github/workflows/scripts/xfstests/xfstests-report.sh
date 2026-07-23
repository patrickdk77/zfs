#!/usr/bin/env bash
#
# xfstests-report.sh -- turn a `./check` run log into a zfs-qemu-style summary.
#
# Reads one or more check logs (one per topology), compares the observed
# failures against a per-topology known-failure baseline, and prints a summary
# that surfaces PASS / new-FAIL / known-FAIL / SKIP(not-run, by reason) /
# SAFETY-SKIP. Exit non-zero iff any topology has a failure not in its baseline.
#
# Usage:
#   xfstests-report.sh <baseline-dir> <unsafe-file> <topology>=<log> [<topology>=<log> ...]
#
set -u

BASELINE_DIR="$1"; shift
UNSAFE_FILE="$1"; shift

# set of tests marked unsafe (safety-skipped), for the SKIPPED(unsafe) line
unsafe_list() { grep -vE '^\s*#|^\s*$' "$UNSAFE_FILE" 2>/dev/null | awk '{print $1}' | sort -u; }
baseline_list() { grep -vhE '^\s*#|^\s*$' "$BASELINE_DIR/$1.txt" 2>/dev/null | awk '{print $1}' | sort -u; }
# collapse a newline-separated list to one space-separated line for display
oneline() { tr '\n' ' '; }

overall=0
UNSAFE="$(unsafe_list | tr '\n' ' ')"

for pair in "$@"; do
	topo="${pair%%=*}"
	log="${pair#*=}"
	[ -r "$log" ] || { echo "!! $topo: log $log not readable"; overall=1; continue; }

	# xfstests summary lines
	fails=$(sed -n 's/^Failures: //p' "$log" | tr ' ' '\n' | grep -E '/' | sort -u)
	notrun=$(sed -n 's/^Not run: //p' "$log" | tr ' ' '\n' | grep -E '/' | sort -u)
	ran=$(sed -n 's/^Ran: //p' "$log" | tr ' ' '\n' | grep -E '/' | sort -u)
	nfail=$(echo -n "$fails" | grep -c . || true)
	nnotrun=$(echo -n "$notrun" | grep -c . || true)
	nran=$(echo -n "$ran" | grep -c . || true)
	npass=$((nran - nfail - nnotrun))

	base=$(baseline_list "$topo")
	new_fail=$(comm -23 <(echo "$fails") <(echo "$base") | grep -E '/' || true)
	# baseline tests that did NOT fail this run, and are not merely notrun => now passing
	not_failed=$(comm -13 <(echo "$fails") <(echo "$base") | grep -E '/' || true)
	now_pass=$(comm -23 <(echo "$not_failed") <(echo "$notrun") | grep -E '/' || true)
	known_hit=$(comm -12 <(echo "$fails") <(echo "$base") | grep -E '/' || true)

	echo "======================================================================"
	echo "  topology: $topo"
	echo "----------------------------------------------------------------------"
	printf "  PASS        %4d\n" "$npass"
	printf "  KNOWN-FAIL  %4d  (expected, in baseline): %s\n" \
		"$(echo -n "$known_hit" | grep -c . || true)" "$(oneline <<<"$known_hit")"
	printf "  SKIPPED     %4d  (not run)\n" "$nnotrun"
	printf "  SKIPPED(unsafe)   %s\n" "$UNSAFE"

	# group the not-run reasons so the self-skips are visible, not hidden
	if [ -n "$notrun" ]; then
		echo "  --- skip reasons (self-skips shown here) ---"
		grep -hE '\[not run\]' "$log" \
			| sed -E 's|^(generic/[0-9]+).*\[not run\] |\1\t|' \
			| awk -F'\t' '{cnt[$2]++} END{for(r in cnt) printf "  %5d  %s\n", cnt[r], r}' \
			| sort -rn
	fi

	if [ -n "$new_fail" ]; then
		echo "  *** NEW FAILURES (regression) ***: $(oneline <<<"$new_fail")"
		overall=1
	else
		echo "  NEW FAILURES: none"
	fi
	if [ -n "$now_pass" ]; then
		echo "  NO LONGER FAILING (tighten baseline): $(oneline <<<"$now_pass")"
	fi
done

echo "======================================================================"
[ "$overall" = 0 ] && echo "RESULT: green (all failures accounted for by baselines)" \
	|| echo "RESULT: RED (new failures above)"
exit $overall
