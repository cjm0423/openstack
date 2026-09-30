#!/usr/bin/env bash
# =============================================================================
# 20-deploy.sh — controller에서, tmux 안에서 실행. pull → deploy → post-deploy → 검증
#
#   [1/4] pull      (모든 노드, 10~20분)
#   [2/4] deploy    (30~60분)         ⚠️ --use-test-images 없음 (prechecks 전용)
#   [3/4] post-deploy → /etc/kolla/admin-openrc.sh
#   [4/4] 검증: 모든 노드 컨테이너, compute service, OVN 에이전트
#
# 실행: tmux new -s kolla && ./20-deploy.sh     (재실행 = 재배포, 안전)
# 이후: ./30-init.sh
# =============================================================================
set -euo pipefail
SCRIPT_TAG="deploy"
source "$(dirname "$0")/lib/common.sh"
trap 'echo -e "\n\033[1;31m[실패] 20-deploy.sh:$LINENO 에서 중단 — /var/log/kolla/ 와 위 ansible 출력 확인\033[0m"' ERR

require_nonroot
require_state   # CTRL_HOST/IP/IF, COMP_HOSTS/IPS/IFS, VIRT_TYPE, TENANT_DNS ← .state (10-deployer.sh)
[[ "$(hostname)" == "$CTRL_HOST" ]] || die "controller($CTRL_HOST)에서 실행하세요"
[[ -f "$INVENTORY" ]] || die "$INVENTORY 없음 — 10-deployer.sh 먼저"
id -nG | grep -qw docker || die "docker 그룹 미반영 — SSH 재접속 후 다시"
[[ -n "${TMUX:-}" ]] || warn "tmux 밖입니다. SSH가 끊기면 deploy가 중단됩니다 (tmux new -s kolla 권장)"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

log "[1/4] pull";   kolla-ansible pull   -i "$INVENTORY"
log "[2/4] deploy"; kolla-ansible deploy -i "$INVENTORY"
log "[3/4] post-deploy"; kolla-ansible post-deploy -i "$INVENTORY"

# ---------------------------------------------------------------------------
log "[4/4] 검증"
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$KOLLA_DIR/admin-openrc.sh"
echo "-- controller 컨테이너"
docker ps --format '{{.Names}}' | grep -E 'ovn_northd|ovn_nb_db|ovn_sb_db|ovn_controller|openvswitch_vswitchd|neutron_server|nova_api|keystone|horizon' | sort | tr '\n' ' '; echo
docker ps --format '{{.Names}}' | grep -qE '^(haproxy|proxysql)$' && die "haproxy/proxysql 가 떠 있음 — globals 확인" || ok "haproxy/proxysql 없음"
for i in "${!COMP_IPS[@]}"; do
    h="${COMP_HOSTS[$i]}"; names=$(ssh_node "${COMP_IPS[$i]}" "sudo docker ps --format '{{.Names}}'")
    echo "-- compute $h 컨테이너"
    grep -E 'nova_compute|nova_libvirt|ovn_controller|openvswitch_vswitchd|neutron_ovn_metadata_agent' <<<"$names" | sort | tr '\n' ' '; echo
    grep -q '^nova_compute$' <<<"$names" || die "$h 에 nova_compute 컨테이너 없음"
done

echo "-- compute service (compute ${#COMP_HOSTS[@]}대$( [[ "$CTRL_IS_COMPUTE" == "yes" ]] && echo " + controller" ) 모두 up이어야 함)"
openstack compute service list --service nova-compute -c Host -c Status -c State
SVC_HOSTS=$(openstack compute service list --service nova-compute -f value -c Host)
for h in "${COMP_HOSTS[@]}"; do
    grep -qx "$h" <<<"$SVC_HOSTS" || die "nova-compute@$h 가 등록되지 않음"
done
echo "-- network agent (OVN Controller agent × 노드 수, OVN Metadata agent × compute 수)"
openstack network agent list -c "Agent Type" -c Host -c Alive -c State
echo "-- hypervisor"
openstack hypervisor list -c "Hypervisor Hostname" -c State

cat <<MSG

$(echo -e "\033[1;32m")=====================================================
  DEPLOYED — 다음: ./30-init.sh  (br-ex 게이트웨이 + 기본 리소스)
=====================================================$(echo -e "\033[0m")
MSG
