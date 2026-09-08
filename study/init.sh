#!/usr/bin/env bash
# =============================================================================
# init.sh — CloudClub 10기 시즌1 오픈스택 스터디 (6회차: 인스턴스 재료 준비, "INIT" 확인용)
#
# 전제: setup.sh → kolla-ansible pull → deploy 가 끝난 상태 (docker ps에 nova_compute 등 28개)
# 하는 일:
#   [1/4] deploy 확인 + post-deploy (admin-openrc.sh 없으면 생성)
#   [2/4] br-ex-gw.service — br-ex에 192.168.200.1/24 부여 + MASQUERADE + FORWARD ACCEPT (재부팅 생존)
#         ← br-ex는 deploy 때 OVS가 만들므로 setup.sh 단계에서는 줄 수 없음 (SU-Cloud 함정 7)
#   [3/4] OpenStack 리소스 (모두 멱등 — 있으면 건너뜀)
#         provider_network(flat/physnet1, FIP 풀 .101~.150) · tenant_network(10.10.10.0/24, DNS)
#         tenant_router(외부 IP .2 고정 ← 함정 6) · cirros 이미지 · m1.tiny · default SG에 ICMP/22
#   [4/4] "INIT ✅" + Horizon 접속 정보 + 다음 단계
#
# 실행: ./init.sh   (ubuntu 유저, 약 1~2분, 재실행 안전)
#
# 대역 (setup.sh와 공유. 바꾸면 교재도 같이):
#   external 192.168.200.0/24 — br-ex .1 / tenant_router .2 / FIP .101~.150
#   tenant   10.10.10.0/24
# =============================================================================
set -euo pipefail
trap 'echo -e "\n\033[1;31m[실패] init.sh:$LINENO 에서 중단 — 이 화면을 캡처해 단톡방에 공유해주세요\033[0m"' ERR

# ---------- 고정값 ----------
VENV="$HOME/kolla-venv"
KOLLA_DIR="/etc/kolla"
INVENTORY="$KOLLA_DIR/all-in-one"
OPENRC="$KOLLA_DIR/admin-openrc.sh"

EXT_NET="provider_network"; EXT_SUBNET="provider_subnet"
EXT_CIDR="192.168.200.0/24"; BR_EX_IP="192.168.200.1"; ROUTER_EXT_IP="192.168.200.2"
FIP_START="192.168.200.101"; FIP_END="192.168.200.150"
TENANT_NET="tenant_network"; TENANT_SUBNET="tenant_subnet"; TENANT_CIDR="10.10.10.0/24"
ROUTER="tenant_router"; DNS="8.8.8.8"
PHYSNET="physnet1"                      # kolla 기본 physnet ↔ br-ex 매핑
IMAGE="cirros"; CIRROS_VER="0.6.3"
CIRROS_FILE="cirros-${CIRROS_VER}-x86_64-disk.img"
CIRROS_URL="https://download.cirros-cloud.net/${CIRROS_VER}/${CIRROS_FILE}"
FLAVOR="m1.tiny"

log()  { echo -e "\n\033[1;36m[init] $*\033[0m"; }
warn() { echo -e "\033[1;33m[주의] $*\033[0m"; }
die()  { echo -e "\033[1;31m[중단] $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "[1/4] deploy 확인 + post-deploy"
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "root가 아닌 일반 유저(ubuntu)로 실행하세요"
[[ -d "$VENV" ]] || die "$VENV 가 없습니다 — setup.sh를 먼저 실행하세요"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

for c in nova_compute neutron_server neutron_l3_agent openvswitch_vswitchd keystone; do
    docker ps --format '{{.Names}}' | grep -qx "$c" || die "컨테이너 $c 가 없습니다 — deploy가 끝났는지 확인하세요 (docker ps)"
done
ip link show br-ex >/dev/null 2>&1 || die "br-ex 가 없습니다 — deploy 후 openvswitch 컨테이너가 만들어야 합니다"

if [[ ! -f "$OPENRC" ]]; then
    kolla-ansible post-deploy -i "$INVENTORY"
fi
[[ -f "$OPENRC" ]] || die "$OPENRC 생성 실패"

IFACE=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || die "기본 라우트 인터페이스를 찾지 못했습니다"

# ---------------------------------------------------------------------------
log "[2/4] br-ex-gw.service (게이트웨이 IP + NAT, 재부팅 생존)"
# ---------------------------------------------------------------------------
# 호스트가 192.168.200.1로 external 네트워크의 게이트웨이 역할.
#   경로 A (인스턴스 → 인터넷): 인스턴스 → qrouter SNAT(.2) → br-ex(.1) → MASQUERADE(eth0) → 가비아 NAT
#   경로 B (호스트 → FIP):      호스트 → br-ex → qrouter DNAT → 인스턴스   (MASQUERADE 미경유)
# br-ex는 openvswitch 컨테이너가 기동한 뒤에야 존재하므로 유닛이 최대 2분 기다린다.
sudo tee /etc/systemd/system/br-ex-gw.service >/dev/null <<EOF
[Unit]
Description=br-ex gateway IP + NAT for OpenStack external network (study)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do ip link show br-ex >/dev/null 2>&1 && exit 0; sleep 2; done; echo "br-ex not found"; exit 1'
ExecStart=/bin/sh -c 'ip addr show dev br-ex | grep -q "${BR_EX_IP}/" || ip addr add ${BR_EX_IP}/24 dev br-ex'
ExecStart=/sbin/ip link set br-ex up
ExecStart=/bin/sh -c 'iptables -t nat -C POSTROUTING -s ${EXT_CIDR} -o ${IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${EXT_CIDR} -o ${IFACE} -j MASQUERADE'
ExecStart=/bin/sh -c 'iptables -C FORWARD -s ${EXT_CIDR} -j ACCEPT 2>/dev/null || iptables -I FORWARD -s ${EXT_CIDR} -j ACCEPT'
ExecStart=/bin/sh -c 'iptables -C FORWARD -d ${EXT_CIDR} -j ACCEPT 2>/dev/null || iptables -I FORWARD -d ${EXT_CIDR} -j ACCEPT'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable br-ex-gw.service >/dev/null
sudo systemctl restart br-ex-gw.service
ip -4 addr show dev br-ex | grep -q "${BR_EX_IP}/" || die "br-ex 에 ${BR_EX_IP} 부여 실패 (systemctl status br-ex-gw)"

# ---------------------------------------------------------------------------
log "[3/4] OpenStack 리소스 (네트워크 · 라우터 · 이미지 · 플레이버 · 보안그룹)"
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$OPENRC"
openstack token issue -f value -c id >/dev/null || die "Keystone 인증 실패 — admin-openrc.sh 확인"

exists() { openstack "$1" show "$2" >/dev/null 2>&1; }

# external (provider) 네트워크 — FIP 풀. DHCP 없음, 게이트웨이 = br-ex(.1)
if ! exists network "$EXT_NET"; then
    openstack network create --external \
        --provider-network-type flat --provider-physical-network "$PHYSNET" "$EXT_NET"
fi
if ! exists subnet "$EXT_SUBNET"; then
    openstack subnet create "$EXT_SUBNET" --network "$EXT_NET" --no-dhcp \
        --subnet-range "$EXT_CIDR" --gateway "$BR_EX_IP" \
        --allocation-pool "start=${FIP_START},end=${FIP_END}"
fi

# tenant 네트워크 — DHCP + DNS (SU-Cloud 함정 9: DNS 미지정 시 인스턴스가 도메인 해석 불가)
exists network "$TENANT_NET" || openstack network create "$TENANT_NET"
if ! exists subnet "$TENANT_SUBNET"; then
    openstack subnet create "$TENANT_SUBNET" --network "$TENANT_NET" \
        --subnet-range "$TENANT_CIDR" --dns-nameserver "$DNS"
fi

# 라우터 — 외부 IP를 .2로 고정 (SU-Cloud 함정 6: 미지정 시 FIP 풀을 임의 잠식)
if ! exists router "$ROUTER"; then
    openstack router create "$ROUTER"
    openstack router set "$ROUTER" --external-gateway "$EXT_NET" \
        --fixed-ip "ip-address=${ROUTER_EXT_IP}"
    openstack router add subnet "$ROUTER" "$TENANT_SUBNET"
fi

# 이미지 — CirrOS (~20MB)
if ! exists image "$IMAGE"; then
    [[ -f "$HOME/$CIRROS_FILE" ]] || wget -q -O "$HOME/$CIRROS_FILE" "$CIRROS_URL"
    openstack image create "$IMAGE" --file "$HOME/$CIRROS_FILE" \
        --disk-format qcow2 --container-format bare --public
fi

# 플레이버 — 1 vCPU / 512MB / 1GB (8GB 호스트: KVM은 실제 사용분만 점유하므로 2대까지 OK)
exists flavor "$FLAVOR" || openstack flavor create --vcpus 1 --ram 512 --disk 1 "$FLAVOR"

# default 보안그룹 — ICMP + TCP 22 (admin 프로젝트의 default)
SG_ID=$(openstack security group list --project admin -f value -c ID -c Name | awk '$2=="default"{print $1; exit}')
[[ -n "$SG_ID" ]] || die "admin 프로젝트의 default 보안그룹을 찾지 못했습니다"
RULES=$(openstack security group rule list "$SG_ID" -f value -c "IP Protocol" -c "Port Range" -c Direction)
echo "$RULES" | grep -qE '^icmp .* ingress$'      || openstack security group rule create --protocol icmp "$SG_ID" >/dev/null
echo "$RULES" | grep -qE '^tcp 22:22 ingress$'    || openstack security group rule create --protocol tcp --dst-port 22 "$SG_ID" >/dev/null

# ---------------------------------------------------------------------------
log "[4/4] 완료"
# ---------------------------------------------------------------------------
VIP=$(grep -E '^kolla_internal_vip_address' "$KOLLA_DIR/globals.yml" | tail -n 1 | sed 's/.*"\([^"]*\)".*/\1/')
PUBLIC_IP=$(grep -E '^nova_novncproxy_fqdn' "$KOLLA_DIR/globals.yml" | tail -n 1 | sed 's/.*"\([^"]*\)".*/\1/' || true)
ADMIN_PW=$(grep -E '^keystone_admin_password' "$KOLLA_DIR/passwords.yml" | awk '{print $2}')

cat <<EOF

$(echo -e "\033[1;32m")=====================================================
  INIT ✅  — 이 화면을 캡처해서 단톡방에 인증해주세요!
=====================================================$(echo -e "\033[0m")

Horizon : http://${PUBLIC_IP:-<VM 공인 IP>}/      (사설 VIP: ${VIP})
  user  : admin
  pass  : ${ADMIN_PW}          # /etc/kolla/passwords.yml 의 keystone_admin_password

만들어진 것:
  ${EXT_NET} (${EXT_CIDR}, FIP ${FIP_START}~${FIP_END})  ← Network Topology에서 확인
  ${TENANT_NET} (${TENANT_CIDR})  ─ ${ROUTER} (외부 IP ${ROUTER_EXT_IP}) ─ ${EXT_NET}
  image ${IMAGE} · flavor ${FLAVOR} · default SG에 ICMP/22

다음 단계 (6회차 실습):
  1. Horizon → Compute → Key Pairs → 생성 (개인키 저장)
  2. Instances → Launch Instance: image ${IMAGE} / flavor ${FLAVOR} / network ${TENANT_NET} / key pair
  3. 인스턴스 → Associate Floating IP (${EXT_NET}에서 할당)
  4. 이 VM 셸에서:
       ping <FIP>
       ssh -i <개인키> cirros@<FIP>          # 🏁 시즌1 목표

CLI로 같은 일:
  source /etc/kolla/admin-openrc.sh
  openstack keypair create mykey > ~/mykey.pem && chmod 600 ~/mykey.pem
  openstack server create first-vm --image ${IMAGE} --flavor ${FLAVOR} --network ${TENANT_NET} --key-name mykey
  FIP=\$(openstack floating ip create ${EXT_NET} -f value -c floating_ip_address); echo \$FIP
  openstack server add floating ip first-vm \$FIP
  ssh -i ~/mykey.pem cirros@\$FIP

라우터의 실체 (6회차 마무리 5분):
  sudo ip netns list                                     # qrouter-*, qdhcp-*
  QR=\$(sudo ip netns list | grep -o 'qrouter-[^ ]*')
  sudo ip netns exec \$QR ip -4 a                         # 10.10.10.1 / ${ROUTER_EXT_IP}
  sudo ip netns exec \$QR iptables -t nat -L -n           # FIP = DNAT/SNAT 규칙
EOF
