#!/usr/bin/env bash
# USBGuard: First-time setup
# Detects package manager, installs usbguard, seeds an initial policy,
# and enables the service so new devices are blocked by default.

set -euo pipefail

# ── colour ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R=$'\033[0m' BOLD=$'\033[1m'
    OK=$'\033[1;32m' INFO=$'\033[34m' WARN=$'\033[33m' ERR=$'\033[1;31m'
else
    R='' BOLD='' OK='' INFO='' WARN='' ERR=''
fi

log_info()  { printf "${INFO}[INFO]${R}  %s\n" "$*"; }
log_ok()    { printf "${OK}[ OK ]${R}  %s\n" "$*"; }
log_warn()  { printf "${WARN}[WARN]${R}  %s\n" "$*"; }
log_err()   { printf "${ERR}[ ERR]${R}  %s\n" "$*" >&2; }
die()       { log_err "$*"; exit 1; }

hline() { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'; }

# ── root check ────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "Not running as root. Re-executing with sudo..."
        exec sudo bash "$0" "$@"
    fi
}

# ── distro / package manager detection ───────────────────────────────────────
detect_pm() {
    if   command -v apt-get  &>/dev/null; then PM=apt
    elif command -v dnf      &>/dev/null; then PM=dnf
    elif command -v yum      &>/dev/null; then PM=yum
    elif command -v zypper   &>/dev/null; then PM=zypper
    elif command -v pacman   &>/dev/null; then PM=pacman
    elif command -v apk      &>/dev/null; then PM=apk
    elif command -v emerge   &>/dev/null; then PM=portage
    elif command -v pkg      &>/dev/null; then PM=pkg       # FreeBSD
    elif command -v brew     &>/dev/null; then PM=brew      # macOS / Linuxbrew
    else
        die "No supported package manager found. Install usbguard manually."
    fi

    NEED_EPEL=0
    if [[ $PM == dnf || $PM == yum ]]; then
        if [[ -f /etc/os-release ]]; then
            source /etc/os-release
            case "${ID:-}" in
                rhel|centos|rocky|almalinux|ol)
                    NEED_EPEL=1 ;;
                fedora)
                    NEED_EPEL=0 ;;
            esac
        fi
    fi
}

# ── installation ─────────────────────────────────────────────────────────────
install_usbguard() {
    log_info "Package manager: ${BOLD}${PM}${R}"
    case $PM in
        apt)
            apt-get update -qq
            apt-get install -y usbguard
            ;;
        dnf)
            if [[ $NEED_EPEL -eq 1 ]]; then
                log_info "RHEL-family detected, installing EPEL first"
                dnf install -y epel-release
            fi
            dnf install -y usbguard
            ;;
        yum)
            if [[ $NEED_EPEL -eq 1 ]]; then
                log_info "RHEL-family detected, installing EPEL first"
                yum install -y epel-release
            fi
            yum install -y usbguard
            ;;
        zypper)
            zypper install -y usbguard
            ;;
        pacman)
            pacman -Sy --noconfirm usbguard
            ;;
        apk)
            # usbguard lives in the community repo; Alpine needs udev (eudev)
            apk add --no-cache usbguard eudev
            ;;
        portage)
            emerge --ask=n sys-apps/usbguard
            ;;
        pkg)
            # usbguard uses Linux-specific netlink/udev, not available on FreeBSD
            die "usbguard is Linux-only and is not available via FreeBSD pkg. Use devd rules for USB control instead."
            ;;
        brew)
            die "usbguard requires the Linux kernel and is not available on macOS."
            ;;
    esac
}

# ── verify installation ───────────────────────────────────────────────────────
verify_install() {
    local missing=()
    command -v usbguard &>/dev/null || missing+=(usbguard)

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Installation appears incomplete, missing: ${missing[*]}"
    fi
    log_ok "usbguard  : $(command -v usbguard)"
    log_ok "version   : $(usbguard --version 2>/dev/null | head -1 || echo 'unknown')"
}

# ── initial policy ────────────────────────────────────────────────────────────
init_policy() {
    local rules_file="/etc/usbguard/rules.conf"
    local rules_dir="/etc/usbguard"

    [[ -d "$rules_dir" ]] || mkdir -p "$rules_dir"

    if [[ -f "$rules_file" ]]; then
        log_info "Policy file already exists, skipping generation"
        log_info "To regenerate: sudo usbguard generate-policy > $rules_file"
        return
    fi

    log_info "Generating initial policy from currently connected devices…"
    log_warn "All devices plugged in RIGHT NOW will be allowed. Unplug untrusted devices first."
    echo ""
    read -rt 30 -p "  Press ENTER to continue or Ctrl-C to abort: " _ || true
    echo ""

    # generate-policy snapshots currently connected devices as allow rules
    usbguard generate-policy > "$rules_file"
    chmod 600 "$rules_file"

    local rule_count
    rule_count=$(grep -c '^allow\|^block' "$rules_file" 2>/dev/null || echo 0)
    log_ok "Policy seeded with ${rule_count} rule(s) → ${rules_file}"
}

# ── service setup ─────────────────────────────────────────────────────────────
enable_service() {
    if ! command -v systemctl &>/dev/null; then
        log_warn "systemctl not found, skipping service setup"
        log_warn "Start usbguard manually with: sudo usbguard daemon -d"
        return
    fi

    if ! systemctl is-enabled --quiet usbguard 2>/dev/null; then
        systemctl enable usbguard
        log_ok "usbguard service enabled"
    else
        log_info "usbguard service already enabled"
    fi

    if systemctl start usbguard; then
        log_ok "usbguard service started"
    else
        log_warn "usbguard failed to start. Check: sudo journalctl -u usbguard"
    fi
}

# ── install usbwarden ─────────────────────────────────────────────────────────
install_helper() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local helper="${script_dir}/usbwarden.sh"

    if [[ -f "$helper" ]]; then
        install -m 0755 -o root -g root "$helper" /usr/local/bin/usbwarden
        log_ok "Installed helper → /usr/local/bin/usbwarden"
    else
        log_warn "usbwarden.sh not found in ${script_dir}, skipping"
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    require_root "$@"

    hline
    printf "${BOLD}  USBGuard: First-time Setup${R}\n"
    hline
    echo ""

    detect_pm
    install_usbguard
    echo ""
    verify_install
    echo ""
    init_policy
    echo ""
    enable_service
    install_helper

    echo ""
    hline
    printf "${OK}  Setup complete.${R}\n"
    hline
    log_ok "usbguard installed and service running."
    echo ""
}

main "$@"
