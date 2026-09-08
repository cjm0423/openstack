#!/usr/bin/env bash
# 공통 함수 + env.sh 로드. 각 스크립트가 `source "$(dirname "$0")/lib/common.sh"` 로 읽는다.

log()  { echo -e "\n\033[1;36m[$SCRIPT_TAG] $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m[주의] $*\033[0m"; }
die()  { echo -e "\033[1;31m[중단] $*\033[0m" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/env.sh}"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE 가 없습니다 — cp env.example env.sh 후 값을 채우세요"
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in CTRL_HOST CTRL_IP COMP_HOST COMP_IP NET_PREFIX NET_GW NODE_USER KOLLA_VERSION ANSIBLE_CORE_VERSION VENV KOLLA_DIR EXT_IF EXT_IF_PEER EXT_CIDR EXT_GW; do
    [[ -n "${!v:-}" ]] || die "env.sh 에 $v 가 비어 있습니다"
done

INVENTORY="$KOLLA_DIR/multinode"

require_nonroot() { [[ $EUID -ne 0 ]] || die "root가 아닌 일반 유저($NODE_USER)로 실행하세요"; }
require_ubuntu2404() {
    . /etc/os-release
    [[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 필요 (현재: ${PRETTY_NAME:-unknown})"
}

# 기본 라우트 NIC / 그 NIC의 IPv4
detect_iface() { ip -4 route show default | awk '{print $5; exit}'; }
iface_ip()     { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# 이 머신이 controller인지 compute인지 — IP로 판정
whoami_role() {
    local ifc; ifc=$(detect_iface)
    local ip;  ip=$(iface_ip "$ifc")
    case "$ip" in
        "$CTRL_IP") echo controller ;;
        "$COMP_IP") echo compute ;;
        *) echo unknown ;;
    esac
}

ensure_nopasswd_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/kolla-nopasswd >/dev/null
        sudo chmod 0440 /etc/sudoers.d/kolla-nopasswd
        sudo visudo -c >/dev/null
    fi
}
