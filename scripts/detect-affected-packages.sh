#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: detect-affected-packages.sh [OPTIONS]

Determine which Fedora Dragon Q8B packages need rebuilding based on changed files.

Options:
  --base REF            Base git reference/commit to diff against
  --head REF            Head git reference/commit to diff against (default: HEAD)
  --files FILE...       Explicit list of changed file paths
  --packages LIST       Explicit list or comma/space-separated string of packages (e.g. "boot,fastrpc", "all", "auto")
  --all                 Select all packages
  --format FORMAT       Output format: "space" (default), "newline", or "json"
  -h, --help            Show this help message

Known packages:
  kernel, dragon-q8b-firmware, dragon-q8b-boot, dragon-q8b-overlays,
  dragon-q8b-alsa-ucm, dragon-q8b-fastrpc, dragon-q8b-qnn,
  dragon-q8b-kernel, dragon-q8b-support
EOF
}

ALL_PACKAGES=(
    kernel
    dragon-q8b-firmware
    dragon-q8b-boot
    dragon-q8b-overlays
    dragon-q8b-alsa-ucm
    dragon-q8b-fastrpc
    dragon-q8b-qnn
    dragon-q8b-kernel
    dragon-q8b-support
)

normalize_pkg_name() {
    case "$1" in
        kernel) echo "kernel" ;;
        firmware|dragon-q8b-firmware) echo "dragon-q8b-firmware" ;;
        boot|dragon-q8b-boot) echo "dragon-q8b-boot" ;;
        overlays|dragon-q8b-overlays) echo "dragon-q8b-overlays" ;;
        alsa|alsa-ucm|dragon-q8b-alsa|dragon-q8b-alsa-ucm) echo "dragon-q8b-alsa-ucm" ;;
        fastrpc|dragon-q8b-fastrpc) echo "dragon-q8b-fastrpc" ;;
        qnn|dragon-q8b-qnn) echo "dragon-q8b-qnn" ;;
        kernel-meta|dragon-q8b-kernel) echo "dragon-q8b-kernel" ;;
        meta|support|dragon-q8b-support) echo "dragon-q8b-support" ;;
        *) echo "$1" ;;
    esac
}

base_ref=
head_ref=HEAD
mode_all=0
explicit_packages=()
explicit_files=()
format="space"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)
            base_ref=${2:?missing base ref}
            shift 2
            ;;
        --head)
            head_ref=${2:?missing head ref}
            shift 2
            ;;
        --all)
            mode_all=1
            shift
            ;;
        --packages)
            raw_pkgs=${2:?missing packages list}
            shift 2
            IFS=', ' read -r -a parsed_pkgs <<< "$raw_pkgs"
            for p in "${parsed_pkgs[@]}"; do
                [[ -n "$p" ]] && explicit_packages+=("$p")
            done
            ;;
        --files)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                explicit_files+=("$1")
                shift
            done
            ;;
        --format)
            format=${2:?missing format}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

declare -A selected_packages=()

select_pkg() {
    local pkg
    pkg=$(normalize_pkg_name "$1")
    selected_packages["$pkg"]=1
}

# Handle explicit packages request
if [[ ${#explicit_packages[@]} -gt 0 ]]; then
    for item in "${explicit_packages[@]}"; do
        if [[ "$item" == "all" ]]; then
            mode_all=1
            break
        elif [[ "$item" == "auto" ]]; then
            # fallback to change detection
            explicit_packages=()
            break
        else
            select_pkg "$item"
        fi
    done
fi

if [[ "$mode_all" -eq 1 ]]; then
    for p in "${ALL_PACKAGES[@]}"; do
        selected_packages["$p"]=1
    done
fi

if [[ ${#selected_packages[@]} -eq 0 && "$mode_all" -eq 0 ]]; then
    changed_files=()

    if [[ ${#explicit_files[@]} -gt 0 ]]; then
        changed_files=("${explicit_files[@]}")
    else
        # Determine changed files from Git
        if [[ -z "$base_ref" ]]; then
            if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
                base_ref="origin/${GITHUB_BASE_REF}"
            elif [[ -n "${GITHUB_EVENT_BEFORE:-}" && "${GITHUB_EVENT_BEFORE}" != "0000000000000000000000000000000000000000" ]]; then
                base_ref="${GITHUB_EVENT_BEFORE}"
            else
                if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
                    base_ref="HEAD~1"
                else
                    base_ref=$(git hash-object -t tree /dev/null)
                fi
            fi
        fi

        if git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
            while IFS= read -r f; do
                [[ -n "$f" ]] && changed_files+=("$f")
            done < <(git diff --name-only "$base_ref" "$head_ref" -- || true)
        else
            # If base_ref could not be resolved, safely assume all packages changed
            mode_all=1
            for p in "${ALL_PACKAGES[@]}"; do
                selected_packages["$p"]=1
            done
        fi
    fi

    if [[ "$mode_all" -eq 0 ]]; then
        for file in "${changed_files[@]}"; do
            case "$file" in
                packaging/firmware/*|vendor/radxa/firmware/*)
                    select_pkg dragon-q8b-firmware
                    ;;
                packaging/boot/*)
                    select_pkg dragon-q8b-boot
                    ;;
                packaging/overlays/*|vendor/radxa/overlays/*)
                    select_pkg dragon-q8b-overlays
                    ;;
                packaging/alsa/*|vendor/radxa/alsa/*)
                    select_pkg dragon-q8b-alsa-ucm
                    ;;
                packaging/fastrpc/*|vendor/qualcomm/fastrpc/*)
                    select_pkg dragon-q8b-fastrpc
                    ;;
                packaging/qnn/*)
                    select_pkg dragon-q8b-qnn
                    ;;
                packaging/kernel-meta/*)
                    select_pkg dragon-q8b-kernel
                    ;;
                packaging/meta/*)
                    select_pkg dragon-q8b-support
                    ;;
                vendor/armbian/sc8280xp-edge-patches/*|vendor/radxa/kernel/*|\
                config/armbian-sc8280xp-edge-patches.*|scripts/prepare-kernel-source.sh|\
                scripts/check-patch-redundancy.sh)
                    select_pkg kernel
                    select_pkg dragon-q8b-kernel
                    ;;
                config/dragon-q8b.env)
                    # Inspect changed env lines if possible
                    if [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
                        env_diff=$(git diff "$base_ref" "$head_ref" -- config/dragon-q8b.env 2>/dev/null || true)
                        if grep -Eq 'RADXA_FIRMWARE' <<< "$env_diff"; then select_pkg dragon-q8b-firmware; fi
                        if grep -Eq 'RADXA_OVERLAYS' <<< "$env_diff"; then select_pkg dragon-q8b-overlays; fi
                        if grep -Eq 'ALSA_UCM' <<< "$env_diff"; then select_pkg dragon-q8b-alsa-ucm; fi
                        if grep -Eq 'FASTRPC' <<< "$env_diff"; then select_pkg dragon-q8b-fastrpc; fi
                        if grep -Eq 'ARMBIAN|RADXA_KERNEL|FEDORA_RELEASE' <<< "$env_diff"; then
                            select_pkg kernel
                            select_pkg dragon-q8b-kernel
                        fi
                    else
                        for p in "${ALL_PACKAGES[@]}"; do
                            selected_packages["$p"]=1
                        done
                    fi
                    ;;
                scripts/build-srpms.sh|packaging/inputs.lock)
                    for p in "${ALL_PACKAGES[@]}"; do
                        selected_packages["$p"]=1
                    done
                    ;;
                *)
                    # Non-packaging files (docs, README, .gitignore, other scripts, workflows) do not trigger builds
                    ;;
            esac
        done
    fi
fi

# If kernel is selected, dragon-q8b-kernel must also be selected
if [[ -n "${selected_packages[kernel]:-}" ]]; then
    selected_packages["dragon-q8b-kernel"]=1
fi

result_packages=()
for p in "${ALL_PACKAGES[@]}"; do
    if [[ -n "${selected_packages[$p]:-}" ]]; then
        result_packages+=("$p")
    fi
done

case "$format" in
    newline)
        for p in "${result_packages[@]}"; do
            printf '%s\n' "$p"
        done
        ;;
    json)
        if [[ ${#result_packages[@]} -eq 0 ]]; then
            printf '[]\n'
        else
            printf '["%s"' "${result_packages[0]}"
            for ((i=1; i<${#result_packages[@]}; i++)); do
                printf ',"%s"' "${result_packages[i]}"
            done
            printf ']\n'
        fi
        ;;
    space|*)
        printf '%s\n' "${result_packages[*]:-}"
        ;;
esac
