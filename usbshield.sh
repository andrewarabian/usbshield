#!/bin/bash
set -eo pipefail

_USBSHIELD_ELEVATED=${_USBSHIELD_ELEVATED:-0}
if [[ $EUID -ne 0 ]]; then
    [[ "$_USBSHIELD_ELEVATED" == "1" ]] && { echo "  ERROR: Elevation failed. Recursive sudo may be disabled." >&2; exit 1; }
    _USBSHIELD_ELEVATED=1 exec sudo -E "$0" "$@"
fi

trap 'echo "  ERROR: unexpected failure at line $LINENO" >&2; exit 1' ERR

command -v usbguard >/dev/null 2>&1 || { echo "  ERROR: usbguard not found. Install it first." >&2; exit 1; }

resolve_class() {
    case "$1" in
        00) echo "Per-Interface" ;;
        02) echo "Communications" ;;
        03) echo "HID" ;;
        06) echo "Imaging" ;;
        07) echo "Printer" ;;
        08) echo "Mass Storage" ;;
        09) echo "Hub" ;;
        0a) echo "CDC Data" ;;
        0e) echo "Video" ;;
        e0) echo "Wireless/BT" ;;
        ef) echo "Miscellaneous" ;;
        ff) echo "Vendor-Specific" ;;
        *)  echo "Class 0x$1" ;;
    esac
}

COLS=$(tput cols 2>/dev/null) || COLS=80
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
SEP=$(printf '─%.0s' $(seq 1 "$((COLS - 2))"))

echo ""
echo "  [ Detected USB Devices ]"
echo "  $SEP"

index=0
rows=()
rows+=(" # | Manufacturer | Product | Serial | VID:PID | Class | Interfaces | Power | Port")

declare -a DEVICE_VIDPID
declare -a DEVICE_DESC
declare -a DEVICE_SERIAL
has_badusb_suspect=0

shopt -s nullglob

for dev_path in /sys/bus/usb/devices/*/; do
    idVendor=$(cat "$dev_path/idVendor" 2>/dev/null)   || continue
    idProduct=$(cat "$dev_path/idProduct" 2>/dev/null) || continue
    [[ -z "$idVendor" || "$idVendor" == "0000" ]] && continue
    [[ "$idVendor" == "1d6b" ]] && continue  # Linux Foundation (root hubs)
    [[ "$idVendor" == "8087" ]] && continue  # Intel integrated (BT/WiFi)
    [[ "$idVendor" == "1022" ]] && continue  # AMD integrated

    manufacturer=$(cat "$dev_path/manufacturer" 2>/dev/null || echo "Unknown")
    product=$(cat "$dev_path/product"           2>/dev/null || echo "Unknown")
    serial=$(cat "$dev_path/serial" 2>/dev/null | tr -d '[:space:]' || echo "—")

    dev_class=$(cat "$dev_path/bDeviceClass" 2>/dev/null | tr -d '[:space:]' || echo "??")
    class_label=$(resolve_class "$dev_class")

    num_interfaces=$(cat "$dev_path/bNumInterfaces" 2>/dev/null | tr -d '[:space:]' || echo "?")
    dev_name=$(basename "$dev_path")

    iface_classes=()
    # Interface subdirs follow sysfs naming: <device>:<config>.<iface>/
    for iface_path in "${dev_path}${dev_name}":*/; do
        iclass=$(cat "${iface_path}bInterfaceClass" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$iclass" ]] && iface_classes+=("$iclass")
    done

    if (( ${#iface_classes[@]} > 0 )); then
        mapfile -t unique_classes < <(printf '%s\n' "${iface_classes[@]}" | sort -u)
        iface_labels=()
        for c in "${unique_classes[@]}"; do
            iface_labels+=("$(resolve_class "$c")")
        done
        iface_display=$(printf '%s, ' "${iface_labels[@]}"); iface_display="${iface_display%, }"
    else
        iface_display="$num_interfaces"
    fi

    dev_has_hid=0; dev_has_storage=0; dev_has_cdc=0
    dev_has_video=0; dev_has_printer=0; dev_has_vendor=0
    for c in "${iface_classes[@]}"; do
        [[ "$c" == "03" ]] && dev_has_hid=1
        [[ "$c" == "08" ]] && dev_has_storage=1
        [[ "$c" == "02" || "$c" == "0a" ]] && dev_has_cdc=1
        [[ "$c" == "0e" ]] && dev_has_video=1
        [[ "$c" == "07" ]] && dev_has_printer=1
        [[ "$c" == "ff" ]] && dev_has_vendor=1
    done
    if (( dev_has_hid && (dev_has_storage || dev_has_cdc || dev_has_video || dev_has_printer || dev_has_vendor) )); then
        iface_display="${iface_display} [!]"
        has_badusb_suspect=1
    fi

    max_power_raw=$(cat "$dev_path/bMaxPower" 2>/dev/null | tr -d '[:space:]' || echo "?")
    if [[ -n "$max_power_raw" && "$max_power_raw" =~ ^[0-9]+$ ]]; then
        max_power=$(( max_power_raw * 2 ))
    else
        max_power="?"
    fi

    port=$(basename "$dev_path")

    index=$((index + 1))
    DEVICE_VIDPID[$index]="${idVendor}:${idProduct}"
    DEVICE_DESC[$index]="$manufacturer $product"
    DEVICE_SERIAL[$index]="$serial"
    rows+=(" $index | $manufacturer | $product | $serial | ${idVendor}:${idProduct} | $class_label | $iface_display | ${max_power}mA | $port")
done

shopt -u nullglob

printf '%s\n' "${rows[@]}" | column -t -s '|' | sed 's/^/ /'
echo "  $SEP"

if [[ $index -eq 0 ]]; then
    echo ""
    echo "  No external USB devices detected."
    echo ""
    exit 2
fi

echo ""
(( has_badusb_suspect )) && echo "  [!] One or more devices combine HID with Mass Storage, network, video, printer, or vendor-specific interfaces - a common BadUSB indicator. Verify before proceeding."
echo ""

# ── Device selection ──────────────────────────────────────────────────────────

read -rt 60 -p "  Select device to authorize (1-$index): " selection || { echo ""; echo "  Timed out. Aborting."; exit 1; }

if ! [[ "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > index )); then
    echo "  Invalid selection. Aborting."
    exit 1
fi

echo ""
echo "  Selected: ${DEVICE_DESC[$selection]}  [${DEVICE_VIDPID[$selection]}]"
echo ""
read -rt 60 -p "  New Label: " label || { echo ""; echo "  Timed out. Aborting."; exit 1; }
label="${label// /-}"
label="${label//[^a-zA-Z0-9._-]/}"

if [[ -z "$label" ]]; then
    echo "  No label entered. Aborting."
    exit 1
fi

# ── Verify device still present ───────────────────────────────────────────────

still_present=0
for dev_path in /sys/bus/usb/devices/*/; do
    vid=$(cat "$dev_path/idVendor"  2>/dev/null | tr -d '[:space:]') || continue
    pid=$(cat "$dev_path/idProduct" 2>/dev/null | tr -d '[:space:]') || continue
    ser=$(cat "$dev_path/serial"    2>/dev/null | tr -d '[:space:]') || ser="—"
    if [[ "${vid}:${pid}" == "${DEVICE_VIDPID[$selection]}" ]] &&
       { [[ "${DEVICE_SERIAL[$selection]}" == "—" ]] || [[ "$ser" == "${DEVICE_SERIAL[$selection]}" ]]; }; then
        still_present=1
        break
    fi
done

if (( ! still_present )); then
    echo "  ERROR: Selected device no longer detected. Was it unplugged?"
    exit 1
fi

# ── Generate and annotate policy ─────────────────────────────────────────────

echo ""
echo "  Generating policy..."

dev_serial="${DEVICE_SERIAL[$selection]}"
device_found=0
annotated=""

while IFS= read -r line; do
    if [[ "$line" == *"${DEVICE_VIDPID[$selection]}"* ]] &&
       { [[ "$dev_serial" == "—" ]] || [[ "$line" == *"$dev_serial"* ]]; } &&
       (( ! device_found )); then
        annotated+="# $label"$'\n'
        device_found=1
    fi
    annotated+="$line"$'\n'
done < <(usbguard generate-policy)

if [[ -z "$annotated" ]]; then
    echo "  ERROR: usbguard generate-policy returned nothing."
    exit 1
fi

if (( ! device_found )); then
    echo "  ERROR: Selected device not found in generated policy. Aborting."
    exit 1
fi

# ── Atomic write with backup ──────────────────────────────────────────────────

rules_file="/etc/usbguard/rules.conf"
rules_backup="${rules_file}.bak.$(date +%s)-${RANDOM}"

if [[ -f "$rules_file" ]]; then
    cp "$rules_file" "$rules_backup" || { echo "  ERROR: Could not create backup. Aborting."; exit 1; }
    chmod 600 "$rules_backup"
fi

[[ -d /etc/usbguard ]] || { echo "  ERROR: /etc/usbguard directory not found." >&2; exit 1; }
tmp_rules=$(mktemp /etc/usbguard/rules.conf.XXXXXX) || { echo "  ERROR: Could not create temporary file." >&2; exit 1; }
[[ -L "$tmp_rules" ]] && { echo "  ERROR: Symlink detected in temp path. Aborting." >&2; rm -f "$tmp_rules"; exit 1; }
trap "rm -f '$tmp_rules'" EXIT
printf '%s' "$annotated" > "$tmp_rules"
chmod 600 "$tmp_rules"
mv "$tmp_rules" "$rules_file"
trap - EXIT

rule_count=$(grep -c '^allow\|^block' <<< "$annotated" || true)
annotated=""; unset annotated

# ── Restart and report ────────────────────────────────────────────────────────

if systemctl restart usbguard; then
    echo "  USBGuard restarted."
else
    echo "  USBGuard not running - enable with: sudo systemctl enable --now usbguard"
fi

echo "  Done. [$label] authorized - ${rule_count} rule(s) written."
echo ""
