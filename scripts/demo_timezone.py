#!/usr/bin/env python3
"""Prints a fixed-offset time zone where it is about 10 AM right now.

Screenshots run whenever CI does; running the sample data in this zone makes
the clock and the "next up" times look like a normal morning.
"""
import datetime

now = datetime.datetime.now(datetime.timezone.utc)
offset = round(10 - (now.hour + now.minute / 60))
offset = (offset + 12) % 24 - 12  # UTC-12 ... UTC+11
# Etc/GMT names have the sign inverted: Etc/GMT-3 is UTC+3.
print("UTC" if offset == 0 else "Etc/GMT%+d" % -offset)
