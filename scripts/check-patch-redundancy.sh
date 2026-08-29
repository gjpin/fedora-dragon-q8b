#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: check-patch-redundancy.sh --kernel-dir DIR --patch-dir DIR --patch-list FILE --output FILE

Prepare the unmodified Fedora kernel source and classify a downstream patch
queue against it. The kernel directory must be a Fedora kernel dist-git
checkout; its working tree may contain the generated Q8B patch.

Statuses in the report:
  FEDORA_PRESENT_EXACT       Fedora's prepared source reverses the patch.
  REQUIRED                   The patch applies to the effective source tree.
  COVERED_BY_Q8B_QUEUE       An earlier Q8B patch already supplies the change.
  REVIEW_REQUIRED             Neither direction applies cleanly.
EOF
}

kernel_dir=
patch_dir=
patch_list=
output=
work_dir=
own_work_dir=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-dir) kernel_dir=${2:?missing Fedora kernel directory}; shift 2 ;;
        --patch-dir) patch_dir=${2:?missing patch directory}; shift 2 ;;
        --patch-list) patch_list=${2:?missing patch list}; shift 2 ;;
        --output) output=${2:?missing report path}; shift 2 ;;
        --work-dir) work_dir=${2:?missing work directory}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "patch-redundancy: $*" >&2; exit 1; }

[[ -d "$kernel_dir" ]] || die "missing Fedora kernel directory: $kernel_dir"
[[ -d "$patch_dir" ]] || die "missing patch directory: $patch_dir"
[[ -r "$patch_list" ]] || die "missing patch list: $patch_list"
[[ -n "$output" ]] || { usage >&2; exit 2; }

for command in git fedpkg rpmbuild cp find awk grep mktemp; do
    command -v "$command" >/dev/null || die "missing required command: $command"
done

git -C "$kernel_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "kernel directory is not a Git checkout: $kernel_dir"

if [[ -z "$work_dir" ]]; then
    work_dir=$(mktemp -d -t dragon-q8b-patch-check.XXXXXX)
    own_work_dir=1
else
    mkdir -p "$work_dir"
fi

cleanup() {
    if [[ $own_work_dir -eq 1 ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

mkdir -p "$(dirname "$output")"
stock_dir="$work_dir/fedora-distgit"
rpmbuild_topdir="$work_dir/rpmbuild"

# The prepared kernel checkout has a modified working tree. A local clone
# gives us the exact Fedora commit and its original kernel.spec without
# acquiring or trusting a second Fedora revision.
echo "Creating stock Fedora dist-git checkout"
git clone --quiet --local "$kernel_dir" "$stock_dir"
# A local clone inherits a local-path origin, which prevents fedpkg from
# resolving Fedora's namespace for the lookaside cache.
git -C "$stock_dir" remote set-url origin https://src.fedoraproject.org/rpms/kernel.git
fedora_commit=$(git -C "$stock_dir" rev-parse HEAD)

mkdir -p "$rpmbuild_topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
echo "Fetching Fedora sources listed by the stock kernel.spec"
(cd "$stock_dir" && fedpkg sources)

cp "$stock_dir/kernel.spec" "$rpmbuild_topdir/SPECS/kernel.spec"
find "$stock_dir" -maxdepth 1 -type f ! -name kernel.spec \
    -exec cp -n {} "$rpmbuild_topdir/SOURCES/" \;

echo "Applying Fedora's own kernel patches"
rpmbuild -bp --nodeps \
    --define "_topdir $rpmbuild_topdir" \
    "$rpmbuild_topdir/SPECS/kernel.spec"

mapfile -t base_trees < <(
    find "$rpmbuild_topdir/BUILD" -type d -name 'linux-*' -print
)
[[ ${#base_trees[@]} -eq 1 ]] || die "expected one prepared Linux source tree, found ${#base_trees[@]}"
base_tree=${base_trees[0]}
working_tree="$work_dir/effective-source"
cp -a "$base_tree" "$working_tree"

printf 'fedora_kernel_commit\t%s\n' "$fedora_commit" > "$output"
printf 'patch\tstatus\tfedora_exact_reverse\taction\n' >> "$output"

required=0
fedora_present=0
covered=0
review=0

while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    patch="$patch_dir/$patch_name"
    [[ -r "$patch" ]] || die "patch listed but not found: $patch"

    # This check is always made against the untouched post-Fedora source.
    # It is the answer to “does Fedora already carry this exact change?”
    fedora_exact=0
    if git -C "$base_tree" apply --reverse --check "$patch" >/dev/null 2>&1; then
        fedora_exact=1
    fi

    if [[ $fedora_exact -eq 1 ]]; then
        status=FEDORA_PRESENT_EXACT
        action=skip
        fedora_present=$((fedora_present + 1))
    elif git -C "$working_tree" apply --reverse --check "$patch" >/dev/null 2>&1; then
        # This is not attributed to Fedora: a prior Q8B patch may have
        # supplied the same change. Keep it out of the effective queue.
        status=COVERED_BY_Q8B_QUEUE
        action=skip
        covered=$((covered + 1))
    elif git -C "$working_tree" apply --check "$patch" >/dev/null 2>&1; then
        git -C "$working_tree" apply "$patch"
        status=REQUIRED
        action=apply
        required=$((required + 1))
    else
        status=REVIEW_REQUIRED
        action=blocked
        review=$((review + 1))
    fi

    printf '%s\t%s\t%s\t%s\n' "$patch_name" "$status" "$fedora_exact" "$action" >> "$output"
done < "$patch_list"

# Make the downloaded Fedora source files available to a following build step
# when the report is run against a prepared checkout. This avoids a second
# lookaside download in the normal GitHub Actions path.
find "$stock_dir" -maxdepth 1 -type f ! -name kernel.spec \
    -exec cp -n {} "$kernel_dir/" \;

printf 'summary\tfedora_present_exact=%s required=%s covered_by_q8b=%s review_required=%s\n' \
    "$fedora_present" "$required" "$covered" "$review" >> "$output"

echo "Patch report: $output"
echo "Fedora exact: $fedora_present; required: $required; covered by Q8B queue: $covered; review: $review"

if [[ $review -gt 0 ]]; then
    echo "one or more patches require semantic/manual review" >&2
    exit 1
fi
