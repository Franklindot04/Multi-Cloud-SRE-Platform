# Result summary

This is the Markdown that `scripts/chaos-run.sh` writes next to the JSON result of a run, in `chaos/results/<experiment>-<run id>.md`, with each value filled in. It is not written by hand. A game day copies the lines it needs into the [game day record](game-day-record.md).

```markdown
# <experiment>

- Run: `<run id>` on the cluster `<cluster name>`, <start> to <end>
- Hypothesis: <the hypothesis of the experiment>
- Result: **the hypothesis held** | **the hypothesis did not hold (a finding)**
- Aborted: no | <the reason: a probe that failed for longer than its grace, a page alert, a signal, an error>
- Valid: yes | no: the injection was undone from outside
- Rollback: ok | FAILED
- Recovered: yes | no

## Probes

- before: <each probe, its state and value>
- after: <each probe, its state and value>
- during: <how many readings, and how many were outside the threshold>

## Alerts

- expected: <the alerts the experiment expected to fire>
- fired: <those that were seen firing>
- must not fire, and did: <the alerts in mustNotFire that fired>
- expected but not seen firing: <the expected alerts that never fired>
- page alerts at the abort: <the page alerts that ended the run, if any>

## Changes made

- <time> <each change the runner made to the cluster>

## Notes

- <anything the run noticed: a node it skipped, a timeout, an alert that must not fire>
```

How to read it:

- **The hypothesis held** means: nothing aborted the run, every probe that applies after the injection passed again within the rollback timeout, no probe stayed outside its threshold past the grace period, no alert that must not fire did, and the rollback worked. It says nothing about what was not measured (see the header of each experiment).
- **The hypothesis did not hold** is a finding. The JSON file has the probe values at every reading.
- **Valid: no** means that something put the injection back while the run was on (Argo CD self-heal, for a scaled-down workload). The run proves nothing: pause the Application and run it again.
- **Rollback: FAILED** means something may be left behind: run `scripts/chaos-run.sh --cleanup`.
