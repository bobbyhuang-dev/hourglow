#!/usr/bin/env python3
"""对拍 Solar 的日出日落计算。

参考值用 ephem（XEphem 的 VSOP87 星历）二分求解「太阳几何中心高度角
= -50 角分」的时刻 —— 这正是 NOAA 对日出日落的定义（34' 大气折射
+ 16' 日面半径），不依赖 ephem 自己的 rise/set 约定，也不依赖任何在线服务。

    pip install ephem
    python3 Tests/verify-solar.py

注意：不要用 ephem 的 next_rising(horizon='-0:50')。它在给定 horizon
之外还会自行扣掉一次日面半径，等于把 16' 算了两遍，结果会偏约 75 秒。
"""
import datetime as dt
import math
import subprocess
import sys

try:
    import ephem
except ImportError:
    sys.exit("需要 ephem：pip install ephem")

BINARY = "build/solarcheck"
TOLERANCE = 30            # 秒
CENTER_ALTITUDE = -50.0   # 角分

CASES = [
    ("上海",            31.2333, 121.4667, "2026-08-22", "Asia/Shanghai"),
    ("上海·冬至",        31.2333, 121.4667, "2026-12-21", "Asia/Shanghai"),
    ("上海·夏至",        31.2333, 121.4667, "2026-06-21", "Asia/Shanghai"),
    ("纽约·夏至",        40.7128, -74.0060, "2026-06-21", "America/New_York"),
    ("纽约·DST 切换日",  40.7128, -74.0060, "2026-11-01", "America/New_York"),
    ("悉尼·南半球夏至",   -33.8688, 151.2093, "2026-12-21", "Australia/Sydney"),
    ("开普敦",           -33.9249, 18.4241, "2026-03-15", "Africa/Johannesburg"),
    ("换日线以东",        -17.7134, 178.0650, "2026-08-22", "Pacific/Fiji"),
    ("雷克雅未克·夏至",   64.1466, -21.9426, "2026-06-21", "Atlantic/Reykjavik"),
    ("朗伊尔城·极昼",     78.2232, 15.6267, "2026-06-21", "Arctic/Longyearbyen"),
]


def altitude_arcmin(observer, sun, when):
    observer.date = ephem.Date(when)
    sun.compute(observer)
    return math.degrees(float(sun.alt)) * 60


def crossing(lat, lon, date, rising):
    """二分求太阳中心穿过 -50' 的时刻。极昼极夜返回 None。"""
    observer = ephem.Observer()
    observer.lat, observer.lon = str(lat), str(lon)
    observer.elevation = 0
    observer.pressure = 0          # 关掉 ephem 的折射模型，我们要几何高度
    sun = ephem.Sun()

    day = dt.datetime.strptime(date, "%Y-%m-%d")
    # 以 UTC 为轴扫一整天多一点，足以覆盖任意经度
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

    # 取距离目标日期本地正午最近的那次穿越
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
    print(f"{'案例':<22} {'日出偏差':>9} {'日落偏差':>9}")
    print("-" * 45)

    for label, lat, lon, date, tz in CASES:
        run = subprocess.run([BINARY, str(lat), str(lon), date, tz],
                             capture_output=True, text=True)
        if run.returncode != 0:
            print(f"{label:<22} 运行失败: {run.stderr.strip()}")
            failures += 1
            continue

        reference = (crossing(lat, lon, date, rising=True),
                     crossing(lat, lon, date, rising=False))

        if run.stdout.strip() == "POLAR":
            ok = reference[0] is None and reference[1] is None
            print(f"{label:<22} {'极昼/极夜':>16}  {'✓' if ok else '✗ 参考有日出'}")
            failures += 0 if ok else 1
            continue

        if None in reference:
            print(f"{label:<22} ✗ 我们给出了时刻，参考判定为极昼/极夜")
            failures += 1
            continue

        mine = [dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
                for s in run.stdout.split()]
        deltas = [abs((m - r).total_seconds()) for m, r in zip(mine, reference)]
        bad = any(d > TOLERANCE for d in deltas)
        failures += bad
        print(f"{label:<22} {deltas[0]:>7.0f} s {deltas[1]:>7.0f} s  {'✗' if bad else '✓'}")

    print("-" * 45)
    print(f"{len(CASES) - failures}/{len(CASES)} 通过（容差 {TOLERANCE} 秒）")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
