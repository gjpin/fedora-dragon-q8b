#!/usr/bin/env bash
# =============================================================================
# dragon-q8b-thermal.sh - Thermal Governor & Cooling Management for Dragon Q8B
# =============================================================================
# Reproduces the thermal governor configuration functionality of Radxa OS
# (rsetup). Defaults to 'step_wise' policy for active cooling with PWM fans.
# =============================================================================
set -Eeuo pipefail

DEFAULT_GOVERNOR="step_wise"
CONFIG_FILE="/etc/dragon-q8b/thermal.conf"
TMPFILES_CONF="/etc/tmpfiles.d/dragon-q8b-thermal.conf"
SYSFS_THERMAL_DIR="/sys/class/thermal"

usage() {
    cat <<'EOF'
Usage: dragon-q8b-thermal.sh [OPTIONS]

Configure and monitor thermal governor policies and fan cooling on the
Radxa Dragon Q8B (Qualcomm SC8280XP).

Options:
  -m, --mode POLICY        Set thermal governor policy (default: step_wise)
                           Supported: step_wise, power_allocator, user_space,
                                      fair_share, bang_bang
  -s, --status             Display status of all thermal zones and cooling devices
  -p, --persist            Persist the selected governor across system reboots
      --apply-config       Read /etc/dragon-q8b/thermal.conf and apply saved policy
  -f, --fan-speed LEVEL    Set cooling device state (0 to max_state; requires user_space)
  -i, --menu               Open interactive thermal configuration menu
  -b, --batch              Run in non-interactive batch mode (default when options given)
  -n, --dry-run            Show actions without writing to sysfs or disk
  -q, --quiet              Suppress informational output
  -h, --help               Show this help message

Examples:
  dragon-q8b-thermal.sh                       # Apply default step_wise policy & persist
  dragon-q8b-thermal.sh --status              # View current temperatures & governors
  dragon-q8b-thermal.sh -m power_allocator    # Switch to passive/fanless cooling mode
  dragon-q8b-thermal.sh -m user_space -f 3    # Switch to manual control and set fan level
  dragon-q8b-thermal.sh --menu                # Open interactive rsetup-style menu
EOF
}

log() {
    if [[ "$QUIET" -eq 0 ]]; then
        printf '[dragon-q8b-thermal] %s\n' "$*"
    fi
}

log_err() {
    printf '[dragon-q8b-thermal] ERROR: %s\n' "$*" >&2
}

log_warn() {
    printf '[dragon-q8b-thermal] WARNING: %s\n' "$*" >&2
}

# Defaults
MODE=""
ACTION=""
PERSIST=0
FAN_SPEED=""
DRY_RUN=0
QUIET=0
INTERACTIVE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode|--policy)
            MODE=${2:?missing policy name after $1}
            ACTION="set"
            shift 2
            ;;
        -s|--status)
            ACTION="status"
            shift
            ;;
        -p|--persist)
            PERSIST=1
            shift
            ;;
        --apply-config)
            ACTION="apply_config"
            shift
            ;;
        -f|--fan-speed|--fan-level)
            FAN_SPEED=${2:?missing fan speed level after $1}
            ACTION="fan_speed"
            shift 2
            ;;
        -i|--menu|--interactive)
            INTERACTIVE=1
            ACTION="menu"
            shift
            ;;
        -b|--batch|--non-interactive)
            INTERACTIVE=0
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_err "Unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

require_root() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        log_err "Root privileges required to modify thermal settings. Please run with sudo."
        exit 1
    fi
}

get_thermal_zones() {
    local zones=()
    if [[ -d "$SYSFS_THERMAL_DIR" ]]; then
        for z in "$SYSFS_THERMAL_DIR"/thermal_zone*; do
            [[ -d "$z" ]] && zones+=("$z")
        done
    fi
    printf '%s\n' "${zones[@]:-}"
}

get_cooling_devices() {
    local cdevs=()
    if [[ -d "$SYSFS_THERMAL_DIR" ]]; then
        for c in "$SYSFS_THERMAL_DIR"/cooling_device*; do
            [[ -d "$c" ]] && cdevs+=("$c")
        done
    fi
    printf '%s\n' "${cdevs[@]:-}"
}

show_status() {
    echo "================================================================================"
    echo "                   Radxa Dragon Q8B Thermal & Fan Status"
    echo "================================================================================"

    local zone_found=0
    printf "%-16s %-22s %-12s %-16s %s\n" "ZONE" "TYPE" "TEMP (°C)" "CURRENT POLICY" "AVAILABLE POLICIES"
    printf "%-16s %-22s %-12s %-16s %s\n" "----------------" "----------------------" "------------" "----------------" "------------------"

    while IFS= read -r z; do
        [[ -n "$z" ]] || continue
        zone_found=1
        local zid type temp_mc temp_c policy avail
        zid=$(basename "$z")
        type=$(cat "$z/type" 2>/dev/null || echo "unknown")
        temp_mc=$(cat "$z/temp" 2>/dev/null || echo "0")
        if [[ "$temp_mc" =~ ^-?[0-9]+$ ]]; then
            temp_c=$(awk "BEGIN {printf \"%.1f\", $temp_mc / 1000}")
        else
            temp_c="N/A"
        fi
        policy=$(cat "$z/policy" 2>/dev/null || echo "unknown")
        avail=$(cat "$z/available_policies" 2>/dev/null || echo "none")

        printf "%-16s %-22s %-12s %-16s %s\n" "$zid" "$type" "$temp_c" "$policy" "$avail"
    done < <(get_thermal_zones)

    if [[ $zone_found -eq 0 ]]; then
        echo "  (No sysfs thermal zones detected in $SYSFS_THERMAL_DIR)"
    fi

    echo
    echo "----------------------------- Cooling Devices ----------------------------------"
    local cdev_found=0
    printf "%-18s %-24s %-16s %s\n" "DEVICE" "TYPE" "CURRENT STATE" "MAX STATE"
    printf "%-18s %-24s %-16s %s\n" "------------------" "------------------------" "----------------" "---------"

    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        cdev_found=1
        local cid ctype cur max
        cid=$(basename "$c")
        ctype=$(cat "$c/type" 2>/dev/null || echo "unknown")
        cur=$(cat "$c/cur_state" 2>/dev/null || echo "N/A")
        max=$(cat "$c/max_state" 2>/dev/null || echo "N/A")
        printf "%-18s %-24s %-16s %s\n" "$cid" "$ctype" "$cur" "$max"
    done < <(get_cooling_devices)

    if [[ $cdev_found -eq 0 ]]; then
        echo "  (No cooling devices detected in $SYSFS_THERMAL_DIR)"
    fi

    echo
    echo "----------------------------- Saved Configuration ------------------------------"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Config file: $CONFIG_FILE"
        grep -v '^#' "$CONFIG_FILE" | grep -v '^[[:space:]]*$' || echo "  (empty)"
    else
        echo "Config file: $CONFIG_FILE (not present, using system defaults)"
    fi
    if [[ -f "$TMPFILES_CONF" ]]; then
        echo "Tmpfiles rule: $TMPFILES_CONF"
        cat "$TMPFILES_CONF"
    fi
    echo "================================================================================"
}

set_governor() {
    local target_policy=$1
    local persist_flag=$2

    require_root

    local updated=0
    local skipped=0
    local zones
    mapfile -t zones < <(get_thermal_zones)

    if [[ ${#zones[@]} -eq 0 ]]; then
        log_warn "No thermal zones found in $SYSFS_THERMAL_DIR."
    fi

    for z in "${zones[@]}"; do
        [[ -n "$z" ]] || continue
        local zid avail cur_policy type
        zid=$(basename "$z")
        type=$(cat "$z/type" 2>/dev/null || echo "unknown")
        avail=$(cat "$z/available_policies" 2>/dev/null || echo "")
        cur_policy=$(cat "$z/policy" 2>/dev/null || echo "")

        # Check if zone supports this policy
        if [[ -n "$avail" && " $avail " != *" $target_policy "* ]]; then
            log_warn "$zid ($type) does not support policy '$target_policy' (available: $avail); skipping."
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$cur_policy" == "$target_policy" ]]; then
            log "Zone $zid ($type) is already set to '$target_policy'."
            updated=$((updated + 1))
            continue
        fi

        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "[DRY-RUN] Would set $zid/policy ($type) -> $target_policy"
            updated=$((updated + 1))
        else
            if echo "$target_policy" > "$z/policy" 2>/dev/null; then
                log "Set $zid ($type) policy to '$target_policy'."
                updated=$((updated + 1))
            else
                log_warn "Failed to set policy for $zid ($type)."
            fi
        fi
    done

    if [[ "$persist_flag" -eq 1 ]]; then
        save_persistence "$target_policy"
    fi

    log "Thermal governor update complete ($updated applied/matched, $skipped skipped)."
}

save_persistence() {
    local target_policy=$1

    require_root

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[DRY-RUN] Would save configuration to $CONFIG_FILE and $TMPFILES_CONF (policy: $target_policy)"
        return 0
    fi

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
# Configuration for Radxa Dragon Q8B thermal governor
# Generated by dragon-q8b-thermal on $(date -u +'%Y-%m-%d %H:%M:%S UTC')
GOVERNOR=${target_policy}
EOF
    chmod 0644 "$CONFIG_FILE"
    log "Saved configuration to $CONFIG_FILE"

    mkdir -p "$(dirname "$TMPFILES_CONF")"
    cat > "$TMPFILES_CONF" <<EOF
# Systemd tmpfiles rule for Dragon Q8B thermal governor
# Restores the chosen thermal policy across all thermal zones at boot
w /sys/class/thermal/thermal_zone*/policy - - - - ${target_policy}
EOF
    chmod 0644 "$TMPFILES_CONF"
    log "Created systemd tmpfiles rule in $TMPFILES_CONF"
}

apply_saved_config() {
    local policy="$DEFAULT_GOVERNOR"
    if [[ -f "$CONFIG_FILE" ]]; then
        local read_policy
        read_policy=$(awk -F= '/^[[:space:]]*GOVERNOR[[:space:]]*=/{gsub(/[[:space:]"\x27]/,"",$2); print $2; exit}' "$CONFIG_FILE" || true)
        if [[ -n "$read_policy" ]]; then
            policy="$read_policy"
        fi
    fi
    log "Applying saved thermal governor configuration: $policy"
    set_governor "$policy" 1
}

set_fan_speed() {
    local speed=$1
    require_root

    local cdevs
    mapfile -t cdevs < <(get_cooling_devices)

    if [[ ${#cdevs[@]} -eq 0 ]]; then
        log_err "No cooling devices found in $SYSFS_THERMAL_DIR."
        exit 1
    fi

    for c in "${cdevs[@]}"; do
        [[ -n "$c" ]] || continue
        local cid max_state
        cid=$(basename "$c")
        max_state=$(cat "$c/max_state" 2>/dev/null || echo "0")

        if (( speed < 0 || speed > max_state )); then
            log_err "Fan speed $speed is out of range for $cid (0 - $max_state)"
            exit 1
        fi

        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "[DRY-RUN] Would set $cid/cur_state -> $speed (max: $max_state)"
        else
            echo "$speed" > "$c/cur_state"
            log "Set $cid cooling state to $speed (max: $max_state)."
        fi
    done
}

interactive_menu() {
    while true; do
        clear
        echo "================================================================================"
        echo "           Radxa Dragon Q8B Thermal Governor Setup (rsetup style)"
        echo "================================================================================"
        echo " 1) step_wise        - Active cooling with PWM fan / heatsink [Recommended]"
        echo " 2) power_allocator  - Passive cooling / fanless or fixed DC fan"
        echo " 3) user_space       - Manual fan speed & cooling device control"
        echo " 4) fair_share       - Distribute cooling load across devices proportionally"
        echo " 5) bang_bang        - Two-point threshold cooling"
        echo " 6) View Status      - Show thermal zone temperatures and cooling devices"
        echo " 7) Set Fan Speed    - Set manual fan speed state (requires user_space)"
        echo " 8) Exit"
        echo "================================================================================"
        printf "Select an option [1-8]: "
        read -r choice

        case "$choice" in
            1)
                echo
                set_governor "step_wise" 1
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            2)
                echo
                set_governor "power_allocator" 1
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            3)
                echo
                set_governor "user_space" 1
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            4)
                echo
                set_governor "fair_share" 1
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            5)
                echo
                set_governor "bang_bang" 1
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            6)
                echo
                show_status
                printf "\nPress Enter to return to menu..."
                read -r _
                ;;
            7)
                echo
                printf "Enter desired fan speed level (integer): "
                read -r fspeed
                if [[ "$fspeed" =~ ^[0-9]+$ ]]; then
                    set_fan_speed "$fspeed"
                else
                    echo "Invalid number: $fspeed"
                fi
                printf "\nPress Enter to continue..."
                read -r _
                ;;
            8|q|Q)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid selection."
                sleep 1
                ;;
        esac
    done
}

# Main Execution Routing
if [[ "$ACTION" == "menu" || ($INTERACTIVE -eq 1 && -t 0 && -t 1 && -z "$ACTION") ]]; then
    interactive_menu
    exit 0
fi

case "$ACTION" in
    status)
        show_status
        ;;
    fan_speed)
        set_fan_speed "$FAN_SPEED"
        ;;
    apply_config)
        apply_saved_config
        ;;
    set)
        set_governor "$MODE" "$PERSIST"
        ;;
    *)
        # Default behavior: If invoked with no options, apply default step_wise and persist
        log "No options specified; configuring default governor '${DEFAULT_GOVERNOR}' with persistence."
        set_governor "$DEFAULT_GOVERNOR" 1
        ;;
esac
