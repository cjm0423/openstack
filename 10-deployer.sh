#!/usr/bin/env bash
# =============================================================================
# 10-deployer.sh — controller에서만 실행. 탐색 → deploy "직전"(prechecks)까지.
#
# 하는 일:
#   [1/7] 탐색·점검 → .state 저장 (20/30 이 읽음)
#         controller: 호스트명·관리 NIC/IP·DNS, 보호 IP 가드, DHCP 금지, 포트/docker 충돌, 외부망 대역 충돌
#         compute 각각(SSH): 호스트명·NIC·IP, 같은 L2, NOPASSWD sudo, /dev/kvm
#   [2/7] ~/kolla-venv + kolla-ansible / ansible-core (env.sh 버전)
#   [3/7] /etc/kolla — multinode 인벤토리 생성, passwords.yml 생성·백업     ← 운영계 함정 8
#   [4/7] globals.yml 관리 블록 (# >>> kolla-multinode >>> … # <<< kolla-multinode <<<)
#   [5/7] install-deps + ansible ping (모든 노드)
#   [6/7] bootstrap-servers (모든 노드 docker 설치) + docker 그룹            ← 운영계 함정 4
#   [7/7] prechecks --use-test-images → "READY"
#
# 실행: ./10-deployer.sh --discover <compute IP> [<compute IP> ...]   [1/7]만 하고 탐색 결과 출력 후 종료
#       ./10-deployer.sh <compute IP> [<compute IP> ...]              전체 (재실행 안전, 약 10~15분)
# 이후: ./20-deploy.sh
# =============================================================================
set -euo pipefail
SCRIPT_TAG="deployer"
source "$(dirname "$0")/lib/common.sh"
trap 'echo -e "\n\033[1;31m[실패] 10-deployer.sh:$LINENO 에서 중단\033[0m"' ERR

DISCOVER_ONLY="no"; COMP_IPS=()
for a in "$@"; do
    case "$a" in
        --discover) DISCOVER_ONLY="yes" ;;
        -*) die "알 수 없는 옵션: $a" ;;
        *)  [[ "$a" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "IPv4 형식이 아닙니다: $a"
            [[ " ${COMP_IPS[*]} " == *" $a "* ]] && die "compute IP 중복: $a"
            COMP_IPS+=("$a") ;;
    esac
done
(( ${#COMP_IPS[@]} > 0 )) || die "사용법: ./10-deployer.sh [--discover] <compute IP> [<compute IP> ...]"

# ---------------------------------------------------------------------------
log "[1/7] 탐색 · 점검"
# ---------------------------------------------------------------------------
require_nonroot; ensure_nopasswd_sudo
ip link show "$EXT_IF" >/dev/null 2>&1 || die "$EXT_IF 가 없습니다 — 이 머신에서 00-node-prep.sh --role controller 먼저"

# --- controller: 이전 .state 가 아니라 env.sh 와 실제 시스템에서 다시 읽는다 ---
CTRL_HOST="$(env_get CTRL_HOST)"
if [[ -n "$CTRL_HOST" ]]; then
    [[ "$(hostname)" == "$CTRL_HOST" ]] || die "hostname이 $CTRL_HOST 가 아닙니다 — 00-node-prep.sh --role controller 먼저"
else
    CTRL_HOST="$(hostname)"
fi
CTRL_IF="$(env_get CTRL_IF)"; CTRL_IF="${CTRL_IF:-$(detect_iface)}"
[[ -n "$CTRL_IF" ]] || die "controller 관리 NIC를 찾지 못했습니다 (env.sh CTRL_IF 지정)"
CTRL_IP=$(iface_ip "$CTRL_IF")
[[ -n "$CTRL_IP" ]] || die "$CTRL_IF 에 IPv4가 없습니다"
guard_ip "$CTRL_IP"
require_static "$CTRL_IF"
TENANT_DNS="$(env_get TENANT_DNS)"; TENANT_DNS_SRC="env.sh"
if [[ -z "$TENANT_DNS" ]]; then
    TENANT_DNS="$(detect_dns "$CTRL_IF")"; TENANT_DNS_SRC="$CTRL_IF 의 DNS"
    [[ -n "$TENANT_DNS" ]] || { TENANT_DNS="8.8.8.8"; TENANT_DNS_SRC="감지 실패 → 기본값"; }
fi
ok "controller $CTRL_HOST = $CTRL_IP on $CTRL_IF, DNS $TENANT_DNS ($TENANT_DNS_SRC)"

# horizon precheck 이 포트 점유로 실패하는 것을 미리 막는다 (배포 후 재실행이면 horizon 자신이 잡고 있으니 통과)
if ss -ltnH "( sport = :$HORIZON_PORT )" | grep -q . \
   && ! sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx horizon; then
    die "controller에서 :$HORIZON_PORT 사용 중 ($(sudo ss -ltnpH "( sport = :$HORIZON_PORT )" | awk '{print $NF}' | head -1)) — 서비스 중지하거나 env.sh HORIZON_PORT 변경"
fi
# Ubuntu docker.io / containerd 는 bootstrap-servers 가 까는 docker-ce(containerd.io)와 충돌
CONFLICT_PKGS=$(dpkg -l | awk '$1 ~ /^[hi]i$/ {print $2}' | sed 's/:.*//' | grep -xE 'docker\.io|containerd' | paste -sd' ' || true)
[[ -z "$CONFLICT_PKGS" ]] || die "controller에 $CONFLICT_PKGS 설치됨 — docker-ce와 충돌. sudo apt-get purge $CONFLICT_PKGS 후 재실행"

# --- 가상 대역: 값끼리 맞는지 + controller 라우팅 테이블과 겹치는지 (br-ex 자신의 라우트는 제외) ---
EXT_ERR=$(ext_values_check)
[[ -z "$EXT_ERR" ]] || die "env.sh 외부망 값 오류: $EXT_ERR"
HOST_ROUTES=$(ip -4 route show | grep -vE ' dev br-ex( |$)' || true)
C=$(cidr_conflicts "$EXT_CIDR" <<<"$HOST_ROUTES")
[[ -z "$C" ]] || die "EXT_CIDR $EXT_CIDR 가 호스트 라우트와 겹침: $C — env.sh EXT_* 를 다른 사설 대역으로"
C=$(cidr_conflicts "$TENANT_CIDR" <<<"$HOST_ROUTES")
[[ -z "$C" ]] || warn "TENANT_CIDR $TENANT_CIDR 가 호스트 라우트와 겹침: $C — 인스턴스가 그 대역에 못 닿음 (env.sh TENANT_CIDR 변경 권장)"
C=$(cidr_conflicts "$TENANT_CIDR" <<<"$EXT_CIDR")
[[ -z "$C" ]] || die "TENANT_CIDR 와 EXT_CIDR 가 겹침"
ok "외부망 $EXT_CIDR (gw $EXT_GW, FIP $EXT_POOL_START~$EXT_POOL_END), 테넌트망 $TENANT_CIDR"

# --- compute 각각 ---
[[ -f ~/.ssh/id_ed25519.pub ]] || die "SSH 키(id_ed25519) 없음 — 00-node-prep.sh --role controller 먼저"
COMP_ENV_IF="$(env_get COMP_IF)"
COMP_HOSTS=(); COMP_IFS=()
for ip in "${COMP_IPS[@]}"; do
    guard_ip "$ip"
    [[ "$ip" != "$CTRL_IP" ]] || die "compute IP($ip)가 controller IP와 같습니다"
    ip route get "$ip" | grep -q ' via ' && die "$ip 는 게이트웨이 경유 — controller($CTRL_IP/$CTRL_IF)와 같은 L2가 아닙니다"

    # SSH: 키 없으면 한 번만 비밀번호로 복사
    ssh-keygen -F "$ip" >/dev/null 2>&1 || ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>/dev/null
    if ! ssh_node "$ip" true 2>/dev/null; then
        warn "$ip 에 키 접속 불가 → ssh-copy-id (비밀번호 1회)"
        ssh-copy-id -i ~/.ssh/id_ed25519.pub "$NODE_USER@$ip"
    fi
    ssh_node "$ip" 'sudo -n true' || die "$ip 에서 NOPASSWD sudo 실패 — 그 노드에서 00-node-prep.sh --role compute 먼저"

    hn=$(ssh_node "$ip" hostname)
    valid_hostname "$hn" || die "$ip 의 hostname '$hn' 사용 불가 — 그 노드에서 00-node-prep.sh --role compute --hostname 이름"
    [[ "$hn" != "$CTRL_HOST" ]] || die "$ip 의 hostname이 controller와 같음($hn) — 그 노드에서 --hostname 으로 바꾸기"
    [[ " ${COMP_HOSTS[*]} " != *" $hn "* ]] || die "compute hostname 중복: $hn"

    ifc="${COMP_ENV_IF:-$(ssh_node "$ip" "ip -4 route show default | awk '{print \$5; exit}'")}"
    [[ -n "$ifc" ]] || die "$ip 의 관리 NIC를 찾지 못했습니다 (env.sh COMP_IF 지정)"
    addr=$(ssh_node "$ip" "ip -4 -o addr show dev $ifc scope global")
    [[ "$(awk '{print $4}' <<<"$addr" | cut -d/ -f1 | head -1)" == "$ip" ]] || die "$hn 의 $ifc IP가 인자($ip)와 다름 — 관리 NIC/IP 확인"
    grep -qw dynamic <<<"$addr" && die "$hn($ip) 의 IP가 DHCP(dynamic) — 설치 시 고정 IP로"

    # virt_type 은 인스턴스가 실제로 뜨는 compute 기준. qemu 로 조용히 떨어지는 대신 중단.
    ssh_node "$ip" 'test -e /dev/kvm' || die "$hn($ip)에 /dev/kvm 없음 — BIOS에서 VT-x/AMD-V 켜기"

    COMP_HOSTS+=("$hn"); COMP_IFS+=("$ifc")
    ok "compute $hn = $ip on $ifc (SSH/sudo/kvm OK)"
done
if [[ "$CTRL_IS_COMPUTE" == "yes" ]]; then
    [[ -e /dev/kvm ]] || die "CTRL_IS_COMPUTE=yes 인데 controller에 /dev/kvm 없음 — BIOS에서 VT-x/AMD-V 켜기"
fi
VIRT_TYPE="kvm"

{
    echo "# 10-deployer.sh 가 $(date '+%F %T') 에 탐색·확정한 값 — 손대지 말고 env.sh 수정 후 10-deployer.sh 재실행"
    echo "CTRL_HOST=\"$CTRL_HOST\""
    echo "CTRL_IP=\"$CTRL_IP\""
    echo "CTRL_IF=\"$CTRL_IF\""
    echo "COMP_HOSTS=(${COMP_HOSTS[*]})"
    echo "COMP_IPS=(${COMP_IPS[*]})"
    echo "COMP_IFS=(${COMP_IFS[*]})"
    echo "VIRT_TYPE=\"$VIRT_TYPE\""
    echo "TENANT_DNS=\"$TENANT_DNS\""
} > "$STATE_FILE"

echo
echo "  ---- 탐색 결과 ($STATE_FILE) ----"
printf '  %-10s %-18s %-16s %s\n' 역할 hostname IP NIC
printf '  %-10s %-18s %-16s %s\n' controller "$CTRL_HOST" "$CTRL_IP" "$CTRL_IF"
for i in "${!COMP_IPS[@]}"; do
    printf '  %-10s %-18s %-16s %s\n' compute "${COMP_HOSTS[$i]}" "${COMP_IPS[$i]}" "${COMP_IFS[$i]}"
done
echo "  user=$NODE_USER  virt_type=$VIRT_TYPE  tenant DNS=$TENANT_DNS  controller도 compute=$CTRL_IS_COMPUTE"
if [[ "$DISCOVER_ONLY" == "yes" ]]; then
    echo; ok "--discover: 여기까지. 값이 맞으면 --discover 빼고 같은 인자로 재실행"
    exit 0
fi

# ---------------------------------------------------------------------------
log "[2/7] ~/kolla-venv + kolla-ansible ${KOLLA_VERSION}"
# ---------------------------------------------------------------------------
[[ -d "$VENV" ]] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install -q -U pip
# docker/dbus-python: controller는 ansible_python_interpreter=venv 라 시스템의 python3-docker(bootstrap이 apt로 설치)를 못 봄 → venv에 직접
pip install -q docker dbus-python \
    "ansible-core==${ANSIBLE_CORE_VERSION}" \
    "kolla-ansible==${KOLLA_VERSION}" \
    python-openstackclient osc-placement

# ---------------------------------------------------------------------------
log "[3/7] /etc/kolla — 인벤토리 · passwords.yml"
# ---------------------------------------------------------------------------
sudo mkdir -p "$KOLLA_DIR" && sudo chown "$USER:$USER" "$KOLLA_DIR"
cp -rn "$VENV/share/kolla-ansible/etc_examples/kolla/." "$KOLLA_DIR/"

# 인벤토리: 앞부분(호스트 그룹)만 생성하고, [baremetal:children] 이후는 kolla 예제 그대로 붙인다.
# 노드별 NIC 는 호스트 변수 (NIC 이름이 노드마다 다를 수 있음)
# controller: ansible_connection=local + venv python. compute: SSH, 시스템 python (bootstrap이 python3-docker apt 설치)
{
cat <<INV
# 10-deployer.sh 생성 — 손대지 말고 env.sh 수정 후 재실행
[control]
${CTRL_HOST} ansible_host=${CTRL_IP} ansible_connection=local ansible_python_interpreter=${VENV}/bin/python3 network_interface=${CTRL_IF}

[network]
${CTRL_HOST}

[compute]
$(for i in "${!COMP_IPS[@]}"; do echo "${COMP_HOSTS[$i]} ansible_host=${COMP_IPS[$i]} ansible_user=${NODE_USER} network_interface=${COMP_IFS[$i]}"; done)
$( [[ "$CTRL_IS_COMPUTE" == "yes" ]] && echo "${CTRL_HOST}" || true )

[monitoring]
${CTRL_HOST}

[storage]
${CTRL_HOST}

[deployment]
localhost ansible_connection=local

INV
sed -n '/^\[baremetal:children\]/,$p' "$VENV/share/kolla-ansible/ansible/inventory/multinode"
} > "$INVENTORY"

if grep -qE '^keystone_admin_password: *$' "$KOLLA_DIR/passwords.yml"; then
    kolla-genpwd -p "$KOLLA_DIR/passwords.yml"
fi
mkdir -p ~/kolla-backup && chmod 700 ~/kolla-backup
cp "$KOLLA_DIR/passwords.yml" "$HOME/kolla-backup/passwords.yml.$(date +%F)" && chmod 600 ~/kolla-backup/passwords.yml.*
ok "인벤토리 $INVENTORY, passwords 백업 ~/kolla-backup/"

# ---------------------------------------------------------------------------
log "[4/7] globals.yml 관리 블록"
# ---------------------------------------------------------------------------
# 이전 이름(su-cloud) 블록도 같이 지운다
sed -i -e '/^# >>> su-cloud >>>/,/^# <<< su-cloud <<</d' -e '/^# >>> kolla-multinode >>>/,/^# <<< kolla-multinode <<</d' "$KOLLA_DIR/globals.yml"
cat >> "$KOLLA_DIR/globals.yml" <<GL
# >>> kolla-multinode >>>  (10-deployer.sh 가 관리하는 블록 — 직접 고치지 말고 env.sh 수정 후 재실행)
# controller(${CTRL_HOST}) + compute(${COMP_HOSTS[*]}) / ${NEUTRON_PLUGIN} / 관리망 = 터널망

# --- 기본 ---
kolla_base_distro: "ubuntu"
kolla_internal_vip_address: "${CTRL_IP}"    # haproxy 없음 → VIP = controller 관리 IP. compute는 이 주소로 API 접근
# 노드별 인터페이스는 인벤토리 호스트 변수로 — globals.yml은 extra vars라 여기 두면 호스트 변수를 덮어씀
neutron_external_interface: "${EXT_IF}"     # network 그룹(controller)에서만 br-ex에 편입됨 (kolla openvswitch/post-config.yml 조건)
$( [[ -n "${EXTERNAL_FQDN:-}" ]] && echo "kolla_external_fqdn: \"${EXTERNAL_FQDN}\"    # public 엔드포인트/Horizon 이름 (haproxy 없이 미검증)" || true )

# --- 컨트롤러 1대: LB 계층 제거 (enable_proxysql 은 기본 ON → 3306 충돌, 운영계 keepalived 우회도 불필요) ---
enable_haproxy: "no"
enable_keepalived: "no"
enable_proxysql: "no"

# --- 네트워크 백엔드 ---
neutron_plugin_agent: "${NEUTRON_PLUGIN}"
# OVN: 게이트웨이 섀시 = [network] 그룹 = controller. compute는 neutron_ovn_distributed_fip(기본 false)라 br-ex 불필요.

# --- 컴퓨트 ---
nova_compute_virt_type: "${VIRT_TYPE}"
horizon_port: "${HORIZON_PORT}"

# --- 범위 밖: 배포 시간·메모리 절약 ---
enable_cinder: "no"
enable_heat: "no"
enable_swift: "no"
enable_octavia: "no"
enable_barbican: "no"
enable_designate: "no"
enable_magnum: "no"
enable_prometheus: "no"
enable_grafana: "no"
enable_central_logging: "no"

# openstack_release / docker_registry / docker_namespace 는 넣지 않는다 (22.0.0 기본값이 정답, 임의 지정 시 pull 실패).
# <<< kolla-multinode <<<
GL
ok "globals.yml 갱신"

# ---------------------------------------------------------------------------
log "[5/7] install-deps + 모든 노드 ansible ping"
# ---------------------------------------------------------------------------
kolla-ansible install-deps
ansible -i "$INVENTORY" baremetal -m ping -o || die "ansible ping 실패 — 위 출력에서 어느 노드인지 확인"

# ---------------------------------------------------------------------------
log "[6/7] bootstrap-servers (모든 노드 docker 설치, 수 분)"
# ---------------------------------------------------------------------------
kolla-ansible bootstrap-servers -i "$INVENTORY"
# 운영계 함정 4: bootstrap이 배포 유저의 docker 그룹 추가를 누락 → deploy 중 docker.sock permission denied
sudo groupadd -f docker && sudo usermod -aG docker "$USER" && sudo systemctl restart docker
for ip in "${COMP_IPS[@]}"; do
    # shellcheck disable=SC2016  # $USER 는 원격에서 확장
    ssh_node "$ip" 'sudo groupadd -f docker && sudo usermod -aG docker $USER && sudo systemctl restart docker'
done
ok "docker 그룹: $USER@controller + compute ${#COMP_IPS[@]}대"

# ---------------------------------------------------------------------------
log "[7/7] prechecks"
# ---------------------------------------------------------------------------
# --use-test-images 는 prechecks 전용 (22.0.0 소스: Prechecks.get_parser 에만 존재). pull/deploy에 붙이면 에러.
sg docker -c ". '$VENV/bin/activate' && kolla-ansible prechecks -i '$INVENTORY' --use-test-images"

cat <<MSG

$(echo -e "\033[1;32m")=====================================================
  READY — 모든 노드 prechecks 통과
=====================================================$(echo -e "\033[0m")
  exit                # docker 그룹 반영 (SSH 재접속)
  tmux new -s kolla
  ./20-deploy.sh      # pull → deploy → post-deploy → 검증
MSG
