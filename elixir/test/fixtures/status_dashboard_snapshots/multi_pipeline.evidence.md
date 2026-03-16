```text
╭─ SYMPHONY STATUS
│ Agents: 1/10
│ Throughput: 88 tps
│ Runtime: 5m 15s
│ Tokens: in 20,000 | out 4,500 | total 24,500
│ Rate Limits: unavailable
├─ Pipelines
│
│  alpha      active      run=1 retry=1 next=5s https://linear.app/project/alpha-project/issues
│  beta       paused      run=0 retry=1 next=paused https://linear.app/project/beta-project/issues
├─ Running
│
│   PIPELINE   ID       STAGE          PID      AGE / TURN   TOKENS     SESSION        EVENT                       
│   ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
│ ● alpha      MT-201   In Progress    4242     5m 15s / 9       24,500 thre...567890  turn completed (completed)  
│
├─ Backoff queue
│
│  ↻ [alpha] MT-202 attempt=2 in 2.500s error=waiting on review feedback
│  ↻ [beta] MT-203 attempt=1 in 7.000s error=pipeline paused
╰─
```
