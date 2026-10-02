#!/usr/bin/env python3
# SPDX-License-Identifier: CDDL-1.0
"""
Split this VM's share of the ZTS runfiles into runfiles for parallel
runners plus one runfile of tests that must run alone.

zts-parallel.py --runfiles A.run,B.run --list zts-parallel.tsv
    --part N/D --runners R|auto --outdir DIR

Writes DIR/par-<i>.<runfile> for i in 1..R and DIR/serial.<runfile>,
and prints the comma separated runfile lists, one line per runner
and a last line for the serial run.
"""

import argparse
import heapq
import os
import re

SECTION = re.compile(r'^\[([^\]]+)\]\n(.*?)(?=^\[|\Z)', re.M | re.S)
TESTS = re.compile(r'^tests\s*=\s*\[(.*?)\]', re.M | re.S)
TAGS = re.compile(r'^tags\s*=\s*\[(.*?)\]', re.M | re.S)
NAME = re.compile(r"'([^']+)'")


def parse(path):
    text = open(path).read()
    head = text[:text.find('[tests/')]
    secs = []
    for name, body in SECTION.findall(text):
        if name == 'DEFAULT':
            continue
        t = TESTS.search(body)
        g = TAGS.search(body)
        secs.append((name, body,
                     NAME.findall(t.group(1)) if t else [],
                     NAME.findall(g.group(1)) if g else []))
    return head, secs


def part_tags(sections, num, den):
    last = sorted({tags[-1] for _, _, _, tags in sections
                   if tags and tags[-1] != 'functional'})
    return {t for i, t in enumerate(last, 1) if i % den == num - 1}


def load_list(path):
    cls = {}
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        f = line.rstrip('\n').split('\t')
        cls[f[0]] = (f[1], int(f[2]))
    return cls


def section_text(name, body, tests):
    names = ', '.join("'%s'" % t for t in tests)
    return '[%s]\n%s' % (name, TESTS.sub(
        lambda m: 'tests = [%s]' % names, body, count=1))


def with_outputdir(head, outdir):
    lines = [x for x in head.split('\n')
             if not x.startswith('outputdir')]
    i = lines.index('[DEFAULT]') + 1
    lines.insert(i, 'outputdir = %s' % outdir)
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--runfiles', required=True)
    ap.add_argument('--list', required=True)
    ap.add_argument('--part', default='1/1')
    ap.add_argument('--runners', default='auto')
    ap.add_argument('--outdir', required=True)
    ap.add_argument('--results', default='/var/tmp/test_results')
    a = ap.parse_args()

    if a.runners == 'auto':
        runners = os.cpu_count() or 1
    else:
        runners = max(1, int(a.runners))
    num, den = (int(x) for x in a.part.split('/'))
    cls = load_list(a.list)

    files = [(p, *parse(p)) for p in a.runfiles.split(',')]
    allsecs = [s for _, _, secs in files for s in secs]
    want = part_tags(allsecs, num, den)

    par = []
    for path, head, secs in files:
        for name, body, tests, tags in secs:
            if not set(tags) & want:
                continue
            for t in tests:
                c, sec = cls.get(name + '/' + t, ('S', 30))
                if c == 'P':
                    par.append((sec, path, name, t))

    load = [(0, i) for i in range(runners)]
    owner = {}
    for sec, path, name, t in sorted(par, reverse=True):
        s, i = heapq.heappop(load)
        owner[(path, name, t)] = i
        heapq.heappush(load, (s + sec, i))

    os.makedirs(a.outdir, exist_ok=True)
    lists = [[] for _ in range(runners + 1)]
    for path, head, secs in files:
        base = os.path.basename(path)
        out = [[] for _ in range(runners + 1)]
        for name, body, tests, tags in secs:
            if not set(tags) & want:
                continue
            split = [[] for _ in range(runners + 1)]
            for t in tests:
                split[owner.get((path, name, t), runners)].append(t)
            for i, ts in enumerate(split):
                if ts:
                    out[i].append(section_text(name, body, ts))
        for i, secs_out in enumerate(out):
            if not secs_out:
                continue
            tag = 'serial' if i == runners else 'par-%d' % (i + 1)
            res = a.results if i == runners else \
                '%s-%s' % (a.results, tag)
            f = os.path.join(a.outdir, '%s.%s' % (tag, base))
            with open(f, 'w') as fh:
                fh.write(with_outputdir(head, res))
                fh.write('\n'.join(secs_out))
            lists[i].append(f)
    for i in range(runners + 1):
        print(','.join(lists[i]))


if __name__ == '__main__':
    main()
