#!/usr/bin/env bash
# =============================================================================
# 30-init.sh — controller에서, deploy 후 1회. 운영계 구축 기록 Step 6~7 이식.
#
#   [1/3] br-ex-gw.service — br-ex에 EXT_GW(env.sh) + MASQUERADE/FORWARD + VM→관리 영역 격리 (재부팅 생존)   ← 운영계 함정 7·10
#   [2/3] provider_network(FIP 풀) · tenant_network · tenant_router(외부 IP 명시) · cirros · m1.tiny · SG   ← 함정 6·9
#   [3/3] 스모크 테스트 안내 (compute 노드에 인스턴스가 뜨는지)
#
# 실행: ./30-init.sh   (재실행 안전)
# =============================================================================
set -euo pipefail
SCRIPT_TAG="init"
source "$(dirname "$0")/lib/common.sh"
trap 'echo -e "\n\033[1;31m[실패] 30-init.sh:$LINENO 에서 중단\033[0m"' ERR

require_nonroot
require_state   # CTRL_HOST/IP/IF, COMP_HOSTS/IPS/IFS, VIRT_TYPE, TENANT_DNS ← .state (10-deployer.sh)
[[ "$(hostname)" == "$CTRL_HOST" ]] || die "controller($CTRL_HOST)에서 실행하세요"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
[[ -f "$KOLLA_DIR/admin-openrc.sh" ]] || die "admin-openrc.sh 없음 — 20-deploy.sh 먼저"
# shellcheck disable=SC1091
source "$KOLLA_DIR/admin-openrc.sh"
docker ps --format '{{.Names}}' | grep -q '^ovn_controller$' || die "ovn_controller 컨테이너 없음 — deploy 미완료"
ip link show br-ex >/dev/null 2>&1 || die "br-ex 없음 — $EXT_IF 편입 실패 (docker exec openvswitch_vswitchd ovs-vsctl show)"
openstack service list >/dev/null || die "openstack CLI 인증 실패"

# ---------------------------------------------------------------------------
log "[1/3] br-ex 게이트웨이 IP + NAT (systemd)"
# ---------------------------------------------------------------------------
# br-ex는 deploy 후 OVS가 만들므로 부팅 때마다 docker 이후에 부여 (운영계 함정 7).
# FORWARD는 kolla가 docker iptables 관리를 꺼서 ACCEPT지만 방어적으로 명시 (함정 10).
# FIP 경로: 인스턴스 → geneve → controller(게이트웨이 섀시) → br-ex → 호스트 IP 스택 → MASQUERADE(${CTRL_IF})
#
# VM → 관리 영역 격리 (ISOLATE_VMS=yes): br-ex로 들어온 VM 트래픽이 호스트 IP 스택을 타므로
#   INPUT  : EXT_CIDR 소스의 NEW 연결 전부 DROP — 목적지를 CTRL_IP로 한정하지 않는다
#            (sshd 등이 0.0.0.0 에 떠 있어 EXT_GW·Tailscale IP로도 닿기 때문). NEW만이라 ctrl → VM 응답은 통과.
#   FORWARD: EXT_CIDR → ctrl 직결 대역 전부(br-ex/EXT_CIDR·docker 브리지·tailscale 제외) + ISOLATE_EXTRA_CIDRS DROP.
#            인터넷(MASQUERADE)은 그대로.
# 순서: ACCEPT 규칙들 다음에 각 DROP을 지우고(-D, 중복까지) 다시 맨 위에 넣는다(-I) — -C 방식은 이후 -I ACCEPT에 밀려 순서가 뒤집힘.
ISOLATE_VMS="${ISOLATE_VMS:-yes}"
ISOLATE_EXTRA_CIDRS="${ISOLATE_EXTRA_CIDRS-100.64.0.0/10}"
[[ "$ISOLATE_VMS" == "yes" || "$ISOLATE_VMS" == "no" ]] || die "env.sh ISOLATE_VMS 는 yes 또는 no (현재: $ISOLATE_VMS)"
# ctrl에 직접 연결된 IPv4 대역 전부 (예: "210.94.240.0/24 dev enp7s0f0 proto kernel scope link src ...").
# 제외: EXT_CIDR 자신(br-ex), docker 브리지(docker0, br-<12hex>), tailscale 인터페이스
CONNECTED_CIDRS=()
while read -r cidr _ dev _; do
    [[ -n "$cidr" && "$cidr" != "$EXT_CIDR" ]] || continue
    [[ "$dev" == "br-ex" || "$dev" == "docker0" || "$dev" =~ ^br-[0-9a-f]{12}$ || "$dev" == tailscale* ]] && continue
    CONNECTED_CIDRS+=("$cidr")
done < <(ip -4 route show proto kernel scope link)
if [[ "$ISOLATE_VMS" == "yes" ]]; then
    (( ${#CONNECTED_CIDRS[@]} > 0 )) || die "ctrl 직결 대역(proto kernel scope link 라우트)을 하나도 찾지 못했습니다"
    ok "격리 대상: ${CONNECTED_CIDRS[*]} ${ISOLATE_EXTRA_CIDRS} (+ INPUT: ${EXT_CIDR} 발 NEW 전부)"
    for c in "${CONNECTED_CIDRS[@]}"; do
        C=$(cidr_conflicts "$TENANT_DNS/32" <<<"$c")
        [[ -z "$C" ]] || warn "TENANT_DNS $TENANT_DNS 가 격리 대역 $c 안 — VM이 이 DNS에 못 닿음 (env.sh TENANT_DNS 변경)"
    done
fi
ISO_RULES=("INPUT -s ${EXT_CIDR} -m conntrack --ctstate NEW -j DROP")
for c in "${CONNECTED_CIDRS[@]}" $ISOLATE_EXTRA_CIDRS; do ISO_RULES+=("FORWARD -s ${EXT_CIDR} -d ${c} -j DROP"); done
ISO_BLOCK="# --- VM → 관리 영역 격리 (ISOLATE_VMS=${ISOLATE_VMS}) — ACCEPT 다음에 지우고(-D), yes면 맨 위에 다시(-I) ---"
for r in "${ISO_RULES[@]}"; do
    ISO_BLOCK+=$'\n'"while iptables -D ${r} 2>/dev/null; do :; done"
    if [[ "$ISOLATE_VMS" == "yes" ]]; then ISO_BLOCK+=$'\n'"iptables -I ${r}"; fi
done

sudo tee /usr/local/sbin/kolla-ext-gw.sh >/dev/null <<SH
#!/usr/bin/env bash
set -e
until ip link show br-ex >/dev/null 2>&1; do sleep 2; done
ip addr replace ${EXT_GW}/${EXT_CIDR#*/} dev br-ex
ip link set br-ex up
iptables -t nat -C POSTROUTING -s ${EXT_CIDR} -o ${CTRL_IF} -j MASQUERADE 2>/dev/null \\
  || iptables -t nat -A POSTROUTING -s ${EXT_CIDR} -o ${CTRL_IF} -j MASQUERADE
iptables -C FORWARD -s ${EXT_CIDR} -j ACCEPT 2>/dev/null \\
  || iptables -I FORWARD -s ${EXT_CIDR} -j ACCEPT
iptables -C FORWARD -d ${EXT_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \\
  || iptables -I FORWARD -d ${EXT_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
${ISO_BLOCK}
SH
sudo chmod +x /usr/local/sbin/kolla-ext-gw.sh
sudo tee /etc/systemd/system/br-ex-gw.service >/dev/null <<'UNIT'
[Unit]
Description=Assign gateway IP + NAT to br-ex for Neutron external network (SU-Cloud)
After=docker.service tailscaled.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kolla-ext-gw.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable br-ex-gw.service >/dev/null && sudo systemctl restart br-ex-gw.service
ip -4 addr show br-ex | grep -q "$EXT_GW" || die "br-ex에 $EXT_GW 부여 실패"
ok "br-ex = $EXT_GW, MASQUERADE → $CTRL_IF"
if [[ "$ISOLATE_VMS" == "yes" ]]; then
    # iptables -S 의 1행은 정책(-P), 2행이 체인의 1번 규칙
    FIRST_IN=$(sudo iptables -S INPUT | awk 'NR==2')
    FIRST_FW=$(sudo iptables -S FORWARD | awk 'NR==2')
    [[ "$FIRST_IN" == "-A INPUT -s ${EXT_CIDR} -m conntrack --ctstate NEW -j DROP" ]] \
        || die "INPUT 1번 규칙이 격리 DROP이 아님: ${FIRST_IN:-없음} (sudo iptables -S INPUT)"
    [[ "$FIRST_FW" == "-A FORWARD -s ${EXT_CIDR} -d "*" -j DROP" ]] \
        || die "FORWARD 1번 규칙이 격리 DROP이 아님: ${FIRST_FW:-없음} (sudo iptables -S FORWARD)"
    ok "VM 격리 적용: INPUT NEW DROP, FORWARD DROP → ${CONNECTED_CIDRS[*]} ${ISOLATE_EXTRA_CIDRS}"
else
    warn "ISOLATE_VMS=no — VM이 controller 호스트·관리 대역에 접근 가능 (격리 규칙 제거됨)"
fi

# ---------------------------------------------------------------------------
log "[2/3] OpenStack 기본 리소스 (있으면 건너뜀)"
# ---------------------------------------------------------------------------
openstack network show provider_network >/dev/null 2>&1 || openstack network create --external \
    --provider-network-type flat --provider-physical-network physnet1 provider_network >/dev/null
openstack subnet show provider_subnet >/dev/null 2>&1 || openstack subnet create provider_subnet \
    --network provider_network --no-dhcp --subnet-range "$EXT_CIDR" --gateway "$EXT_GW" \
    --allocation-pool "start=${EXT_POOL_START},end=${EXT_POOL_END}" >/dev/null
openstack network show tenant_network >/dev/null 2>&1 || openstack network create tenant_network >/dev/null
openstack subnet show tenant_subnet >/dev/null 2>&1 || openstack subnet create tenant_subnet \
    --network tenant_network --subnet-range "$TENANT_CIDR" --dns-nameserver "$TENANT_DNS" >/dev/null
if ! openstack router show tenant_router >/dev/null 2>&1; then
    openstack router create tenant_router >/dev/null
    openstack router set tenant_router --external-gateway provider_network \
        --fixed-ip "subnet=provider_subnet,ip-address=${EXT_ROUTER_IP}"
    openstack router add subnet tenant_router tenant_subnet
fi
if ! openstack image show cirros >/dev/null 2>&1; then
    IMG="cirros-${CIRROS_VER}-x86_64-disk.img"
    [[ -f "/tmp/$IMG" ]] || curl -fL --max-time 120 -o "/tmp/$IMG" \
        "https://github.com/cirros-dev/cirros/releases/download/${CIRROS_VER}/${IMG}" \
        || curl -fL --max-time 120 -o "/tmp/$IMG" "https://download.cirros-cloud.net/${CIRROS_VER}/${IMG}" \
        || die "CirrOS 다운로드 실패 (캠퍼스망 github 타임아웃이면 다른 곳에서 받아 /tmp/$IMG 에 두고 재실행)"
    openstack image create cirros --file "/tmp/$IMG" --disk-format qcow2 --container-format bare --public >/dev/null
fi
openstack flavor show m1.tiny >/dev/null 2>&1 || openstack flavor create --vcpus 1 --ram 512 --disk 1 --public m1.tiny >/dev/null
SG_ID=$(openstack security group list --project admin -f value -c ID -c Name | awk '$2=="default"{print $1; exit}')
[[ -n "$SG_ID" ]] || die "admin default 보안그룹 없음"
openstack security group rule list "$SG_ID" -f value -c "IP Protocol" -c "Port Range" -c Direction | grep -q "^icmp .* ingress" \
    || openstack security group rule create --ingress --protocol icmp "$SG_ID" >/dev/null
openstack security group rule list "$SG_ID" -f value -c "IP Protocol" -c "Port Range" -c Direction | grep -q "^tcp 22:22 ingress" \
    || openstack security group rule create --ingress --protocol tcp --dst-port 22 "$SG_ID" >/dev/null
echo; openstack network list -c Name -c Subnets; openstack router list -c Name -c Status; openstack image list -c Name -c Status; openstack flavor list -c Name -c VCPUs -c RAM

# ---------------------------------------------------------------------------
log "[3/3] 완료"
# ---------------------------------------------------------------------------
cat <<MSG

$(echo -e "\033[1;32m")=====================================================
  INIT — Horizon: http://${CTRL_IP}:${HORIZON_PORT}/  (admin / $(grep keystone_admin_password "$KOLLA_DIR/passwords.yml" | awk '{print $2}'))
=====================================================$(echo -e "\033[0m")

스모크 테스트 (인스턴스가 compute 노드에 스케줄되는지):
  openstack keypair create --public-key ~/.ssh/id_ed25519.pub ctrl-key >/dev/null
  openstack server create --image cirros --flavor m1.tiny --network tenant_network --key-name ctrl-key smoke
  openstack server show smoke -c OS-EXT-SRV-ATTR:host -c status         # host = ${COMP_HOSTS[*]} 중 하나, ACTIVE
  FIP=\$(openstack floating ip create provider_network -f value -c floating_ip_address)
  openstack server add floating ip smoke \$FIP
  ping -c3 \$FIP && ssh cirros@\$FIP                                     # 비밀번호 gocubsgo
  ssh cirros@\$FIP 'ping -c3 8.8.8.8'                                     # MASQUERADE 경로
  ssh cirros@\$FIP 'for t in ${CTRL_IP} ${EXT_GW} 8.8.8.8; do ping -c1 -W2 \$t >/dev/null 2>&1 && echo "\$t 열림" || echo "\$t 막힘"; done'   # 격리: 앞 둘 막힘, 8.8.8.8 열림

OVN 확인 (qrouter netns 없음 — 라우터는 OVN 논리 오브젝트):
  docker exec ovn_nb_db ovn-nbctl show
  docker exec ovn_sb_db ovn-sbctl show                                    # chassis = 노드 수, controller가 gateway
  docker exec openvswitch_vswitchd ovs-vsctl show                          # br-ex 포트에 ${EXT_IF}, br-int 에 geneve 터널
MSG
