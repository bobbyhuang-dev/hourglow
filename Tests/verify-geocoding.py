#!/usr/bin/env python3
"""Opt-in live MapKit check through the real CLI, isolated from user settings and wallpaper.

Unlike the offline suite, this requires Apple's geocoding service to return a known place.
The query must have no offline match; choose a landmark covered by your regional service.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default='build/hourglow-cli')
parser.add_argument('--arch', choices=['arm64', 'x86_64'])
parser.add_argument('--query', default='杭州西湖')
parser.add_argument('--latitude', type=float, default=30.2592)
parser.add_argument('--longitude', type=float, default=120.1304)
args = parser.parse_args()
command = [str(Path(args.binary).resolve())]
if args.arch:
    command = ['/usr/bin/arch', '-' + args.arch, *command]

with tempfile.TemporaryDirectory(prefix='hourglow-live-geocoding-') as temporary:
    root = Path(temporary)
    config = root / 'schedule.json'
    config.write_text(json.dumps({'slots': [], 'paused': True, 'automaticLocation': False}))
    env = {**os.environ, 'HOURGLOW_HOME': temporary, 'HOURGLOW_LANG': 'en'}

    def run(*operands):
        return subprocess.run([*command, *operands], env=env, capture_output=True,
                              text=True, timeout=20)

    offline = run('cities', args.query)
    assert offline.returncode == 1 and 'no city matches' in offline.stderr, offline
    online = run('location', args.query)
    assert online.returncode == 0, f'MapKit did not resolve the live query: {online.stderr}'
    schedule = json.loads(config.read_text())
    location = schedule['location']
    assert math.isclose(location['latitude'], args.latitude, abs_tol=0.2), location
    assert math.isclose(location['longitude'], args.longitude, abs_tol=0.2), location
    assert location.get('name'), location
    assert schedule['paused'] and schedule['slots'] == [] and not schedule['automaticLocation']
    assert not (root / 'state.json').exists(), 'Live lookup must never start wallpaper scheduling'
    print(f"Live MapKit lookup passed ({args.arch or 'native'}): {location['name']} "
          f"{location['latitude']:.6f}, {location['longitude']:.6f}; no offline match or wallpaper write")
