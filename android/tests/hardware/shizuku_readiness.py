#!/usr/bin/env python3
"""Physical regression: server death must reach the Mac before any manual request."""
import subprocess,time,json,sys,argparse
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default='adb')
parser.add_argument('--mac-cli', default='tetherbug')
parser.add_argument('--output', type=Path)
parser.add_argument('--execute', action='store_true', help='Interrupt Shizuku once on the USB-connected physical phone; watchdog must be enabled')
args=parser.parse_args()
if not args.execute:
 print('Plan: terminate the verified shell-UID Shizuku server once; require automatic watchdog recovery and fresh Mac unavailable/ready status, without issuing hotspot commands. No hotspot configuration changes. Use --execute only with USB debugging, a running Shizuku Next watchdog, and Tetherbug connected on both devices.')
 sys.exit(0)
ADB=args.adb;APP=args.mac_cli

def a(*x):return subprocess.run([ADB,'-d','shell',*x],capture_output=True,text=True,timeout=10)
def state():return json.loads(subprocess.check_output([str(APP),'status','--json'],text=True))
old=a('pidof','shizuku_server').stdout.strip();app_pid=a('pidof','ie.xav.tetherbug').stdout.strip();j=state();assert old.isdecimal() and app_pid.isdecimal() and j.get('connected') and j.get('status',{}).get('controllable')
assert 'WatchdogService' in a('dumpsys','activity','services','moe.shizuku.privileged.api').stdout, 'Enable Shizuku Next watchdog first'
ps=a('ps','-A','-o','USER,PID,NAME').stdout;assert any(l.split()==['shell',old,'shizuku_server'] for l in ps.splitlines())
start=time.monotonic();a('kill','-TERM',old);events=[];last=None;saw_unready=False;saw_ready_after=False
while time.monotonic()-start<15:
 j=state();v={'seconds':round(time.monotonic()-start,3),'connected':j.get('connected'),'controllable':j.get('status',{}).get('controllable')}
 key=(v['connected'],v['controllable'])
 if key!=last:events.append(v);print(json.dumps(v),flush=True);last=key
 if v['controllable'] is False:saw_unready=True
 if saw_unready and v['controllable'] is True:saw_ready_after=True;break
 time.sleep(.08)
new=a('pidof','shizuku_server').stdout.strip();r={'events':events,'sawUnreadyWithoutCommand':saw_unready,'sawReadyAfterWithoutCommand':saw_ready_after,'oldServerPid':old,'newServerPid':new,'tetherbugProcessUnchanged':app_pid==a('pidof','ie.xav.tetherbug').stdout.strip(),'serverRespawned':bool(new and new!=old)}
if args.output:args.output.write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps(r),flush=True)
assert saw_unready and saw_ready_after and r['serverRespawned'] and r['tetherbugProcessUnchanged'],'Mac was not notified of Shizuku availability changes without a manual command'
