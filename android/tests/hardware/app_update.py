#!/usr/bin/env python3
"""Physical regression: an in-place APK update must preserve live Mac status notifications."""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default='adb')
parser.add_argument('--mac-cli', required=True, type=Path)
parser.add_argument('--apk', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--execute', action='store_true')
args = parser.parse_args()
if not args.execute:
    print('Plan: require the hotspot initially off, reinstall the same-key APK on the USB-connected physical phone, keep the Mac agent running, then enable/disable the physical hotspot from the Mac. Restore off on failure. No Shizuku restart or Wi-Fi configuration changes.')
    sys.exit(0)

def phone_pid():
    return subprocess.check_output([args.adb, '-d', 'shell', 'pidof', 'ie.xav.tetherbug'], text=True).strip()

def agent_pids():
    lines = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    return [int(line.split(maxsplit=1)[0]) for line in lines
            if line.split(maxsplit=1)[-1] == str(args.mac_cli) + ' agent']

def state():
    return json.loads(subprocess.check_output([str(args.mac_cli), 'status', '--json'], text=True))

def tethered():
    output = subprocess.check_output([args.adb, '-d', 'shell', 'dumpsys', 'tethering'], text=True)
    return any(re.search(r'\b(?:swlan|wlan)\w*\s*-\s*TetheredState', line) for line in output.splitlines())

def hotspot(enabled):
    subprocess.run([str(args.mac_cli), 'enable' if enabled else 'disable', '--json'],
                   check=True, capture_output=True, text=True)
    start = time.monotonic()
    while time.monotonic() - start < 20:
        report = state()
        if (report.get('status') or {}).get('hotspot') == ('on' if enabled else 'off') and not report.get('requestPending') and tethered() == enabled:
            return round(time.monotonic() - start, 3)
        time.sleep(.2)
    raise AssertionError('Fresh Mac status and physical hotspot state did not agree with the request')

before_agent = agent_pids()
before_phone = phone_pid()
assert len(before_agent) == 1 and before_phone.isdecimal(), 'Start both Tetherbug services first'
assert args.apk.is_file()
initial = state()
assert initial.get('connected') and (initial.get('status') or {}).get('controllable'), 'Shizuku must be ready first'
assert (initial.get('status') or {}).get('hotspot') == 'off' and not tethered(), 'Turn hotspot off before this test'
started = time.monotonic()
result = subprocess.run([args.adb, '-d', 'install', '-r', str(args.apk)], capture_output=True, text=True, timeout=60)
assert result.returncode == 0 and 'Success' in result.stdout, result.stderr
while time.monotonic() - started < 30:
    try:
        after_phone = phone_pid()
    except subprocess.CalledProcessError:
        after_phone = ''
    if after_phone and after_phone != before_phone:
        break
    time.sleep(.2)
else:
    raise AssertionError('Android service did not restart after the update')
time.sleep(2)  # Allow GATT registration; the checks below require fresh changes, never cached readiness.
report = {'androidAppReplaced': before_phone != after_phone,
          'macAgentUnchanged': before_agent == agent_pids()}
try:
    report['enableSeconds'] = hotspot(True)
    report['disableSeconds'] = hotspot(False)
    report['statusUpdatesSurvived'] = True
finally:
    if tethered() or (state().get('status') or {}).get('hotspot') != 'off':
        hotspot(False)
    report['macAgentUnchanged'] = before_agent == agent_pids()
    report['seconds'] = round(time.monotonic() - started, 3)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)
assert all(report[key] for key in ('androidAppReplaced', 'macAgentUnchanged', 'statusUpdatesSurvived')), report
