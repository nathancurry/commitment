#!/usr/bin/env python3
"""Fake host planner for real container/FIFO integration tests."""

import importlib.util
import os
import signal
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("planner_broker", sys.argv[1])
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class Backend:
    def plan(self, text):
        if not isinstance(text, str) or not text.strip():
            raise planner.PlannerError("planner input is empty")
        return "fixture advice: " + text.strip()


signal.signal(signal.SIGTERM, planner.stop)
signal.signal(signal.SIGINT, planner.stop)
planner.serve(Path(sys.argv[2]), Backend(), None, os.getppid())
