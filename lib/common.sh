#!/usr/bin/env bash
# 공통 함수 + env.sh 로드. 각 스크립트가 `source "$(dirname "$0")/lib/common.sh"` 로 읽는다.

log()  { echo -e "\n\033[1;36m[$SCRIPT_TAG] $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✔ $*\033[0m"; }
warn() { echo -e "\033[1;33m[주의] $*\033[0m"; }
die()  { echo -e "\033[1;31m[중단] $*\033[0m" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/env.sh}"
STATE_FILE="$REPO_DIR/.state"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE 가 없습니다 — cp env.example env.sh (사이트 값은 sites/*.env 참고)"
# shellcheck disable=SC1090
source "$ENV_FILE"
# 10-deployer.sh 가 탐색·확정한 값 (CTRL_*/COMP_* 배열/VIRT_TYPE/TENANT_DNS, git 제외)
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

NODE_USER="${NODE_USER:-$USER}"
PROTECTED_IPS="${PROTECTED_IPS:-}"
for v in KOLLA_VERSION ANSIBLE_CORE_VERSION VENV KOLLA_DIR EXT_IF EXT_IF_PEER EXT_CIDR EXT_GW EXT_ROUTER_IP EXT_POOL_START EXT_POOL_END TENANT_CIDR; do
    [[ -n "${!v:-}" ]] || die "env.sh 에 $v 가 비어 있습니다"
done

INVENTORY="$KOLLA_DIR/multinode"

# env.sh 에 적힌 값만 (.state 로 덮이기 전). 재탐색할 때 이전 .state 값이 섞이지 않게.
env_get() { ( # shellcheck disable=SC1090
              . "$ENV_FILE"; printf '%s' "${!1:-}" ); }

require_nonroot() { [[ $EUID -ne 0 ]] || die "root가 아닌 일반 유저로 실행하세요"; }
require_ubuntu2404() {
    . /etc/os-release
    [[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 필요 (현재: ${PRETTY_NAME:-unknown})"
}

# 기본 라우트 NIC / 기본 게이트웨이 / 그 NIC의 IPv4
detect_iface() { ip -4 route show default | awk '{print $5; exit}'; }
detect_gw()    { ip -4 route show default | awk '{print $3; exit}'; }
iface_ip()     { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# NIC가 쓰는 상위 DNS (systemd-resolved 스텁 127.0.0.53 말고 실제 서버). 못 찾으면 빈 값.
detect_dns() {
    local d
    d=$(resolvectl dns "$1" 2>/dev/null | sed 's/^[^:]*://' | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | head -1 || true)
    [[ -n "$d" ]] || d=$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true)
    printf '%s' "$d"
}

valid_hostname() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ && "$1" != "localhost" ]]; }

# 보호 IP(PROTECTED_IPS)면 즉시 중단 (어떤 노드든). 비어 있으면 검사 안 함.
guard_ip() {
    local ip="$1" p
    [[ -n "$ip" ]] || die "IP가 비어 있습니다"
    for p in $PROTECTED_IPS; do
        [[ "$ip" == "$p" ]] && die "$ip 는 보호 IP(PROTECTED_IPS)입니다 — 이 머신/대상에서 실행하면 안 됩니다"
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

# 원격 노드 명령 (키 접속 전제)
ssh_node() { local ip="$1"; shift; ssh -o BatchMode=yes -o ConnectTimeout=5 "$NODE_USER@$ip" "$@"; }

# $1 CIDR 과 겹치는 라우트를 출력 (stdin: `ip -4 route show` 형식). 겹침 없으면 아무것도 안 나옴.
cidr_conflicts() {
    python3 -c '
import sys, ipaddress
n = ipaddress.ip_network(sys.argv[1], strict=False)
for line in sys.stdin:
    f = line.split()
    if not f or f[0] == "default":
        continue
    try:
        r = ipaddress.ip_network(f[0], strict=False)
    except ValueError:
        continue
    if n.overlaps(r):
        print(line.strip())
' "$1"
}

# EXT_* 값끼리 맞는지 (게이트웨이·라우터 IP·풀이 EXT_CIDR 안, 게이트웨이/라우터가 풀 밖). 문제 있으면 메시지 출력.
ext_values_check() {
    python3 -c '
import sys, ipaddress as I
net = I.ip_network(sys.argv[1], strict=False)
gw, rt, ps, pe = (I.ip_address(a) for a in sys.argv[2:6])
for name, ip in (("EXT_GW", gw), ("EXT_ROUTER_IP", rt), ("EXT_POOL_START", ps), ("EXT_POOL_END", pe)):
    if ip not in net: print(f"{name}={ip} 가 EXT_CIDR={net} 밖")
if ps > pe: print(f"EXT_POOL_START({ps}) > EXT_POOL_END({pe})")
for name, ip in (("EXT_GW", gw), ("EXT_ROUTER_IP", rt)):
    if ps <= ip <= pe: print(f"{name}={ip} 가 FIP 풀({ps}~{pe}) 안")
if gw == rt: print("EXT_GW 와 EXT_ROUTER_IP 가 같음")
' "$EXT_CIDR" "$EXT_GW" "$EXT_ROUTER_IP" "$EXT_POOL_START" "$EXT_POOL_END"
}

# 20/30 은 10-deployer.sh 가 저장한 .state 가 있어야 한다
require_state() {
    [[ -f "$STATE_FILE" ]] || die "$STATE_FILE 없음 — ./10-deployer.sh <compute IP> [...] 먼저"
    local v ip
    for v in CTRL_HOST CTRL_IP CTRL_IF VIRT_TYPE TENANT_DNS; do
        [[ -n "${!v:-}" ]] || die ".state 에 $v 가 비어 있습니다 — 10-deployer.sh 재실행"
    done
    [[ "$(declare -p COMP_IPS 2>/dev/null)" == "declare -a"* && ${#COMP_IPS[@]} -gt 0 ]] \
        || die ".state 가 이전 형식이거나 compute 목록이 없습니다 — 10-deployer.sh 재실행"
    guard_ip "$CTRL_IP"
    for ip in "${COMP_IPS[@]}"; do guard_ip "$ip"; done
}

ensure_nopasswd_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/kolla-nopasswd >/dev/null
        sudo chmod 0440 /etc/sudoers.d/kolla-nopasswd
        sudo visudo -c >/dev/null
    fi
}
