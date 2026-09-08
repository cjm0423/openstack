#!/usr/bin/env bash
# =============================================================================
# setup.sh — CloudClub 10기 시즌1 오픈스택 스터디 (4회차: READY 확인용)
#
# 근거: SU-Cloud 프로젝트에서 검증한 Kolla-Ansible AIO 절차
#   - 운영계(.179) 구축 기록 2026-08-13  (Ubuntu 24.04 / kolla-ansible 22.0.0 / 2026.1)
#   - 개발계(.180) ML2/OVS 구성 2026-07-07
#   - 공부 노트 Ch4 (가비아 VM · ML2/OVS 이식본)
# 가비아 VM에 맞게 바꾼 것: 브리지(brbond0)·MAC 고정 불필요 → 단일 NIC 그대로 사용,
#   VIP = VM 사설 IP, 중첩 가상화 자동 감지(kvm/qemu 분기), 스왑 보강,
#   kvm_intel 로드용 systemd 유닛(가비아 이미지가 /etc/modprobe.d/kvm.conf 로 블랙리스트 처리하므로 modules-load.d 불가).
#
# 스터디 기준 VM: 가비아 Standard 2vCore / 8GB / 50GB, Ubuntu 24.04 (2026-09-07 확정)
#   - 8GB 환경이므로 스왑 8GB를 자동 생성하고, 스터디 밖 서비스(heat·fluentd 등)는 끈다
#   - 가비아 VM은 중첩 가상화(VT-x)를 노출하므로 nova_compute_virt_type=kvm 으로 감지된다
#   - 실측(2026-09-07): setup.sh 약 3.5분, 완료 직후 사용 메모리 약 550MB
#
# 하는 일 (deploy "직전"까지):
#   [1/8] 환경 점검 (OS·RAM·디스크·NIC·가상화 자동 감지, passwordless sudo)
#   [2/8] 패키지 + chrony + 스왑(16GB 미만일 때 8GB)
#   [3/8] /etc/hosts 치환 + sysctl(ip_forward, rp_filter=2)   ← SU-Cloud 함정 1·2
#   [4/8] veth-setup.service (veth0 미부착 원칙)                 ← SU-Cloud 함정 5
#   [5/8] ~/kolla-venv + kolla-ansible 22.0.0 / ansible-core 2.19.11
#   [6/8] /etc/kolla (인벤토리·passwords.yml 백업·globals.yml 관리 블록)
#   [7/8] install-deps + bootstrap-servers + docker 그룹         ← SU-Cloud 함정 4
#   [8/8] prechecks --use-test-images → "READY ✅"
#
# 실행: ./setup.sh   (ubuntu 유저, 약 10~15분, 재실행 안전)
#
# 이후 (5회차, tmux 안에서):
#   source ~/kolla-venv/bin/activate
#   kolla-ansible pull   -i /etc/kolla/all-in-one
#   kolla-ansible deploy -i /etc/kolla/all-in-one      # ⚠️ --use-test-images 붙이지 말 것 (prechecks 전용 옵션)
# 이후 (6회차): ./init.sh
# =============================================================================
set -euo pipefail
trap 'echo -e "\n\033[1;31m[실패] setup.sh:$LINENO 에서 중단 — 이 화면을 캡처해 단톡방에 공유해주세요\033[0m"' ERR

# ---------- 고정값 (init.sh와 공유 — 바꾸면 init.sh도 같이) ----------
KOLLA_VERSION="22.0.0"
ANSIBLE_CORE_VERSION="2.19.11"
VENV="$HOME/kolla-venv"
KOLLA_DIR="/etc/kolla"
INVENTORY="$KOLLA_DIR/all-in-one"
EXT_IF="veth1"                    # neutron_external_interface (OVS br-ex 편입)
EXT_IF_PEER="veth0"               # 쌍. UP만, 어디에도 미부착

log()  { echo -e "\n\033[1;36m[setup] $*\033[0m"; }
warn() { echo -e "\033[1;33m[주의] $*\033[0m"; }
die()  { echo -e "\033[1;31m[중단] $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "[1/8] 환경 점검"
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "root가 아닌 일반 유저(ubuntu)로 실행하세요"
command -v sudo >/dev/null || die "sudo가 없습니다"

. /etc/os-release
[[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04가 필요합니다 (현재: ${PRETTY_NAME:-unknown}). kolla-ansible 22.x는 22.04를 지원하지 않습니다"

# 8GB VM은 MemTotal이 7.8GB 안팎으로 잡혀 정수 변환 시 7이 된다 → 최소치 7
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
(( MEM_GB >= 7 ))  || die "RAM ${MEM_GB}GB — 최소 8GB 필요. VM 스펙을 확인해주세요"
(( MEM_GB >= 15 )) || echo "  RAM ${MEM_GB}GB — 스터디 기준 사양(8GB). 스왑 8GB로 보완합니다"

DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
(( DISK_GB >= 35 )) || warn "루트 여유 ${DISK_GB}GB — 50GB 이상 권장 (컨테이너 이미지가 수십 GB)"

if ! sudo -n true 2>/dev/null; then
    echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/kolla-nopasswd >/dev/null
    sudo chmod 0440 /etc/sudoers.d/kolla-nopasswd
    sudo visudo -c >/dev/null
fi

# 기본 라우트 NIC = 관리망(network_interface). 가비아 VM은 NIC 1개(eth0).
IFACE=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$IFACE" ]] || die "기본 라우트 인터페이스를 찾지 못했습니다"
HOST_IP=$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || die "$IFACE 의 IPv4 주소를 찾지 못했습니다"

# 중첩 가상화 → kvm / qemu 자동 분기 (egrep -c '(vmx|svm)' /proc/cpuinfo 가 0이면 qemu)
# 가비아 VM은 VT-x를 노출하지만 클라우드 커널이 kvm 모듈을 자동 로드하지 않으므로(/dev/kvm 없음)
# 여기서 로드하고 재부팅 후에도 올라오도록 영속화한다. (Kolla nova-cell 롤도 로드하지만 이중 안전장치)
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
    VIRT_TYPE="kvm"
    KVM_MOD=$(grep -q vmx /proc/cpuinfo && echo kvm_intel || echo kvm_amd)
    # 가비아 이미지는 /etc/modprobe.d/kvm.conf 에서 kvm_intel을 블랙리스트 → modules-load.d로는 부팅 시 로드되지 않는다
    # (2026-09-07 실측: "Module 'kvm_intel' is deny-listed (by kmod)"). 명시적 modprobe는 블랙리스트를 무시하므로
    # systemd 유닛으로 부팅 시 직접 로드한다. 가비아 파일은 건드리지 않는다(이미지 갱신 시 되돌아올 수 있음).
    sudo rm -f /etc/modules-load.d/kvm.conf
    sudo tee /etc/systemd/system/kvm-load.service >/dev/null <<EOF
[Unit]
Description=Load ${KVM_MOD} explicitly (image blacklists it) — study
DefaultDependencies=no
After=systemd-modules-load.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/sbin/modprobe ${KVM_MOD}
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now kvm-load.service >/dev/null
    [[ -e /dev/kvm ]] || warn "/dev/kvm 이 생성되지 않았습니다 — 배포는 진행되지만 인스턴스가 느릴 수 있습니다"
else
    VIRT_TYPE="qemu"
    warn "중첩 가상화 미지원 → QEMU 에뮬레이션 (인스턴스 부팅 1~2분, 학습엔 충분)"
fi

# noVNC 콘솔 URL용 공인 IP (선택). NAT 뒤라면 자동 감지, 실패하면 콘솔 기능만 포기.
PUBLIC_IP="${PUBLIC_IP:-$(curl -4 -s --max-time 5 https://api.ipify.org || true)}"

echo "  관리 NIC      : $IFACE ($HOST_IP)  ← VIP로 사용"
echo "  외부망 NIC    : $EXT_IF (veth 더미, br-ex 편입 예정)"
echo "  가상화        : $VIRT_TYPE / RAM ${MEM_GB}GB / 디스크 여유 ${DISK_GB}GB"
echo "  공인 IP(noVNC): ${PUBLIC_IP:-감지 실패 → 콘솔 탭 미사용}"

# ---------------------------------------------------------------------------
log "[2/8] 패키지 + chrony + 스왑"
# ---------------------------------------------------------------------------
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    chrony curl wget git tmux python3-dev python3-venv libffi-dev gcc \
    libdbus-1-dev libglib2.0-dev pkg-config
sudo timedatectl set-timezone Asia/Seoul || true
sudo systemctl enable --now chrony

# 8GB 기준 사양: deploy 중 순간 피크와 인스턴스 기동 시 OOM Kill 방지용 안전망 (성능보다 생존 우선)
if (( MEM_GB < 15 )) && ! swapon --show --noheadings | grep -q .; then
    sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

# ---------------------------------------------------------------------------
log "[3/8] /etc/hosts 치환 + 커널 파라미터"
# ---------------------------------------------------------------------------
# SU-Cloud 함정 1: 127.0.1.1 <호스트명> 줄이 남아 있으면 RabbitMQ가 루프백에 바인드 → 배포 중반 실패.
# tee -a로 "추가"하면 앞 줄이 먼저 매칭되므로 반드시 "치환".
HN=$(hostname)
if grep -qE "^127\.0\.1\.1[[:space:]]+$HN" /etc/hosts; then
    sudo sed -i "s/^127\.0\.1\.1[[:space:]]\+$HN.*/$HOST_IP $HN/" /etc/hosts
elif ! grep -qE "^$HOST_IP[[:space:]]+$HN" /etc/hosts; then
    echo "$HOST_IP $HN" | sudo tee -a /etc/hosts >/dev/null
fi
# 가비아 이미지의 cloud-init이 재부팅 때 /etc/hosts를 되돌리지 않도록
echo 'manage_etc_hosts: false' | sudo tee /etc/cloud/cloud.cfg.d/99-kolla-hosts.cfg >/dev/null

# SU-Cloud 함정 2: rp_filter strict(1)면 FIP 응답 패킷이 로그 없이 drop. loose(2) 필수.
# ip_forward: kolla가 docker의 ip-forward를 끄므로(docker_disable_ip_forward) 우리가 직접 켠다.
sudo tee /etc/sysctl.d/99-kolla.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
sudo sysctl --system >/dev/null

# ---------------------------------------------------------------------------
log "[4/8] veth-setup.service (외부망 더미 인터페이스, 재부팅 생존)"
# ---------------------------------------------------------------------------
# SU-Cloud 함정 5: veth0을 브리지에 물리지 않는다 (운영계 실제 장애). UP만 유지.
# br-ex의 게이트웨이 IP는 배포 후 OVS가 br-ex를 만든 뒤에야 줄 수 있으므로 init.sh(br-ex-gw.service)가 담당.
sudo tee /etc/systemd/system/veth-setup.service >/dev/null <<EOF
[Unit]
Description=Create veth pair for Neutron external interface (study)
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
EOF
sudo systemctl daemon-reload
sudo systemctl enable veth-setup.service >/dev/null
sudo systemctl restart veth-setup.service
ip link show "$EXT_IF" >/dev/null || die "$EXT_IF 생성 실패"

# ---------------------------------------------------------------------------
log "[5/8] ~/kolla-venv + kolla-ansible ${KOLLA_VERSION}"
# ---------------------------------------------------------------------------
[[ -d "$VENV" ]] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install -q -U pip
pip install -q docker dbus-python \
    "ansible-core==${ANSIBLE_CORE_VERSION}" \
    "kolla-ansible==${KOLLA_VERSION}" \
    python-openstackclient osc-placement      # osc-placement: resource provider 명령용

# ---------------------------------------------------------------------------
log "[6/8] /etc/kolla — 인벤토리 · passwords.yml · globals.yml"
# ---------------------------------------------------------------------------
sudo mkdir -p "$KOLLA_DIR" && sudo chown "$USER:$USER" "$KOLLA_DIR"
cp -rn "$VENV/share/kolla-ansible/etc_examples/kolla/." "$KOLLA_DIR/"      # 기존 파일 보존
[[ -f "$INVENTORY" ]] || cp "$VENV/share/kolla-ansible/ansible/inventory/all-in-one" "$INVENTORY"
if ! grep -q ansible_python_interpreter "$INVENTORY"; then
    sed -i "1i [all:vars]\nansible_python_interpreter=$VENV/bin/python3\n" "$INVENTORY"
fi

# passwords.yml: 비어 있을 때만 생성 + 즉시 백업 (분실 시 복구 불가)
if grep -qE '^keystone_admin_password: *$' "$KOLLA_DIR/passwords.yml"; then
    kolla-genpwd -p "$KOLLA_DIR/passwords.yml"
fi
mkdir -p ~/kolla-backup
cp "$KOLLA_DIR/passwords.yml" ~/kolla-backup/passwords.yml.$(date +%F) && chmod 600 ~/kolla-backup/passwords.yml.*

# globals.yml: 예제 파일은 그대로 두고, 마커 사이 블록만 우리가 관리 (재실행 시 교체)
sed -i '/^# >>> su-study >>>/,/^# <<< su-study <<</d' "$KOLLA_DIR/globals.yml"
# 예제 globals.yml에는 kolla_internal_vip_address가 주석 없이 들어 있어 우리 블록과 키 중복.
# YAML은 마지막 값이 이기지만 혼동 방지를 위해 주석 처리 (블록 삭제 후라 재실행 멱등)
sed -i 's/^kolla_internal_vip_address:/#&/' "$KOLLA_DIR/globals.yml"
cat >> "$KOLLA_DIR/globals.yml" <<EOF
# >>> su-study >>>  (setup.sh가 관리하는 블록 — 직접 고치지 말고 setup.sh를 재실행)
# OpenStack 스터디 시즌1 — AIO / ML2-OVS / 가비아 VM 2vCore·8GB   (SU-Cloud 운영계 설정 이식)

# --- 기본 ---
kolla_base_distro: "ubuntu"
kolla_internal_vip_address: "${HOST_IP}"     # VM 사설 IP. 공인 IP 절대 아님 (VM 밖 NAT 주소라 바인드 불가)
network_interface: "${IFACE}"
neutron_external_interface: "${EXT_IF}"

# --- 단일 노드: LB 계층 제거 (enable_proxysql은 haproxy와 무관하게 기본 ON → 3306 충돌) ---
enable_haproxy: "no"
enable_keepalived: "no"
enable_proxysql: "no"

# --- 네트워크 백엔드: OVS (6·7회차 qrouter netns 실습 전제. kolla 기본값도 openvswitch) ---
neutron_plugin_agent: "openvswitch"

# --- 컴퓨트 (중첩 가상화 자동 감지 결과) ---
nova_compute_virt_type: "${VIRT_TYPE}"
$( [[ -n "$PUBLIC_IP" ]] && echo "nova_novncproxy_fqdn: \"${PUBLIC_IP}\"        # Horizon 콘솔(noVNC) URL을 공인 IP로 (방화벽 6080 필요)" || true )

# --- 스터디 범위 밖: 배포 시간·메모리 절약 (heat·fluentd는 기본 ON이라 명시적으로 끔) ---
enable_cinder: "no"
enable_heat: "no"
enable_fluentd: "no"           # 로그 수집기. 8GB에서 수백 MB 절약. 로그는 docker logs / /var/log/kolla 로 본다
enable_swift: "no"
enable_octavia: "no"
enable_barbican: "no"
enable_designate: "no"
enable_magnum: "no"
enable_prometheus: "no"
enable_grafana: "no"
enable_central_logging: "no"

# openstack_release / docker_registry / docker_namespace 는 넣지 않는다.
# 22.0.0 기본값(2026.1 / quay.io / openstack.kolla)이 정답이며, 임의 지정 시 pull 실패 위험.
# <<< su-study <<<
EOF

# ---------------------------------------------------------------------------
log "[7/8] install-deps + bootstrap-servers (Docker 설치 등, 수 분)"
# ---------------------------------------------------------------------------
kolla-ansible install-deps
kolla-ansible bootstrap-servers -i "$INVENTORY"

# SU-Cloud 함정 4: bootstrap-servers가 docker 그룹 멤버 추가를 누락 → deploy 중 docker.sock permission denied
sudo groupadd -f docker
sudo usermod -aG docker "$USER"
sudo systemctl restart docker

# ---------------------------------------------------------------------------
log "[8/8] prechecks"
# ---------------------------------------------------------------------------
# --use-test-images: "quay.io/openstack.kolla 이미지를 쓰겠다"는 확인 플래그. prechecks에만 존재.
# (kolla-ansible 22.0.0 소스 확인: pull/deploy에 붙이면 unrecognized arguments)
sg docker -c ". '$VENV/bin/activate' && kolla-ansible prechecks -i '$INVENTORY' --use-test-images"

cat <<EOF

$(echo -e "\033[1;32m")=====================================================
  READY ✅  — 이 화면을 캡처해서 단톡방에 인증해주세요!
=====================================================$(echo -e "\033[0m")

다음 단계 (5회차 deploy 데이, 세션에서 다같이):
  exit                          # ← docker 그룹 반영을 위해 SSH 한 번 재접속
  tmux new -s kolla
  source ~/kolla-venv/bin/activate
  kolla-ansible pull   -i /etc/kolla/all-in-one        # 2vCore 기준 20~40분
  kolla-ansible deploy -i /etc/kolla/all-in-one        # 30~60분 — tmux에 걸어두고 해산
                                                       #   ⚠️ --use-test-images 붙이지 않음
  (6회차) kolla-ansible post-deploy -i /etc/kolla/all-in-one && ./init.sh

참고:
  - SSH가 끊겨도 tmux attach -t kolla 로 복귀
  - 재실행 안전: 뭔가 이상하면 ./setup.sh 다시 실행
  - passwords.yml 백업: ~/kolla-backup/
EOF
