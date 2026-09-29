#!/usr/bin/env bash
# =============================================================================
# 10-deployer.sh — controller에서만 실행. deploy "직전"(prechecks)까지.
#
# 하는 일:
#   [1/7] 점검 (controller 판정·IP 감지, 운영계 IP 가드, L2 확인, 포트/docker 충돌, compute SSH + sudo + /dev/kvm)
#         → 확정한 CTRL_IP/CTRL_IF/COMP_IP/COMP_IF 를 .state 에 저장 (20/30 이 읽음)
#   [2/7] ~/kolla-venv + kolla-ansible 22.0.0 / ansible-core 2.19.11
#   [3/7] /etc/kolla — multinode 인벤토리 생성, passwords.yml 생성·백업     ← 운영계 함정 8
#   [4/7] globals.yml 관리 블록 (# >>> su-cloud >>> … # <<< su-cloud <<<)
#   [5/7] install-deps + ansible ping (두 노드)
#   [6/7] bootstrap-servers (두 노드에 docker 설치) + docker 그룹            ← 운영계 함정 4
#   [7/7] prechecks --use-test-images → "READY"
#
# 실행: ./10-deployer.sh <compute IP>   (예: ./10-deployer.sh 210.94.240.182, 재실행 안전, 약 10~15분)
# 이후: ./20-deploy.sh
# =============================================================================
set -euo pipefail
SCRIPT_TAG="deployer"
source "$(dirname "$0")/lib/common.sh"
trap 'echo -e "\n\033[1;31m[실패] 10-deployer.sh:$LINENO 에서 중단\033[0m"' ERR

[[ $# -eq 1 && -n "$1" ]] || die "사용법: ./10-deployer.sh <compute IP>   (예: ./10-deployer.sh 210.94.240.182)"
COMP_IP="$1"

# ---------------------------------------------------------------------------
log "[1/7] 점검"
# ---------------------------------------------------------------------------
require_nonroot; ensure_nopasswd_sudo
[[ "$(hostname)" == "$CTRL_HOST" ]] || die "hostname이 $CTRL_HOST 가 아닙니다 — controller에서 00-node-prep.sh --role controller 먼저"
ip link show "$EXT_IF" >/dev/null 2>&1 || die "$EXT_IF 가 없습니다 — 00-node-prep.sh --role controller 먼저"

# controller IP/NIC: env.sh CTRL_IF(지정 시) 아니면 기본 라우트 NIC. (이전 .state 값이 아니라 env.sh 기준으로 다시 감지)
# shellcheck disable=SC1090
CTRL_IF=$(. "$ENV_FILE"; echo "${CTRL_IF:-}")
CTRL_IF="${CTRL_IF:-$(detect_iface)}"
[[ -n "$CTRL_IF" ]] || die "controller 관리 NIC를 찾지 못했습니다 (env.sh CTRL_IF 지정)"
CTRL_IP=$(iface_ip "$CTRL_IF")
[[ -n "$CTRL_IP" ]] || die "$CTRL_IF 에 IPv4가 없습니다"
guard_ip "$CTRL_IP"
guard_ip "$COMP_IP"
require_static "$CTRL_IF"
[[ "$CTRL_IP" != "$COMP_IP" ]] || die "compute IP($COMP_IP)가 controller IP와 같습니다"
ip route get "$COMP_IP" | grep -q ' via ' && die "$COMP_IP 는 게이트웨이 경유 — controller($CTRL_IP/$CTRL_IF)와 같은 L2가 아닙니다"
ok "controller $CTRL_HOST = $CTRL_IP on $CTRL_IF"

# horizon precheck 이 포트 점유로 실패하는 것을 미리 막는다 (배포 후 재실행이면 horizon 자신이 잡고 있으니 통과)
if ss -ltnH "( sport = :$HORIZON_PORT )" | grep -q . \
   && ! sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx horizon; then
    die "controller에서 :$HORIZON_PORT 사용 중 ($(sudo ss -ltnpH "( sport = :$HORIZON_PORT )" | awk '{print $NF}' | head -1)) — 서비스 중지하거나 env.sh HORIZON_PORT 변경"
fi
# Ubuntu docker.io / containerd 는 bootstrap-servers 가 까는 docker-ce(containerd.io)와 충돌
CONFLICT_PKGS=$(dpkg -l | awk '$1 ~ /^[hi]i$/ {print $2}' | sed 's/:.*//' | grep -xE 'docker\.io|containerd' | paste -sd' ' || true)
[[ -z "$CONFLICT_PKGS" ]] || die "controller에 $CONFLICT_PKGS 설치됨 — docker-ce와 충돌. sudo apt-get purge $CONFLICT_PKGS 후 재실행"

# compute SSH: 키 없으면 한 번만 비밀번호로 복사
ssh-keygen -F "$COMP_IP" >/dev/null 2>&1 || ssh-keyscan -H "$COMP_IP" >> ~/.ssh/known_hosts 2>/dev/null
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$NODE_USER@$COMP_IP" true 2>/dev/null; then
    warn "compute에 키 접속 불가 → ssh-copy-id (비밀번호 1회)"
    ssh-copy-id -i ~/.ssh/id_ed25519.pub "$NODE_USER@$COMP_IP"
fi
ssh -o BatchMode=yes "$NODE_USER@$COMP_IP" 'sudo -n true' || die "compute에서 NOPASSWD sudo 실패 — compute에서 00-node-prep.sh --role compute 실행했는지 확인"
COMP_HN=$(ssh -o BatchMode=yes "$NODE_USER@$COMP_IP" hostname)
[[ "$COMP_HN" == "$COMP_HOST" ]] || die "compute hostname=$COMP_HN (기대: $COMP_HOST) — compute에서 00-node-prep.sh --role compute 먼저"
# shellcheck disable=SC1090
COMP_IF=$(. "$ENV_FILE"; echo "${COMP_IF:-}")
COMP_IF="${COMP_IF:-$(ssh -o BatchMode=yes "$NODE_USER@$COMP_IP" "ip -4 route show default | awk '{print \$5; exit}'")}"
[[ -n "$COMP_IF" ]] || die "compute 관리 NIC를 찾지 못했습니다 (env.sh COMP_IF 지정)"
COMP_IF_IP=$(ssh -o BatchMode=yes "$NODE_USER@$COMP_IP" "ip -4 -o addr show dev $COMP_IF scope global | awk '{print \$4}' | cut -d/ -f1 | head -1")
[[ "$COMP_IF_IP" == "$COMP_IP" ]] || die "compute $COMP_IF 의 IP가 ${COMP_IF_IP:-없음} (인자: $COMP_IP) — 관리 NIC/IP 확인"
ok "compute $COMP_HOST($COMP_IP) SSH/sudo OK, NIC=$COMP_IF"

# virt_type 은 인스턴스가 실제로 뜨는 compute 기준. qemu 로 떨어지면 느린 것보다 모르고 지나가는 게 문제라 중단.
ssh -o BatchMode=yes "$NODE_USER@$COMP_IP" 'test -e /dev/kvm' || die "compute($COMP_HOST)에 /dev/kvm 없음 — P520 BIOS에서 VT-x 켜기"
if [[ "$CTRL_IS_COMPUTE" == "yes" ]]; then
    [[ -e /dev/kvm ]] || die "CTRL_IS_COMPUTE=yes 인데 controller에 /dev/kvm 없음 — BIOS에서 VT-x 켜기"
fi
VIRT_TYPE="kvm"
ok "/dev/kvm OK → nova_compute_virt_type=$VIRT_TYPE"

cat > "$REPO_DIR/.state" <<ST
# 10-deployer.sh 가 $(date '+%F %T') 에 확정한 값 — 손대지 말고 10-deployer.sh 재실행
CTRL_IP="$CTRL_IP"
CTRL_IF="$CTRL_IF"
COMP_IP="$COMP_IP"
COMP_IF="$COMP_IF"
ST
ok ".state 저장: CTRL=$CTRL_IP/$CTRL_IF COMP=$COMP_IP/$COMP_IF"

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
# controller: ansible_connection=local + venv python. compute: SSH, 시스템 python (bootstrap이 python3-docker apt 설치)
{
cat <<INV
# 10-deployer.sh 생성 — 손대지 말고 env.sh 수정 후 재실행
[control]
${CTRL_HOST} ansible_host=${CTRL_IP} ansible_connection=local ansible_python_interpreter=${VENV}/bin/python3

[network]
${CTRL_HOST}

[compute]
${COMP_HOST} ansible_host=${COMP_IP} ansible_user=${NODE_USER} network_interface=${COMP_IF}
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
sed -i '/^# >>> su-cloud >>>/,/^# <<< su-cloud <<</d' "$KOLLA_DIR/globals.yml"
cat >> "$KOLLA_DIR/globals.yml" <<GL
# >>> su-cloud >>>  (10-deployer.sh 가 관리하는 블록 — 직접 고치지 말고 env.sh 수정 후 재실행)
# SU-Cloud 개발계 — controller(${CTRL_HOST}) + compute(${COMP_HOST}) / ${NEUTRON_PLUGIN} / 캠퍼스망 관리·터널

# --- 기본 ---
kolla_base_distro: "ubuntu"
kolla_internal_vip_address: "${CTRL_IP}"    # haproxy 없음 → VIP = controller 관리 IP. compute는 이 주소로 API 접근
network_interface: "${CTRL_IF}"             # compute는 인벤토리 호스트 변수로 override (${COMP_IF})
neutron_external_interface: "${EXT_IF}"     # network 그룹(controller)에서만 br-ex에 편입됨 (kolla openvswitch/post-config.yml 조건)
$( [[ -n "${EXTERNAL_FQDN:-}" ]] && echo "kolla_external_fqdn: \"${EXTERNAL_FQDN}\"    # public 엔드포인트/Horizon 이름 (SU-Cloud 미검증)" || true )

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
# <<< su-cloud <<<
GL
ok "globals.yml 갱신"

# ---------------------------------------------------------------------------
log "[5/7] install-deps + 두 노드 ansible ping"
# ---------------------------------------------------------------------------
kolla-ansible install-deps
ansible -i "$INVENTORY" baremetal -m ping -o || die "ansible ping 실패 — 위 출력에서 어느 노드인지 확인"

# ---------------------------------------------------------------------------
log "[6/7] bootstrap-servers (두 노드 docker 설치, 수 분)"
# ---------------------------------------------------------------------------
kolla-ansible bootstrap-servers -i "$INVENTORY"
# 운영계 함정 4: bootstrap이 배포 유저의 docker 그룹 추가를 누락 → deploy 중 docker.sock permission denied
sudo groupadd -f docker && sudo usermod -aG docker "$USER" && sudo systemctl restart docker
ssh -o BatchMode=yes "$NODE_USER@$COMP_IP" 'sudo groupadd -f docker && sudo usermod -aG docker $USER && sudo systemctl restart docker'
ok "docker 그룹: $USER@both"

# ---------------------------------------------------------------------------
log "[7/7] prechecks"
# ---------------------------------------------------------------------------
# --use-test-images 는 prechecks 전용 (22.0.0 소스: Prechecks.get_parser 에만 존재). pull/deploy에 붙이면 에러.
sg docker -c ". '$VENV/bin/activate' && kolla-ansible prechecks -i '$INVENTORY' --use-test-images"

cat <<MSG

$(echo -e "\033[1;32m")=====================================================
  READY — 두 노드 prechecks 통과
=====================================================$(echo -e "\033[0m")
  exit                # docker 그룹 반영 (SSH 재접속)
  tmux new -s kolla
  ./20-deploy.sh      # pull → deploy → post-deploy → 검증
MSG
