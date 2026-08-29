# Fresh start

This guide takes a new checkout from source files to tested Fedora packages for
the Radxa Dragon Q8B.

The repository builds a Fedora kernel with the Q8B patch queue, then packages
the board-specific firmware, boot integration, device-tree overlays, ALSA UCM
configuration, and dependency meta-packages.

## 1. Clone and prepare the sources

Clone the repository and materialize the large source archives tracked by Git
LFS:

```shell
git clone https://github.com/gjpin/fedora-dragon-q8b.git
cd fedora-dragon-q8b
git lfs install
git lfs pull
```

The vendored inputs are pinned and checksummed. Validate them before building:

```shell
./scripts/validate-vendor.sh
```

## 2. Build the source RPMs

The build must run in Fedora or a Fedora container/VM. Native macOS does not
provide the Fedora RPM and kernel packaging tools required by this project.

Install the build dependencies in Fedora:

```shell
sudo dnf install \
  fedpkg fedora-packager rpm-build rpmdevtools kernel-rpm-macros \
  python3-devel make gcc flex bison openssl dtc ShellCheck
```

Prepare the build directories and Fedora kernel source:

```shell
mkdir -p build/kernel build/srpms
./scripts/prepare-kernel-source.sh \
  --release 44 \
  --output build/kernel
```

Check the downstream patch queue against Fedora's prepared kernel source:

```shell
./scripts/check-patch-redundancy.sh \
  --kernel-dir build/kernel/kernel \
  --patch-dir build/kernel/dragon-q8b-patches \
  --patch-list config/armbian-sc8280xp-edge-patches.list \
  --output build/kernel/patch-status.tsv
```

Build and validate the SRPMs:

```shell
./scripts/build-srpms.sh \
  --release 44 \
  --source-dir build/kernel/kernel \
  --output build/srpms
./scripts/validate-srpms.sh build/srpms
```

The output contains nine SRPMs: the Fedora `kernel` rebuild, six board
components, and two dependency meta-packages.

## 3. COPR

COPR provides the build chroot and publishes the resulting RPM repository.
This project uses one staging project for testing and one production project
for releases.

### Create the projects

In the COPR web interface, create these projects under your COPR username:

```text
<your-user>/dragon-q8b-staging
<your-user>/dragon-q8b
```

Enable the `fedora-44-aarch64` chroot in both projects. Fedora 44 and aarch64
are intentional: the Dragon Q8B is an ARM64 board and the repository is
currently configured for Fedora 44.

### Configure COPR authentication

Open the [COPR API page](https://copr.fedorainfracloud.org/api/), copy the
complete CLI configuration, and save it locally as:

```text
~/.config/copr
```

Protect the file because it contains an API token:

```shell
chmod 600 ~/.config/copr
copr whoami
```

Do not commit this file or paste its contents into an issue, pull request, or
chat.

### Submit locally

After the SRPM build completes, submit all packages with the repository's
dependency-aware helper:

```shell
./scripts/submit-copr-builds.sh \
  --project <your-user>/dragon-q8b-staging \
  --chroot fedora-44-aarch64 \
  --srpm-dir build/srpms
```

The helper submits the kernel, firmware, boot, overlays, ALSA, FastRPC, and QNN packages
first. It waits for those builds to finish before submitting
`dragon-q8b-kernel` and `dragon-q8b-support`.

COPR's [user documentation](https://docs.pagure.org/copr.copr/user_documentation.html)
also describes creating projects and submitting SRPMs with `copr-cli`.

### Publish with GitHub Actions

The included workflow is usually easier than building locally. In the GitHub
repository, add these Actions secrets under **Settings → Secrets and
variables → Actions**:

```text
COPR_OWNER  = your COPR username
COPR_CONFIG = complete contents of ~/.config/copr
```

Then open **Actions → Build and publish Fedora Dragon Q8B packages → Run
workflow** and select:

```text
copr_project: dragon-q8b-staging
```

The workflow builds in a Fedora 44 container and submits to the selected
aarch64 COPR chroot. A push to `main` also publishes to the staging project.

Use the staging project until the board has been tested. After physical
validation, run the workflow again with:

```text
copr_project: dragon-q8b
```

## 4. Install on the Dragon Q8B

Enable the production repository and install the support bundle:

```shell
sudo dnf copr enable <your-user>/dragon-q8b
sudo dnf install dragon-q8b-support
```

Or install from staging while testing:

```shell
sudo dnf copr enable <your-user>/dragon-q8b-staging
sudo dnf install dragon-q8b-support
```

The bundled bootstrap script performs the same setup after verifying that it
is running on the expected board:

```shell
sudo COPR_OWNER=<your-user> \
  ./scripts/bootstrap-fedora-dragon-q8b.sh \
  --copr <your-user>/dragon-q8b
```

Do not use `--force` on a real board unless you understand which hardware or
release checks it bypasses. The script does not flash SPI/UEFI firmware,
remove old kernels, upgrade the whole system, or reboot automatically.

## 5. Validate the hardware

After installing a kernel or firmware refresh, run:

```shell
sudo ./scripts/validate-runtime.sh
```

Also test boot from the intended storage devices, both Ethernet ports, USB-C,
HDMI/DP, audio playback and capture, Wi-Fi, Bluetooth, GPIO/I²C/SPI/UART
overlays, GPU/VPU, thermals, reboot, and shutdown before promoting a staging
build to production.
