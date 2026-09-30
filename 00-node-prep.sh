#!/usr/bin/env bash
# =============================================================================
# 00-node-prep.sh — 모든 노드에서 실행 (controller 먼저, 그다음 compute 각각)
#
# 역할은 --role 로 반드시 지정 (IP로 판정하지 않음).
# IP는 OS 설치 때 고정으로 잡는다는 전제 — 이 스크립트는 netplan을 쓰지 않고 읽기만 한다.
# 호스트명: --hostname > (controller면) env.sh CTRL_HOST > 현재 hostname. 인벤토리 이름이 되므로 노드끼리 겹치면 안 됨.
#
# 하는 일:
#   [1/5] 환경 점검 (24.04, NOPASSWD sudo, 관리 IP 읽기 + 보호 IP 가드 + DHCP 금지, gw ping, compute면 /dev/kvm)
#   [2/5] 호스트명 + /etc/hosts (127.0.1.1 삭제, 자기 IP 한 줄)           ← 운영계 함정 1
#   [3/5] 패키지 + chrony (+ TIMEZONE) + sysctl (ip_forward, rp_filter=2)  ← 운영계 함정 2
#   [4/5] controller만: veth-setup.service (veth0 미부착)                  ← 운영계 함정 5
#   [5/5] controller만: SSH 키 생성 → compute 접근 안내
#
# 실행: ./00-node-prep.sh --role controller|compute [--hostname 이름]   (재실행 안전)
# =============================================================================
set -euo pipefail
SCRIPT_TAG="node-prep"
source "$(dirname "$0")/lib/common.sh"
trap 'echo -e "\n\033[1;31m[실패] 00-node-prep.sh:$LINENO 에서 중단\033[0m"' ERR

ROLE=""; HOST_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)     [[ $# -ge 2 ]] || die "--role 뒤에 controller|compute"; ROLE="$2"; shift 2 ;;
        --hostname) [[ $# -ge 2 ]] || die "--hostname 뒤에 이름"; HOST_ARG="$2"; shift 2 ;;
        *) die "알 수 없는 옵션: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
log "[1/5] 환경 점검"
# ---------------------------------------------------------------------------
case "$ROLE" in
    controller) MY_HOST="${HOST_ARG:-$(env_get CTRL_HOST)}"; MY_IF="$(env_get CTRL_IF)" ;;
    compute)    MY_HOST="$HOST_ARG";                         MY_IF="$(env_get COMP_IF)" ;;
    "") die "--role controller|compute 를 지정하세요" ;;
    *)  die "--role 은 controller 또는 compute (받은 값: $ROLE)" ;;
esac
MY_HOST="${MY_HOST:-$(hostname)}"
MY_IF="${MY_IF:-$(detect_iface)}"
valid_hostname "$MY_HOST" || die "호스트명 '$MY_HOST' 사용 불가 (소문자·숫자·- 만, localhost 금지) — --hostname 으로 지정"
require_nonroot; require_ubuntu2404; ensure_nopasswd_sudo
[[ "$USER" == "$NODE_USER" ]] || warn "현재 유저 $USER ≠ NODE_USER=$NODE_USER — 모든 노드에서 같은 유저로 배포해야 합니다"

[[ -n "$MY_IF" ]] || die "관리 NIC를 찾지 못했습니다 (기본 라우트 없음 — env.sh CTRL_IF/COMP_IF 를 지정)"
ip link show "$MY_IF" >/dev/null || die "NIC $MY_IF 가 없습니다"
MY_IP=$(iface_ip "$MY_IF")
[[ -n "$MY_IP" ]] || die "$MY_IF 에 IPv4가 없습니다 — 설치 시 고정 IP를 잡았는지 확인"
guard_ip "$MY_IP"
require_static "$MY_IF"
MY_MAC=$(cat "/sys/class/net/$MY_IF/address")
NET_GW=$(detect_gw)

echo "  역할   : $ROLE"
echo "  호스트 : $MY_HOST  ($MY_IP via $MY_IF, MAC $MY_MAC, gw ${NET_GW:-없음})"
if [[ -z "$NET_GW" ]]; then
    warn "기본 게이트웨이 없음 — 설치 시 gateway를 넣었는지 확인"
else
    ping -c1 -W2 "$NET_GW" >/dev/null || warn "게이트웨이 $NET_GW 응답 없음 — 스위치에 MAC 필터가 있으면 미등록 증상(ARP는 되고 IP는 안 됨). MAC $MY_MAC 등록 확인"
fi
if [[ "$ROLE" == "compute" || "$CTRL_IS_COMPUTE" == "yes" ]]; then
    if [[ -e /dev/kvm ]]; then ok "/dev/kvm 있음 (KVM 가속)"; else warn "/dev/kvm 없음 — BIOS에서 VT-x/AMD-V 켜기. 이대로면 10-deployer.sh 가 중단함"; fi
fi
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
(( MEM_GB >= 15 )) || warn "RAM ${MEM_GB}GB — controller는 16GB 이상 권장"
ok "관리 IP $MY_IP on $MY_IF (고정)"

# ---------------------------------------------------------------------------
log "[2/5] 호스트명 + /etc/hosts"
# ---------------------------------------------------------------------------
[[ "$(hostname)" == "$MY_HOST" ]] || sudo hostnamectl set-hostname "$MY_HOST"
# 운영계 함정 1: 127.0.1.1 <호스트명> 줄이 남으면 RabbitMQ가 루프백에 바인드. 삭제 후 자기 IP 한 줄만(tee -a 누적 금지).
# 다른 노드 이름은 bootstrap-servers(kolla etc_hosts 롤)가 인벤토리 기준으로 모든 노드에 등록한다.
sudo sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
sudo sed -i "/[[:space:]]$MY_HOST\$/d" /etc/hosts
printf '%s %s\n' "$MY_IP" "$MY_HOST" | sudo tee -a /etc/hosts >/dev/null
[[ -d /etc/cloud/cloud.cfg.d ]] && echo 'manage_etc_hosts: false' | sudo tee /etc/cloud/cloud.cfg.d/99-kolla-hosts.cfg >/dev/null
# `getent hosts | grep -q` 가 cmp1(24.04)에서 스크립트 안에서만 매번 실패(원인 미확정) → IPv4만 조회해 첫 결과를 직접 비교.
# ahostsv4 는 kolla rabbitmq precheck(roles/rabbitmq/tasks/precheck.yml)와 같은 조회 방식.
read -r RES_IP _ < <(getent ahostsv4 "$MY_HOST") || true
[[ "${RES_IP:-}" == "$MY_IP" ]] || die "$MY_HOST 가 $MY_IP 로 안 풀립니다 (조회 결과: ${RES_IP:-없음})"
ok "/etc/hosts: $MY_HOST=$MY_IP"

# ---------------------------------------------------------------------------
log "[3/5] 패키지 + chrony + sysctl"
# ---------------------------------------------------------------------------
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    chrony curl wget git tmux python3-dev python3-venv libffi-dev gcc \
    libdbus-1-dev libglib2.0-dev pkg-config
if [[ -n "${TIMEZONE:-}" ]]; then sudo timedatectl set-timezone "$TIMEZONE"; fi
sudo systemctl enable --now chrony
# 운영계 함정 2: rp_filter strict면 FIP 응답 무로그 drop. ip_forward는 kolla가 docker 쪽을 끄므로 직접.
sudo tee /etc/sysctl.d/99-kolla.conf >/dev/null <<'SYS'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYS
sudo sysctl --system >/dev/null
ok "rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter), ip_forward=$(sysctl -n net.ipv4.ip_forward)"

# ---------------------------------------------------------------------------
if [[ "$ROLE" == "controller" ]]; then
log "[4/5] veth-setup.service (외부망 더미 NIC, 재부팅 생존)"
# ---------------------------------------------------------------------------
# 운영계 함정 5: veth0을 브리지/NIC에 물리지 않는다 (플러딩 유출 장애). UP만.
# br-ex IP(192.168.200.1)는 deploy 후 OVS가 br-ex를 만든 뒤 30-init.sh(br-ex-gw.service)가 부여.
sudo tee /etc/systemd/system/veth-setup.service >/dev/null <<UNIT
[Unit]
Description=Create veth pair for Neutron external interface (SU-Cloud)
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStartPre=-/sbin/ip link del ${EXT_IF_PEER}
ExecStart=/sbin/ip link add ${EXT_IF_PEER} type veth peer name ${EXT_IF}
ExecStart=/sbin/ip link set ${EXT_IF_PEER} up
ExecStart=/sbin/ip link set ${EXT_IF} up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable veth-setup.service >/dev/null
sudo systemctl restart veth-setup.service
ip link show "$EXT_IF" >/dev/null || die "$EXT_IF 생성 실패"
ok "$EXT_IF / $EXT_IF_PEER UP (미부착)"

# ---------------------------------------------------------------------------
log "[5/5] SSH 키 (controller → compute)"
# ---------------------------------------------------------------------------
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "$NODE_USER@$MY_HOST" >/dev/null
echo "  공개키: $(cat ~/.ssh/id_ed25519.pub)"
cat <<MSG

controller $MY_HOST($MY_IP) 준비 끝. 다음:
  1) compute 각각에서   ./00-node-prep.sh --role compute [--hostname 이름]
  2) 다시 여기서        ./10-deployer.sh --discover <compute IP> [<compute IP> ...]   (탐색 결과만 확인)
                        ./10-deployer.sh <compute IP> [<compute IP> ...]              (배포 준비, 키가 없으면 ssh-copy-id 1회)
MSG
else
log "[4/5] compute: veth 불필요 (OVN 게이트웨이 섀시 = network 그룹 = controller)"
log "[5/5] compute 준비 끝"
cat <<MSG

compute $MY_HOST($MY_IP) 준비 끝. controller에서 ./10-deployer.sh 의 인자로 $MY_IP 를 넣으면
이 노드로 SSH 접속해 탐색하고 bootstrap-servers 를 돌립니다.
  확인(controller에서): ssh $NODE_USER@$MY_IP 'sudo -n true && echo sudo-ok'
MSG
fi
