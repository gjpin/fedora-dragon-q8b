# Fedora kernel source preparation

The custom kernel starts with Fedora's `kernel` dist-git package for the
selected stable release. `scripts/prepare-kernel-source.sh` downloads the
pinned Armbian SC8280XP edge patch series, verifies every SHA-256 digest, and
adds it as one Fedora kernel patch. The series contains the Q8B device tree;
its board description is based on Radxa's official `linux-7.0.11` source.

This is deliberately a source preparation step, not a replacement kernel
specification. Fedora's package names, KABI handling, config generation,
debug flavors, DTB packaging, and kernel-install behavior remain authoritative.

The preparation script fails on patch conflicts. A Fedora kernel refresh must
therefore be reviewed whenever upstream changes overlap a Q8B patch.

CI adds the workflow run number to Fedora's kernel build ID so a rebuilt
kernel cannot collide with an older COPR build that has the same upstream
Fedora version.
