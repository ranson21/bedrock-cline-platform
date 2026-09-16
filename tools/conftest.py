# keeps `pytest tools` from importing tool entrypoints as tests
collect_ignore_glob = ["*/*_report.py", "*/budget_ctl.py", "*/smoke.py", "*/sync_docs.py"]
