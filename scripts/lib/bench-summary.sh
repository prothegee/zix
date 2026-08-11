#!/usr/bin/env bash
# bench-summary.sh - The result table a finished run ends with.
#
# Everything is already measured by the time anything in here runs: this file
# only decides how the finished rows are laid out. It is a separate file for the
# same reason the host prep and the metric parsing are separate: a change to how
# a result is PRINTED must not be able to reach the code that decides what the
# number is.
#
# Two layouts over one set of rows:
#   text       aligned columns, the default, for reading in the terminal
#   markdown   a table ready to paste into a document, what --summarize selects
#
# Usage:
# ```bash
# summary_reset
# summary_row baseline 512 gcannon 4187491 6366.9% 134MiB
# summary_render markdown
# ```
#
# Sourced by:
#   scripts/localbench-run.sh

SUMMARY_ROWS=()

# summary_reset
# Drop every collected row, so a sweep starts from nothing.
summary_reset() {
    SUMMARY_ROWS=()
}

# summary_row TEST CONN TOOL RPS CPU MEM
# Record one finished tier.
#
# Note:
# - CPU and MEM arrive already rendered ("6366.9%", "134MiB") because they are
#   carried verbatim off the pass that produced the best throughput. Re-deriving
#   them here would mean holding a second copy of numbers that belong to a run.
#
# Param:
# TEST - string (profile name, e.g. baseline)
# CONN - integer (connection count of this tier)
# TOOL - string (load generator that drove it)
# RPS - integer (successful responses per second)
# CPU - string (percent of one core, e.g. 6366.9%)
# MEM - string (peak resident, e.g. 134MiB)
summary_row() {
    SUMMARY_ROWS+=("$1|$2|$3|$4|$5|$6")
}

# group_digits NUMBER
# Thousands separators, so a seven digit throughput is readable at a glance.
# Input that is not a plain run of digits comes back untouched rather than
# mangled, which keeps a "0" or an empty cell honest.
#
# Return:
# - 4187491 becomes 4,187,491
group_digits() {
    local digits="$1" grouped=""

    case "$digits" in
        ''|*[!0-9]*)
            echo "$digits"

            return 0 ;;
    esac

    while [ "${#digits}" -gt 3 ]; do
        grouped=",${digits: -3}$grouped"
        digits="${digits:0:${#digits} - 3}"
    done

    echo "$digits$grouped"
}

# summary_render_text
# One padded line per tier, the form that reads best in a terminal transcript.
summary_render_text() {
    local row test conn tool rps cpu mem

    for row in "${SUMMARY_ROWS[@]+"${SUMMARY_ROWS[@]}"}"; do
        IFS='|' read -r test conn tool rps cpu mem <<< "$row"

        printf '%-18s %-8s %-10s %12s req/s  cpu %9s  mem %9s\n' \
            "$test" "${conn}c" "$tool" "$rps" "$cpu" "$mem"
    done
}

# summary_render_markdown
# The table --summarize asks for. The load generator is not a column: it is
# fixed by the profile, so it would repeat the same value down the table and say
# nothing about the result. It stays in the text form, where the width is free.
summary_render_markdown() {
    local row test conn tool rps cpu mem

    echo "| Test | Conn | RPS | CPU | Mem |"
    echo "| :- | :- | :- | :- | :- |"

    for row in "${SUMMARY_ROWS[@]+"${SUMMARY_ROWS[@]}"}"; do
        IFS='|' read -r test conn tool rps cpu mem <<< "$row"

        echo "| $test | $conn | $(group_digits "$rps") | $cpu | $mem |"
    done
}

# summary_render MODE
# Print the collected rows.
#
# Param:
# MODE - string (markdown for the --summarize table, anything else for text)
summary_render() {
    if [ "${#SUMMARY_ROWS[@]}" -eq 0 ]; then
        echo "no tier produced a result"

        return 0
    fi

    case "$1" in
        markdown) summary_render_markdown ;;
        *) summary_render_text ;;
    esac
}
