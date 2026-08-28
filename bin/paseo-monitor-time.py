#!/usr/bin/env python3
"""Emit timestamps under the Python 3.8-compatible timezone contract.

Do not use zoneinfo here: Python 3.8 deployments do not provide it. Setting TZ
and calling time.tzset() uses host tzdata and remains DST-correct on macOS.
"""

import os
import sys
import time


TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S%z"


def timestamp(epoch=None):
    """Return an America/New_York timestamp for *epoch* or the current time."""
    previous = os.environ.get("TZ")
    os.environ["TZ"] = "America/New_York"
    time.tzset()
    try:
        return time.strftime(TIMESTAMP_FORMAT, time.localtime(epoch))
    finally:
        if previous is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = previous
        time.tzset()


if __name__ == "__main__":
    epoch = float(sys.argv[1]) if len(sys.argv) > 1 else None
    print(timestamp(epoch))
