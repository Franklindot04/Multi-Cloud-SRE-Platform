# Game day record

Copy this file for each game day (for example to a folder of your own, or into the notes of the team), and fill it in during and after the day. The results of the runs are in `chaos/results` on the machine that ran them: copy the numbers here, because that folder is not in Git. The order of the experiments, and what to check, are in the [chaos runbook](../../docs/runbooks/chaos.md).

## The day

- Date:
- Cluster (the name only):
- People, and who ran the experiments:
- Who watched which dashboard (SLOs, Sample services, Progressive delivery, Cluster capacity, Data layer):
- The state of the cluster before: nodes (four for the drain), the bootstrap flags, the profile (data), external secrets mode (yes or no), progressive delivery (yes or no), the load helper running since:
- Argo CD Applications paused for the day (data-valkey, policy-kyverno, eso-operator, delivery-argo-rollouts), and resumed at:

## The plan

The experiments, in the order they will be run, and why each:

1.
2.
3.

## Experiments

Copy this block for each experiment.

### <experiment name>

- Result file (the name only, and the run id):
- Hypothesis (from the file):
- The claim it tests (the ADR or runbook section):
- Expected:
- Observed (what happened, in the order it happened, with the times):
- SLO impact: availability of the gateway over the run (lowest reading of the probe, and the objective 0.995), the share of fast requests (lowest reading, objective 0.95), the minutes of error budget used:
- Alerts that were expected, and which fired:
- Alerts that must not fire, and which did:
- Page alerts that aborted the run:
- Did the hypothesis hold: yes | no | not proved (the run was not valid)
- Was the rollback clean, and how long did the recovery take:
- Anything the runner or the experiment got wrong (a probe that could not tell, a threshold that was a guess):
- Follow-ups (what to fix, what to measure next, who):

## Summary

- Experiments run, and how many held:
- Findings, most serious first. Each finding is recorded here and in the result file; what is done about it is decided by the team:
- Claims in the docs that turned out to be wrong or unproven, with the file and the section to correct:
- Experiments to repeat after a fix:
- Things left in the cluster (nothing, or what and why):
