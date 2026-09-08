#!/usr/bin/env bash
# =============================================================================
# 00-node-prep.sh — 두 노드 모두에서 실행 (controller 먼저, 그다음 compute)
#
# 역할은 관리 NIC의 IP(env.sh의 CTRL_IP / COMP_IP)로 자동 판정. 강제: --role controller|compute
# 네트워크(netplan)는 기본적으로 "검증만" 한다. 새로 깔아서 IP가 아직 다르면 --write-netplan 로 고정 IP 작성.
#
# 하는 일:
#   [1/6] 환경 점검 (24.04, NOPASSWD sudo, 역할 판정, compute면 /dev/kvm)
#   [2/6] 호스트명 + /etc/hosts (127.0.1.1 치환, 두 노드 이름 등록)      ← 운영계 함정 1
#   [3/6] netplan 검증 (또는 --write-netplan 로 고정 IP·MAC 작성)
#   [4/6] 패키지 + chrony + sysctl (ip_forward, rp_filter=2)              ← 운영계 함정 2
#   [5/6] controller만: veth-setup.service (veth0 미부착)                  ← 운영계 함정 5
#   [6/6] controller만: SSH 키 생성 → compute 접근 안내
#
# 실행: ./00-node-prep.sh [--role controller|compute] [--write-netplan]   (재실행 안전)
# =============================================================================
set -euo pipefail
SCRIPT_TAG="node-prep"
source "$(dirname "$0")/lib/common.sh"
trap 'echo -e "\n\033[1;31m[실패] 00-node-prep.sh:$LINENO 에서 중단\033[0m"' ERR

ROLE=""; WRITE_NETPLAN="no"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --write-netplan) WRITE_NETPLAN="yes"; shift ;;
        *) die "알 수 없는 옵션: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
log "[1/6] 환경 점검"
# ---------------------------------------------------------------------------
require_nonroot; require_ubuntu2404; ensure_nopasswd_sudo
[[ "$USER" == "$NODE_USER" ]] || warn "현재 유저 $USER ≠ NODE_USER=$NODE_USER — 두 노드에서 같은 유저로 배포해야 합니다"

[[ -n "$ROLE" ]] || ROLE=$(whoami_role)
case "$ROLE" in
    controller) MY_HOST="$CTRL_HOST"; MY_IP="$CTRL_IP"; MY_IF="${CTRL_IF:-$(detect_iface)}"; MY_MAC="${CTRL_MAC:-}" ;;
    compute)    MY_HOST="$COMP_HOST"; MY_IP="$COMP_IP"; MY_IF="${COMP_IF:-$(detect_iface)}"; MY_MAC="${COMP_MAC:-}" ;;
    *) die "이 머신의 IP가 CTRL_IP/COMP_IP 어느 쪽도 아닙니다. 새로 깐 노드면 --role 과 --write-netplan 을 같이 주세요" ;;
esac
[[ -n "$MY_IF" ]] || die "관리 NIC를 찾지 못했습니다 (env.sh CTRL_IF/COMP_IF 를 지정)"
ip link show "$MY_IF" >/dev/null || die "NIC $MY_IF 가 없습니다"

echo "  역할   : $ROLE"
echo "  호스트 : $MY_HOST  ($MY_IP/$NET_PREFIX via $MY_IF, gw $NET_GW)"
if [[ "$ROLE" == "compute" || "$CTRL_IS_COMPUTE" == "yes" ]]; then
    if [[ -e /dev/kvm ]]; then ok "/dev/kvm 있음 (KVM 가속)"; else warn "/dev/kvm 없음 — BIOS에서 VT-x/AMD-V 확인. 없으면 qemu 에뮬레이션으로 배포됨"; fi
fi
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
(( MEM_GB >= 15 )) || warn "RAM ${MEM_GB}GB — controller는 16GB 이상 권장"

# ---------------------------------------------------------------------------
log "[2/6] 호스트명 + /etc/hosts"
# ---------------------------------------------------------------------------
[[ "$(hostname)" == "$MY_HOST" ]] || sudo hostnamectl set-hostname "$MY_HOST"
# 운영계 함정 1: 127.0.1.1 <호스트명> 줄이 남으면 RabbitMQ가 루프백에 바인드. 치환(tee -a 금지).
# bootstrap-servers(etc_hosts 롤)도 같은 처리를 하지만, prechecks 전에 로컬에서 확정해 둔다.
sudo sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
sudo sed -i "/[[:space:]]$CTRL_HOST\$/d; /[[:space:]]$COMP_HOST\$/d" /etc/hosts
printf '%s %s\n%s %s\n' "$CTRL_IP" "$CTRL_HOST" "$COMP_IP" "$COMP_HOST" | sudo tee -a /etc/hosts >/dev/null
[[ -d /etc/cloud/cloud.cfg.d ]] && echo 'manage_etc_hosts: false' | sudo tee /etc/cloud/cloud.cfg.d/99-kolla-hosts.cfg >/dev/null
getent hosts "$MY_HOST" | grep -q "^$MY_IP" || die "$MY_HOST 가 $MY_IP 로 안 풀립니다"
ok "/etc/hosts: $CTRL_HOST=$CTRL_IP, $COMP_HOST=$COMP_IP"

# ---------------------------------------------------------------------------
log "[3/6] netplan"
# ---------------------------------------------------------------------------
if [[ "$WRITE_NETPLAN" == "yes" ]]; then
    warn "netplan을 새로 씁니다 — 원격(Tailscale/SSH)이면 IP가 바뀌는 순간 세션이 끊길 수 있음. 콘솔에서 실행 권장"
    sudo mkdir -p /etc/netplan/bak && sudo mv /etc/netplan/*.yaml /etc/netplan/bak/ 2>/dev/null || true
    sudo tee /etc/netplan/50-kolla-mgmt.yaml >/dev/null <<NP
# 00-node-prep.sh 작성. 관리망 = 터널망 (캠퍼스 LAN). 브리지 없음 — veth0 미부착 설계라 brbond0가 필요 없음.
network:
  version: 2
  renderer: networkd
  ethernets:
    ${MY_IF}:
      dhcp4: false
$( [[ -n "$MY_MAC" ]] && printf '      macaddress: "%s"   # 캠퍼스 스위치 MAC ACL 등록값\n' "$MY_MAC" || true )
      addresses: [${MY_IP}/${NET_PREFIX}]
      routes:
        - to: default
          via: ${NET_GW}
      nameservers:
        addresses: [$(echo "$NET_DNS" | sed 's/,/, /g')]
NP
    sudo chmod 600 /etc/netplan/50-kolla-mgmt.yaml
    sudo netplan generate && sudo netplan apply
    sleep 2
fi
CUR_IP=$(iface_ip "$MY_IF")
[[ "$CUR_IP" == "$MY_IP" ]] || die "$MY_IF 의 IP가 $CUR_IP (기대: $MY_IP). --write-netplan 로 고정하거나 env.sh를 맞추세요"
ping -c1 -W2 "$NET_GW" >/dev/null || warn "게이트웨이 $NET_GW 응답 없음 — MAC 미등록이면 개발계 7월과 같은 증상(ARP는 되고 IP는 안 됨). 교수님께 MAC $(cat /sys/class/net/$MY_IF/address) 등록 요청"
ok "관리 IP $MY_IP on $MY_IF (MAC $(cat /sys/class/net/$MY_IF/address))"

# ---------------------------------------------------------------------------
log "[4/6] 패키지 + chrony + sysctl"
# ---------------------------------------------------------------------------
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    chrony curl wget git tmux python3-dev python3-venv libffi-dev gcc \
    libdbus-1-dev libglib2.0-dev pkg-config
sudo timedatectl set-timezone Asia/Seoul || true
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
log "[5/6] veth-setup.service (외부망 더미 NIC, 재부팅 생존)"
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
log "[6/6] SSH 키 (controller → compute)"
# ---------------------------------------------------------------------------
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "$NODE_USER@$CTRL_HOST" >/dev/null
echo "  공개키: $(cat ~/.ssh/id_ed25519.pub)"
cat <<MSG

controller 준비 끝. 다음:
  1) compute($COMP_IP)에서  ./00-node-prep.sh   (새 설치면 --role compute --write-netplan)
  2) 다시 여기서            ./10-deployer.sh    (키가 없으면 ssh-copy-id 를 한 번 물어봄)
MSG
else
log "[5/6] compute: veth 불필요 (OVN 게이트웨이 섀시 = network 그룹 = controller)"
log "[6/6] compute 준비 끝"
cat <<MSG

controller($CTRL_IP)에서 ./10-deployer.sh 를 실행하면 이 노드로 SSH 접속해 bootstrap-servers 를 돌립니다.
  확인: ssh $NODE_USER@$COMP_IP 'sudo -n true && echo sudo-ok'
MSG
fi
