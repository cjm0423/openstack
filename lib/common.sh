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
# 10-deployer.sh 가 확정한 CTRL_IP/CTRL_IF/COMP_IP/COMP_IF (git 제외)
# shellcheck disable=SC1091
[[ -f "$REPO_DIR/.state" ]] && source "$REPO_DIR/.state"

for v in CTRL_HOST COMP_HOST PROTECTED_IPS NODE_USER KOLLA_VERSION ANSIBLE_CORE_VERSION VENV KOLLA_DIR EXT_IF EXT_IF_PEER EXT_CIDR EXT_GW; do
    [[ -n "${!v:-}" ]] || die "env.sh 에 $v 가 비어 있습니다"
done

INVENTORY="$KOLLA_DIR/multinode"

require_nonroot() { [[ $EUID -ne 0 ]] || die "root가 아닌 일반 유저($NODE_USER)로 실행하세요"; }
require_ubuntu2404() {
    . /etc/os-release
    [[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 필요 (현재: ${PRETTY_NAME:-unknown})"
}

# 기본 라우트 NIC / 기본 게이트웨이 / 그 NIC의 IPv4
detect_iface() { ip -4 route show default | awk '{print $5; exit}'; }
detect_gw()    { ip -4 route show default | awk '{print $3; exit}'; }
iface_ip()     { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# 운영계 IP면 즉시 중단 (어떤 노드든)
guard_ip() {
    local ip="$1" p
    [[ -n "$ip" ]] || die "IP가 비어 있습니다"
    for p in $PROTECTED_IPS; do
        [[ "$ip" == "$p" ]] && die "$ip 는 운영계 IP(PROTECTED_IPS)입니다 — 이 머신/대상에서 실행하면 안 됩니다"
    done
    return 0
}

# DHCP로 받은 주소면 중단 — 관리 IP는 OS 설치 때 고정으로 잡는다
require_static() {
    local ifc="$1"
    ip -4 -o addr show dev "$ifc" | grep -qw dynamic \
        && die "$ifc 의 IP가 DHCP(dynamic)입니다 — 설치 시 고정 IP로 잡으세요 (/etc/netplan 확인)"
    return 0
}

# 20/30 은 10-deployer.sh 가 저장한 .state 가 있어야 한다
require_state() {
    [[ -f "$REPO_DIR/.state" ]] || die "$REPO_DIR/.state 없음 — 10-deployer.sh <compute IP> 먼저"
    local v
    for v in CTRL_IP CTRL_IF COMP_IP COMP_IF; do
        [[ -n "${!v:-}" ]] || die ".state 에 $v 가 비어 있습니다 — 10-deployer.sh 재실행"
    done
    guard_ip "$CTRL_IP"; guard_ip "$COMP_IP"
}

ensure_nopasswd_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/kolla-nopasswd >/dev/null
        sudo chmod 0440 /etc/sudoers.d/kolla-nopasswd
        sudo visudo -c >/dev/null
    fi
}
