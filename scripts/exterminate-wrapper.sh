#!/bin/bash
# Wrapper for exterminate.sh - Simplifies CAVE infrastructure teardown

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${BLUE}║          CAVE Infrastructure - Teardown Wrapper            ║${NC}" >&2
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n" >&2
}

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}" >&2
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}" >&2
}

_escape_sed_repl() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

resolve_ssh_key() {
    if [ -z "${SSH_KEY_NAME:-}" ]; then
        return 0
    fi

    local ssh_key_path="/home/cave/.ssh/$SSH_KEY_NAME"
    if [ ! -f "$ssh_key_path" ]; then
        print_error "SSH key not found: $ssh_key_path"
        print_error "Make sure your SSH key is in ./ssh-keys/$SSH_KEY_NAME"
        exit 1
    fi
    print_success "SSH key found: $SSH_KEY_NAME"
    echo "$ssh_key_path"
}

patch_exterminate_if_needed() {
    local original="/cave/backend/exterminate.sh"

    local target_ip="${CAVE_HOST_IP:-}"
    if [ -z "$target_ip" ] && [ -n "${OS_AUTH_URL:-}" ]; then
        local url_host
        url_host=$(echo "$OS_AUTH_URL" | sed 's|https\?://||' | cut -d: -f1 | cut -d/ -f1)
        if [[ "$url_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            target_ip="$url_host"
        fi
    fi

    local target_user="${CAVE_HOST_SSH_USER:-vpnsetup}"

    if [ -n "$target_ip" ] && [[ ! "$target_ip" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "CAVE_HOST_IP contains invalid characters: $target_ip"
        exit 1
    fi
    if [[ ! "$target_user" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "CAVE_HOST_SSH_USER contains invalid characters: $target_user"
        exit 1
    fi

    local needs_ip_patch=false
    local needs_user_patch=false
    [ -n "$target_ip" ] && [ "$target_ip" != "10.80.0.100" ] && needs_ip_patch=true
    [ "$target_user" != "vpnsetup" ] && needs_user_patch=true

    if [ "$needs_ip_patch" = false ] && [ "$needs_user_patch" = false ]; then
        echo "$original"
        return
    fi

    local patched
    patched=$(mktemp /cave/backend/.exterminate_XXXXXX.sh)
    cp "$original" "$patched"
    chmod +x "$patched"

    if [ "$needs_ip_patch" = true ]; then
        sed -i "s|10\.80\.0\.100|$(_escape_sed_repl "$target_ip")|g" "$patched"
        print_info "DevStack host IP patched: 10.80.0.100 → $target_ip"
    fi
    if [ "$needs_user_patch" = true ]; then
        sed -i "s|declare DEVSTACK_SSH_USER=\"vpnsetup\"|declare DEVSTACK_SSH_USER=\"$(_escape_sed_repl "$target_user")\"|" "$patched"
        print_info "DevStack SSH user patched: vpnsetup → $target_user"
    fi

    echo "$patched"
}

select_lab_prefix() {
    local out_dir="/cave/backend/out"
    local default_prefix="${LAB_PREFIX:-}"
    local -a deployments=()

    if [ -d "$out_dir" ]; then
        local d
        while IFS= read -r d; do
            [ -n "$d" ] && deployments+=("$d")
        done < <(find "$out_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    fi

    local selection=""
    if [ ${#deployments[@]} -gt 0 ]; then
        print_info "Existing deployments found in $out_dir:"
        local i
        for i in "${!deployments[@]}"; do
            echo "  $((i+1))) ${deployments[$i]}" >&2
        done
        echo "" >&2
        echo "Select a deployment by number, or type a lab prefix manually." >&2
        if [ -n "$default_prefix" ]; then
            echo -n "Choice [$default_prefix]: " >&2
        else
            echo -n "Choice: " >&2
        fi
        read -r selection
        selection="${selection:-$default_prefix}"

        # Numeric input maps to a listed deployment
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#deployments[@]} ]; then
            selection="${deployments[$((selection-1))]}"
        fi
    else
        print_info "No existing deployments found in $out_dir"
        if [ -n "$default_prefix" ]; then
            echo -n "Enter Lab Prefix to destroy [$default_prefix]: " >&2
            read -r selection
            selection="${selection:-$default_prefix}"
        else
            echo -n "Enter Lab Prefix to destroy: " >&2
            read -r selection
        fi
    fi

    if [ -z "$selection" ]; then
        print_error "Lab prefix cannot be empty."
        exit 1
    fi
    echo "$selection"
}

show_usage() {
    cat << EOF >&2
${BLUE}Usage:${NC}
  $0 [OPTIONS]
  $0 <lab-prefix> [OPTIONS]

${BLUE}Arguments:${NC}
  lab-prefix              Lab prefix to destroy (e.g. 'day1')
                          If not provided, uses LAB_PREFIX env var or prompts

${BLUE}Options:${NC}
  --lab-prefix PREFIX     Lab prefix (alternative to positional argument)
  --dry-run               Show what would be executed without running
  --help                  Show this help message

${BLUE}Environment variables:${NC}
  SSH_KEY_NAME            SSH key filename in ./ssh-keys/ — used for iptables cleanup
  LAB_PREFIX              Default lab prefix
  CAVE_HOST_IP            DevStack host IP (default: 10.80.0.100)
  CAVE_HOST_SSH_USER      DevStack SSH user (default: vpnsetup)

${BLUE}Examples:${NC}
  $0 day1
  $0 --lab-prefix day1 --dry-run
EOF
}

main() {
    print_header

    local lab_prefix=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --lab-prefix)
                lab_prefix="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            --*)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -z "$lab_prefix" ]; then
                    lab_prefix="$1"
                else
                    print_error "Too many arguments"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Resolve SSH key (optional — only needed for iptables cleanup)
    local ssh_key_path=""
    if [ -n "${SSH_KEY_NAME:-}" ]; then
        ssh_key_path=$(resolve_ssh_key)
    fi

    # Resolve lab prefix interactively if not provided — scan out/ for existing
    # deployments and offer them as a menu, while still allowing free-text entry.
    if [ -z "$lab_prefix" ]; then
        lab_prefix=$(select_lab_prefix)
    fi

    # Patch exterminate.sh if IP/user differs from defaults
    local exterminate_script
    exterminate_script=$(patch_exterminate_if_needed)
    [ "$exterminate_script" != "/cave/backend/exterminate.sh" ] && trap "rm -f '$exterminate_script'" EXIT

    # Build command
    local cmd=("$exterminate_script" "$lab_prefix")
    if [ -n "$ssh_key_path" ]; then
        cmd+=(--ssh-key "$ssh_key_path")
    fi

    # Interactive summary + confirm loop
    while true; do
        echo ""
        print_info "Teardown Summary:"
        echo "  Lab Prefix:  $lab_prefix"
        if [ -n "$ssh_key_path" ]; then
            echo "  SSH Key:     $SSH_KEY_NAME"
            echo "  iptables:    will be cleaned up on DevStack host"
        else
            echo "  iptables:    skipped (no SSH_KEY_NAME set)"
        fi
        echo ""
        echo "  [y/Enter] Destroy    [p] Change prefix    [n] Cancel"
        echo ""
        echo -n "Choice: "
        read -r choice

        case "$choice" in
            y|Y|"")
                break
                ;;
            p|P)
                echo -n "New lab prefix [$lab_prefix]: "
                read -r new_prefix
                if [ -n "$new_prefix" ]; then
                    lab_prefix="$new_prefix"
                    cmd=("$exterminate_script" "$lab_prefix")
                    if [ -n "$ssh_key_path" ]; then
                        cmd+=(--ssh-key "$ssh_key_path")
                    fi
                fi
                ;;
            n|N)
                print_info "Teardown cancelled"
                exit 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac
    done

    if [ "$dry_run" = true ]; then
        print_info "Dry-run mode - would execute:"
        printf '  %q' "${cmd[@]}"
        echo ""
        exit 0
    fi

    echo ""
    print_info "Starting teardown..."
    echo ""

    cd /cave/backend
    yes 2>/dev/null | "${cmd[@]}"
}

main "$@"
