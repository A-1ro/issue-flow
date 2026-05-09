#!/usr/bin/env bash
# Pre-PR validation: run format and lint before allowing PR creation.
# Invoked by hooks/hooks.json on PreToolUse for mcp__github__create_pull_request.
#
# Exit non-zero blocks the PR creation. Plugin assumes pnpm-based workspace
# with `format` and `lint` scripts at repo root. Override by setting
# ISSUE_FLOW_FORMAT_CMD / ISSUE_FLOW_LINT_CMD in the project environment.

set -euo pipefail

FORMAT_CMD="${ISSUE_FLOW_FORMAT_CMD:-pnpm format}"
LINT_CMD="${ISSUE_FLOW_LINT_CMD:-pnpm lint}"

echo "[issue-flow] running: ${FORMAT_CMD}"
${FORMAT_CMD}

echo "[issue-flow] running: ${LINT_CMD}"
${LINT_CMD}

echo "[issue-flow] pre-PR checks passed"
