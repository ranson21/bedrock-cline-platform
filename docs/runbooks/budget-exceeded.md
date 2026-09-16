# Runbook: an engineer is locked out (budget or cache)

1. `python tools/budget-ctl/budget_ctl.py --live terragrunt/live/<env> status <user>` shows the
   month totals, override, and profile tag states.
2. If the lock is `cache_disabled`, have them turn on "Use prompt caching" in Cline first, then
   `budget-ctl unlock <user>`.
3. If it is `exhausted` and the work is justified, `budget-ctl grant <user> --usd <n> --note "..."`.
   The override expires at month end.
4. If it happens every month, change their budget in `engineers.yaml`.
