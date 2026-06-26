# summary.sh — print results + exit code
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

# ───── Summary ─────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
