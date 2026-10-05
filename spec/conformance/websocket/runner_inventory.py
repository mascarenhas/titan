"""Run with the pinned image's Python 2; emits actual resolved suite IDs."""
from __future__ import print_function

import json
from autobahntestsuite.case import Cases
from autobahntestsuite.caseset import CaseSet

case_set = CaseSet("websocket", "Case", Cases, {}, {})
ids = sorted([case_set.caseClasstoId(case) for case in Cases],
             key=lambda value: tuple(int(part) for part in value.split('.')))
assert ids and len(ids) == len(set(ids))
print(json.dumps({"all_cases": ids}, sort_keys=True, indent=2))
