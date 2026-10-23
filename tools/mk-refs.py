#!/usr/bin/env python3
"""mk-refs.py - packages whose build directory another package's .mk reads.

    mk-refs.py SHOW_INFO.json TREE

SHOW_INFO.json is buildroot's "make show-info" for the configured target; TREE
is the Batocera tree (its package/ and buildroot/package/). For every
configured package, its .mk is scanned for $(<PKG>_BUILDDIR), $(<PKG>_DIR) and
$(<PKG>_SRCDIR) of another configured package (the host variant of a package
counts as another package: uzdoom configures with
$(HOST_UZDOOM_BUILDDIR)/ImportExecutables.cmake). Those directories must
survive the pruning between CI parts, whatever package stamps say.

Output: one line per referenced package, "name version <- user ...", sorted.
"""
import glob, json, os, re, sys

info = json.load(open(sys.argv[1]))
tree = sys.argv[2]
pk = {k: v for k, v in info.items() if v.get('type') in ('target', 'host')}
idx = {}
for root in ('buildroot/package', 'package'):
    for p in glob.glob(os.path.join(tree, root, '**', '*.mk'), recursive=True):
        idx.setdefault(os.path.basename(p)[:-3], []).append(p)

def upper(n):
    return n.upper().replace('-', '_')

def lower(u):
    return ('host-' + u[5:].lower().replace('_', '-')) if u.startswith('HOST_') else u.lower().replace('_', '-')

GENERIC = {'TARGET', 'STAGING', 'HOST', 'BINARIES', 'BASE', 'BUILD', 'TOPDIR', 'PKG', 'SRC',
           'LEGAL_INFO', 'GRAPHS', 'PER_PACKAGE', 'DL', 'CONFIG', 'LINUX_HEADERS'}
REF = re.compile(r'\$\(((?:HOST_)?[A-Z0-9_]+?)_(BUILDDIR|SRCDIR|DIR)\)')
keep = {}
scanned = set()
for n in sorted(pk):
    base = n[5:] if n.startswith('host-') else n
    for mk in idx.get(base, []):
        if mk in scanned:
            continue
        scanned.add(mk)
        owner = upper(base)            # the package the current line defines
        for line in open(mk, errors='replace'):
            m = re.match(r'^(?:define\s+)?((?:HOST_)?[A-Z0-9_]+?)_[A-Z0-9_]*\s*[:+?]?=|^define\s+((?:HOST_)?[A-Z0-9_]+?)_[A-Z0-9_]+', line)
            if m:
                cand = m.group(1) or m.group(2)
                for pfx in (('HOST_' + upper(base)), upper(base)):
                    if cand == pfx or cand.startswith(pfx + '_') or (m.group(1) or m.group(2)).startswith(pfx):
                        owner = pfx
                        break
            for r in REF.finditer(line):
                u = r.group(1)
                if u in GENERIC or u == owner:
                    continue
                dep = lower(u)
                user = lower(owner)
                if dep in pk and user in pk and dep != user:
                    keep.setdefault(dep, set()).add(user)
for dep in sorted(keep):
    print(dep, pk[dep].get('version', ''), '<-', ' '.join(sorted(keep[dep])))
