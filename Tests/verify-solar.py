#!/usr/bin/env python3
"""Cross-check Solar's sunrise and sunset calculations.

Reference times are found by bisection with ephem (XEphem's VSOP87 ephemeris),
using a geometric solar-center altitude of -50 arcminutes: NOAA's definition
of sunrise and sunset (34' atmospheric refraction + 16' solar radius).
This uses neither ephem's own rise/set conventions nor any online service.

    pip install ephem
    python3 Tests/verify-solar.py

Note: do not use ephem's next_rising(horizon='-0:50'). It subtracts the solar
radius from the supplied horizon again, counting 16' twice and shifting results by about 75 seconds.
"""
import datetime as dt
import math
import subprocess
import sys

try:
    import ephem
except ImportError:
    sys.exit("ephem is required: pip install ephem")

BINARY = "build/solarcheck"
TOLERANCE = 30            # seconds
CENTER_ALTITUDE = -50.0   # arcminutes

CASES = [
    ("Shanghai",            31.2333, 121.4667, "2026-08-22", "Asia/Shanghai"),
    ("Shanghai · winter solstice",        31.2333, 121.4667, "2026-12-21", "Asia/Shanghai"),
    ("Shanghai · summer solstice",        31.2333, 121.4667, "2026-06-21", "Asia/Shanghai"),
    ("New York · summer solstice",        40.7128, -74.0060, "2026-06-21", "America/New_York"),
    ("New York · DST transition",  40.7128, -74.0060, "2026-11-01", "America/New_York"),
    ("Sydney · Southern Hemisphere summer solstice",   -33.8688, 151.2093, "2026-12-21", "Australia/Sydney"),
    ("Cape Town",           -33.9249, 18.4241, "2026-03-15", "Africa/Johannesburg"),
    ("East of the International Date Line",        -17.7134, 178.0650, "2026-08-22", "Pacific/Fiji"),
    ("Reykjavik · summer solstice",   64.1466, -21.9426, "2026-06-21", "Atlantic/Reykjavik"),
    ("Longyearbyen · polar day",     78.2232, 15.6267, "2026-06-21", "Arctic/Longyearbyen"),
]


def altitude_arcmin(observer, sun, when):
    observer.date = ephem.Date(when)
    sun.compute(observer)
    return math.degrees(float(sun.alt)) * 60


def crossing(lat, lon, date, rising):
    """Bisect to find when the solar center crosses -50'; return None for polar day/night."""
    observer = ephem.Observer()
    observer.lat, observer.lon = str(lat), str(lon)
    observer.elevation = 0
    observer.pressure = 0          # Disable ephem's refraction model to get geometric altitude.
    sun = ephem.Sun()

    day = dt.datetime.strptime(date, "%Y-%m-%d")
    # Scan a little over a full day along the UTC timeline to cover any longitude.
    start = day - dt.timedelta(days=1)
    samples = [(start + dt.timedelta(minutes=10 * i),
                altitude_arcmin(observer, sun, start + dt.timedelta(minutes=10 * i)))
               for i in range(0, 6 * 24 * 3 + 1)]

    spans = []
    for (t0, a0), (t1, a1) in zip(samples, samples[1:]):
        went_up = a0 < CENTER_ALTITUDE <= a1
        went_down = a0 > CENTER_ALTITUDE >= a1
        if (rising and went_up) or (not rising and went_down):
            spans.append((t0, t1))
    if not spans:
        return None

    # Choose the crossing closest to local noon on the target date.
    target = day + dt.timedelta(hours=12) - dt.timedelta(hours=lon / 15)
    lo, hi = min(spans, key=lambda s: abs((s[0] - target).total_seconds()))
    for _ in range(60):
        mid = lo + (hi - lo) / 2
        above = altitude_arcmin(observer, sun, mid) > CENTER_ALTITUDE
        if above == rising:
            hi = mid
        else:
            lo = mid
    return (lo + (hi - lo) / 2).replace(tzinfo=dt.timezone.utc)


def main():
    failures = 0
    print(f"{'Case':<22} {'Sunrise error':>9} {'Sunset error':>9}")
    print("-" * 45)

    for label, lat, lon, date, tz in CASES:
        run = subprocess.run([BINARY, str(lat), str(lon), date, tz],
                             capture_output=True, text=True)
        if run.returncode != 0:
            print(f"{label:<22} Execution failed: {run.stderr.strip()}")
            failures += 1
            continue

        reference = (crossing(lat, lon, date, rising=True),
                     crossing(lat, lon, date, rising=False))

        if run.stdout.strip() == "POLAR":
            ok = reference[0] is None and reference[1] is None
            print(f"{label:<22} {'Polar day/night':>16}  {'✓' if ok else '✗ Reference has sunrise'}")
            failures += 0 if ok else 1
            continue

        if None in reference:
            print(f"{label:<22} ✗ Solar returned times, but the reference indicates polar day/night")
            failures += 1
            continue

        mine = [dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
                for s in run.stdout.split()]
        deltas = [abs((m - r).total_seconds()) for m, r in zip(mine, reference)]
        bad = any(d > TOLERANCE for d in deltas)
        failures += bad
        print(f"{label:<22} {deltas[0]:>7.0f} s {deltas[1]:>7.0f} s  {'✗' if bad else '✓'}")

    print("-" * 45)
    print(f"{len(CASES) - failures}/{len(CASES)} passed (tolerance: {TOLERANCE} seconds)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
