---
inclusion: fileMatch
fileMatchPattern: "**/demo-dashboard.sh"
---

# Demo Dashboard Layout Rules

When modifying `scripts/demo-dashboard.sh`, follow these strict layout constraints:

## Terminal Width Constraints

- **Most sections**: 80 characters max per line
- **vLLM Pods section (render_pods_section)**: 82 characters max per line (exception for visual alignment)
- **Performance section**: 80 characters exactly

## Section-Specific Padding Values

### vLLM Pods Section (`render_pods_section`)
The "Ready" line has different padding based on state:

**With pending pods:**
- With startup display: `printf "%*s" "$((1 - stale_padding))" ""`
- Without startup display: `printf "%*s" "$((19 - stale_padding))" ""`

**Without pending pods:**
- With startup display: `printf "%*s" "$((21 - stale_padding))" ""`
- Without startup display: `printf "%*s" "$((39 - stale_padding))" ""` ← This is the key value!

### Performance Section (`render_performance_section`)
- Field widths: `%-5s` for Avg, p50, p95, p99 latency values
- Final padding before border: `$((3 - stale_padding))`

## Before Making Changes

1. **Always run tests first**: `bats scripts/tests/demo-dashboard.bats`
2. **After changes, run tests again** to verify alignment
3. **If adding new content**, calculate the character count impact
4. **Adjust padding values** to compensate for added/removed characters

## Test File Location

Tests are in `scripts/tests/demo-dashboard.bats`. Key tests:
- Test 17: `render_pods_section fits in 82 columns`
- Test 19: `render_performance_section fits in 80 columns`
- Test 20: `all sections combined`

## Common Pitfalls

- Adding text without reducing padding = border shifts right
- Removing text without increasing padding = border shifts left
- The stale marker `(*)` adds 2 characters when `STALE_*=true`
