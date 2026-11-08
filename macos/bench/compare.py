#!/usr/bin/env python3
"""Tables of `Petal --bench-windows --json` results, before and after (Python standard library only).

    python3 -I macos/bench/compare.py macos/bench/windows-before.json macos/bench/windows-after.json

Prints Markdown: per window, each timed action (median and p95, and how many times faster), scrolling (per 8 pt
step), the CPU each window uses idle, and the bench process's totals."""
import json, sys


def load(path):
    return json.load(open(path))


def factor(before, after):
    if before is None or after is None:
        return ''
    if after <= 0:
        return '∞'
    f = before / after
    return f'{f:.1f}x' if f < 10 else f'{f:.0f}x'


def ms(value):
    if value is None:
        return '–'
    return f'{value:.2f}' if value < 10 else f'{value:.1f}' if value < 100 else f'{value:.0f}'


def main():
    before, after = load(sys.argv[1]), load(sys.argv[2])
    print(f"Before: `{before.get('commit', '')[:7]}`, after: `{after.get('commit', '')[:7]}`, {after.get('runs')} runs each, "
          f"{after.get('machine', '')}. Times in ms, from the action to its first laid-out, drawn frame.\n")
    names = list(before['windows'].keys())
    names += [n for n in after['windows'] if n not in names]
    for name in names:
        b = before['windows'].get(name, {}); a = after['windows'].get(name, {})
        print(f'### {name}\n')
        print('| | before median | before p95 | after median | after p95 | faster (median) |')
        print('|---|---:|---:|---:|---:|---:|')
        rows = list(b.get('metrics', {}).keys())
        rows += [r for r in a.get('metrics', {}) if r not in rows]
        for row in rows:
            mb = b.get('metrics', {}).get(row); ma = a.get('metrics', {}).get(row)
            if (mb and mb['runs'] == 0) and (ma and ma['runs'] == 0):
                continue
            bm = mb['median'] if mb and mb['runs'] else None; bp = mb['p95'] if mb and mb['runs'] else None
            am = ma['median'] if ma and ma['runs'] else None; ap = ma['p95'] if ma and ma['runs'] else None
            print(f'| {row} | {ms(bm)} | {ms(bp)} | {ms(am)} | {ms(ap)} | {factor(bm, am)} |')
        scrolls = list(b.get('scroll', {}).keys()); scrolls += [s for s in a.get('scroll', {}) if s not in scrolls]
        if scrolls:
            print('\nScrolling, per 8 pt step (top to bottom and back):\n')
            print('| | steps | median | p95 | p99 | > 8.3 ms | > 16.7 ms | jitter (σ) | median faster |')
            print('|---|---:|---|---|---|---|---|---|---:|')
            for s in scrolls:
                sb = b.get('scroll', {}).get(s); sa = a.get('scroll', {}).get(s)
                def pair(key, fmt=ms):
                    return f"{fmt(sb[key]) if sb else '–'} → {fmt(sa[key]) if sa else '–'}"
                count = lambda v: str(int(v))
                steps = sa['steps'] if sa else sb['steps']
                print(f"| {s} | {steps} | {pair('median')} | {pair('p95')} | {pair('p99')} | {pair('over8ms', count)} | "
                      f"{pair('over16ms', count)} | {pair('jitter')} | {factor(sb and sb['median'], sa and sa['median'])} |")
        idle = list(b.get('idle', {}).keys()); idle += [i for i in a.get('idle', {}) if i not in idle]
        if idle:
            print('\nIdle, open and untouched (alone in a fresh process), ms CPU a second:\n')
            print('| | before | after | less |')
            print('|---|---:|---:|---:|')
            for i in idle:
                ib = b.get('idle', {}).get(i, {}).get('cpuMsPerSecond'); ia = a.get('idle', {}).get(i, {}).get('cpuMsPerSecond')
                print(f'| {i} | {ms(ib)} | {ms(ia)} | {factor(ib, ia)} |')
        print()
    cb, ca = before.get('coldProcess', {}), after.get('coldProcess', {})
    wb, wa = before.get('warmProcess', {}), after.get('warmProcess', {})
    print('### The bench process\n')
    print('| | before | after |')
    print('|---|---:|---:|')
    print(f"| every window opened once in a fresh process: CPU (ms) | {ms(cb.get('cpuMedian'))} | {ms(ca.get('cpuMedian'))} |")
    print(f"| … its peak memory (MB) | {ms(cb.get('peakMBMedian'))} | {ms(ca.get('peakMBMedian'))} |")
    print(f"| the whole warm run: CPU (ms) | {ms(wb.get('cpu'))} | {ms(wa.get('cpu'))} |")
    print(f"| … its peak memory (MB) | {ms(wb.get('peakMB'))} | {ms(wa.get('peakMB'))} |")
    print(f"| in the background after closing every window (ms CPU a second) | {ms(wb.get('backgroundCPUPerSecond'))} | {ms(wa.get('backgroundCPUPerSecond'))} |")


main()
