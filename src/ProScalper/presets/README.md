# ProScalper presets

Config sets by purpose, as native MT5 `.set` files. Loading one populates every
`input` in the Inputs tab (Strategy Tester or the EA's own Properties dialog) in
one go - the `.mq5` file and its live-mode input defaults are never touched by
picking a preset.

**To use:** attach/backtest ProScalper as usual, open the Inputs tab, click
**Load**, pick the file.

| File | Purpose | Auto-start | Verbose log |
|---|---|---|---|
| `ProScalper_Live.set` | Live/demo trading via the panel | off (never) | off |
| `ProScalper_Backtest_Visual.set` | Strategy Tester, Visual Mode, you click Start | off | on |
| `ProScalper_Backtest_Unattended.set` | Strategy Tester, fast/headless single run | on | on |
| `ProScalper_Optimization.set` | Strategy Tester Optimizer (many passes) | on | off (avoid log spam/slowdown across passes) |

`InpAutoStartForBacktest` is gated to `MQLInfoInteger(MQL_TESTER)` in code
regardless of what a preset sets it to (see CHANGELOG.md, ProScalper v22.5) -
so even if `ProScalper_Backtest_Unattended.set` or `ProScalper_Optimization.set`
were ever accidentally loaded onto a live chart, it would not auto-start.

The `Optimization.set` preset only fixes the operational flags (auto-start on,
logging off). It does not pre-select what to sweep - after loading it, tick the
"optimize" checkbox on whichever input(s) you want to vary (e.g. the
`InpStair*Pct` fields, `InpSRLookbackBars`, the gap dollar amounts) and set
their start/step/stop in the Tester's Inputs tab.

All other values match the `.mq5` file's own defaults as of v22.7 - see
`CHANGELOG.md` at the repo root, "ProScalper" section, for what each version
changed.
