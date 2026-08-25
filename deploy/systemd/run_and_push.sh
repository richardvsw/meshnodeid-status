#!/bin/bash
# LXC-side runner for the status pages -- mirrors the two GitHub Actions
# workflows' own check-and-commit logic exactly, just running locally
# instead of on a GitHub Actions runner.
#
# 2026-08-25: split from a single mqtt-status-repo into two independent
# repos (meshnodeid-status for the broker tracker, bot-status for the
# bot/service tracker) so each can have its own professional custom
# domain (status.meshnode.id / bot-status.rivi.my.id) via GitHub Pages'
# native one-CNAME-per-repo support. This script now operates on BOTH
# checkouts and does two independent commit/push cycles -- one per repo
# -- instead of the single combined commit it used to do.
#
# Why this exists alongside the GitHub Actions workflows, not instead of
# them: this box sits near Indonesia (~5-30ms to these brokers); the
# Actions runner is on US/EU infra (~600-750ms to the same brokers,
# confirmed 2026-08-19). Running the check from here gives accurate
# latency numbers and a much tighter check interval whenever this box is
# up. THIS side is the primary publisher; each workflow's own "Skip
# publish if the LXC already did recently" step makes it defer to
# whatever this script just pushed, only actually publishing when this
# box has been quiet for a while.
#
# Commits under distinct per-repo identities (not the "RiV-Bot" identity
# used for manual/design-work commits, not "github-actions[bot]") so the
# commit history makes it obvious which system produced which data
# point -- meshnodeid-status-lxc for the broker repo, bot-status-lxc for
# the bot repo, matching what each repo's own workflow guard step checks
# for.
set -euo pipefail

MQTT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BOT_DIR="$(dirname "$MQTT_DIR")/bot-status"
# 2026-08-25: resumed publishing here too, per explicit instruction --
# the new meshnodeid-status/bot-status split is a side project for now,
# this is still the actively-checked page day to day. Kept in sync by
# copying the SAME already-computed output from MQTT_DIR/BOT_DIR rather
# than re-running the real network checks a third time (which could
# read slightly different live broker state than the other two and
# make the three sites visibly disagree with each other).
LEGACY_DIR="$(dirname "$MQTT_DIR")/mqtt-status-repo"

# 2026-08-23: discard any leftover uncommitted state before pulling --
# confirmed live, repeatedly: a dirty tree (always regenerated-output
# files here, e.g. from manual dev/debug work over SSH -- real source
# edits go through their own separate commit, never accumulate as
# stray uncommitted diffs in this checkout) makes `git pull --rebase`
# fail at the very first line, which cascades into the lxc-monitor
# staleness detector correctly-but-misleadingly reporting this box as
# down. Every one of these files gets regenerated fresh moments later
# regardless of what was on disk before this line runs, so discarding
# whatever is here is always safe -- this is what actually makes the
# script self-healing against that whole failure class, instead of
# relying on remembering to `git status` clean before every SSH
# session ends. Applied to BOTH checkouts now.
_discard_and_pull() {
    local dir="$1"
    cd "$dir"
    if [ -n "$(git status --porcelain)" ]; then
        echo "$(basename "$dir"): discarding dirty working tree before pull"
        git checkout --quiet -- .
        git clean --quiet -fd
    fi
    git pull --rebase --quiet origin main
}

_discard_and_pull "$MQTT_DIR"
_discard_and_pull "$BOT_DIR"
_discard_and_pull "$LEGACY_DIR"

cd "$MQTT_DIR"

# 2026-08-22: check_and_render.py now does a real authenticated MQTT
# CONNECT (not just a TCP check) so it can tell "broker down" apart from
# "broker up but login rejected" -- see check_and_render.py's own
# comments for why. Pulled fresh from secrets.json on every run (same
# source meshtasticd's own config was seeded from) rather than baked
# into this unit file, so a password rotation only needs updating in one
# place.
MQTT_CHECK_USER="$(python3 -c "import json; print(json.load(open('/opt/rivbot-ui/data/secrets.json')).get('mqtt_user',''))")"
MQTT_CHECK_PASS="$(python3 -c "import json; print(json.load(open('/opt/rivbot-ui/data/secrets.json')).get('mqtt_pass',''))")"
export MQTT_CHECK_USER MQTT_CHECK_PASS

# 2026-08-22: the ping-legend label used to hardcode "RiV-meshBot" --
# the bot's own node can be (and has been) renamed via
# `meshtastic --set-owner`, so pull the live longName from meshtasticd
# on every run instead of a string that goes stale the moment someone
# renames it. Best-effort: a failed/slow query just leaves
# BOT_LONG_NAME empty, and check_and_render.py falls back to whatever
# was last persisted in state.json's _meta rather than failing the
# whole publish over this.
BOT_LONG_NAME="$(timeout 8 python3 -c "
from meshtastic.tcp_interface import TCPInterface
iface = TCPInterface(hostname='localhost')
name = iface.getMyNodeInfo().get('user', {}).get('longName', '')
iface.close()
print(name)
" 2>/dev/null || true)"
export BOT_LONG_NAME

python3 check_and_render.py

# 2026-08-25: brokers.json is the source of truth here (meshnodeid-
# status) -- bot-status keeps its own copy only because it runs as a
# separate top-level script in a separate repo and can't import across
# checkouts. Sync it over every cycle so adding/removing a tracked
# broker here doesn't silently drift out of sync with the copy
# check_bot_status.py reads for its DNS-failover-target note.
cp "$MQTT_DIR/brokers.json" "$BOT_DIR/brokers.json"

cd "$BOT_DIR"

# 2026-08-22: bot-status.html (mesh_bot/meshtasticd service uptime) --
# only THIS side can actually check them (local systemd + local API,
# neither reachable from GitHub Actions). See check_bot_status.py's own
# docstring for the full LXC-vs-Actions split.
python3 check_bot_status.py

# 2026-08-25: mirror this cycle's already-computed output into the
# legacy repo instead of re-running either check script there -- see
# LEGACY_DIR's comment above for why.
cp "$MQTT_DIR/index.html" "$MQTT_DIR/uptime.html" "$MQTT_DIR/state.json" \
   "$MQTT_DIR/log.jsonl" "$MQTT_DIR/brokers.json" "$MQTT_DIR/notice.json" \
   "$LEGACY_DIR/"
rm -rf "$LEGACY_DIR/history"
cp -r "$MQTT_DIR/history" "$LEGACY_DIR/history"
cp "$BOT_DIR/bot-status.html" "$BOT_DIR/bot_state.json" "$BOT_DIR/bot_log.jsonl" "$LEGACY_DIR/"
rm -rf "$LEGACY_DIR/bot_history"
cp -r "$BOT_DIR/bot_history" "$LEGACY_DIR/bot_history"

_commit_and_push() {
    local dir="$1" identity="$2"
    shift 2
    cd "$dir"
    git add "$@"
    if git diff --cached --quiet; then
        echo "$identity: no changes to publish"
        return 0
    fi
    git -c user.name="$identity" -c user.email="lxc@rivbot.local" \
        commit --quiet -m "Update status (LXC) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # This box is the primary publisher and Actions now defers to it, so
    # a real collision should be rare -- but not impossible right at the
    # boundary of Actions' own 5-min defer window. 2 retries is enough
    # margin for that narrow case without this oneshot unit hanging
    # around; -X ours keeps this run's freshly-computed data on
    # conflict, same reasoning as the Actions side.
    local pushed=0
    for i in 1 2; do
        if git push --quiet origin main; then
            pushed=1
            break
        fi
        echo "$identity: push rejected (attempt $i), rebasing and retrying"
        git fetch --quiet origin main
        git -c user.name="$identity" -c user.email="lxc@rivbot.local" \
            rebase --quiet -X ours origin/main
    done
    if [ "$pushed" = "1" ]; then
        echo "$identity: published"
    else
        echo "$identity: failed to push after retries"
        return 1
    fi
}

mqtt_status=0
bot_status=0
legacy_status=0
# emqx_events.jsonl is only ever created by the GitHub Actions side (on
# a real repository_dispatch from EMQX) -- this box never receives that
# webhook directly. `git add` on a path that doesn't exist yet is a
# hard error under `set -e`, so make sure it exists (empty is fine, and
# harmless if it already has real content from a prior Actions run this
# box then pulled).
touch "$MQTT_DIR/emqx_events.jsonl"
_commit_and_push "$MQTT_DIR" "meshnodeid-status-lxc" \
    index.html uptime.html history state.json log.jsonl brokers.json notice.json emqx_events.jsonl \
    || mqtt_status=1
_commit_and_push "$BOT_DIR" "bot-status-lxc" \
    bot-status.html bot_history bot_state.json bot_log.jsonl brokers.json \
    || bot_status=1
_commit_and_push "$LEGACY_DIR" "mqtt-status-lxc" \
    index.html uptime.html history state.json log.jsonl brokers.json notice.json \
    bot-status.html bot_history bot_state.json bot_log.jsonl \
    || legacy_status=1

if [ "$mqtt_status" != "0" ] || [ "$bot_status" != "0" ] || [ "$legacy_status" != "0" ]; then
    exit 1
fi
