# SU-Cloud 개발계 — Kolla-Ansible 멀티노드 (controller + compute)

기존 개발계(ThinkCentre, `.180`, AIO)를 밀고 **controller**로, 목요일에 들어오는 새 P520(`.182`)을 **compute**로 쓰는 2노드 구성.
근거는 전부 SU-Cloud 운영계(`.179`, AIO/OVN) 구축 기록이고, 스터디용 `setup.sh`/`init.sh`(가비아 AIO)에서 검증된 함정 처리를 그대로 가져왔다.
스터디 스크립트는 `openstack-study` 리포에 따로 있다. 이 리포는 학교 환경 전용.

```
                캠퍼스 LAN 210.94.240.0/24  (gw .254)
  ─────────────┬──────────────────────────────┬─────────────
               │ .180                         │ .182
   ┌───────────┴───────────┐        ┌─────────┴─────────┐
   │ su-cloud-ctrl         │ geneve │ su-cloud-cmp1     │
   │ ThinkCentre (NIC 1개)  │◄──────►│ P520 (X550-T2 ×2, │
   │ control · network     │        │  포트 1개만 사용)   │
   │ · monitoring · storage│        │ compute           │
   │ ovn-northd/nb/sb      │        │ nova-compute      │
   │ ovn-controller (gw)   │        │ ovn-controller    │
   │ br-ex ← veth1         │        │ (br-ex 없음)       │
   │   192.168.200.1 NAT   │        │                   │
   └───────────────────────┘        └───────────────────┘
   VIP = .180 (haproxy 없음)    관리망 = 터널망 = 캠퍼스 LAN
```

## 실행 순서

```bash
# 0. (기존 개발계에서, 밀기 전에 한 번)  ./backup-dev.sh  → tar를 운영계/로컬로 옮김
# 1. 두 노드 Ubuntu 24.04 server 설치, 유저 ubuntu, 설치 화면에서 고정 IP (.180 / .182) — 아래 "설치 시 체크"
git clone https://github.com/cjm0423/openstack && cd openstack   # 두 노드 모두
cp env.example env.sh && vi env.sh          # IP는 적지 않음. 호스트명/NIC(비우면 감지)/PROTECTED_IPS 확인 (env.sh는 .gitignore)

# 2. controller (.180)
./00-node-prep.sh --role controller
# 3. compute (.182)
./00-node-prep.sh --role compute
# 4. controller
./10-deployer.sh 210.94.240.182             # IP 감지·가드 → .state 저장 → venv → 인벤토리/globals → bootstrap(두 노드) → prechecks → READY
exit                                        # docker 그룹 반영 (재접속)
tmux new -s kolla
./20-deploy.sh                              # pull → deploy → post-deploy → 검증
./30-init.sh                                # br-ex 게이트웨이 + provider/tenant/router/cirros/flavor/SG
```

전부 재실행 안전. `globals.yml`은 `# >>> su-cloud >>>` 블록만 스크립트가 관리하고 나머지는 kolla 예제 그대로.

## 목요일 전에 해둘 것

- `backup-dev.sh` 로 `passwords.yml`, Warpgate 설정, nginx, `su-cloud-dev.com` 인증서 백업.

## AIO(운영계·스터디)와 달라지는 지점 — 딱 네 개

1. **원격 bootstrap.** `bootstrap-servers`가 SSH로 compute에 들어가 docker를 깐다. 그래서 `00-node-prep.sh`가 compute에 NOPASSWD sudo를 만들고, `10-deployer.sh`가 controller 키를 `ssh-copy-id`(첫 1회만 비밀번호)로 넣는다. 인벤토리에서 controller는 `ansible_connection=local` + venv python, compute는 SSH + 시스템 python. 이 차이 때문에 docker SDK가 controller는 venv에 `pip`로, compute는 bootstrap이 `python3-docker`를 apt로 깐다(Ubuntu 24.04 externally-managed 처리 — 컬렉션 `docker_sdk` 롤 확인).
2. **/etc/hosts.** `00-node-prep.sh`는 `127.0.1.1` 줄 삭제 + 자기 `IP 호스트명` 한 줄만. 상대 노드 이름은 `bootstrap-servers`의 kolla `etc_hosts` 롤이 인벤토리 기준으로 두 노드에 등록한다.
3. **인벤토리 `multinode`.** `[control]/[network]/[monitoring]/[storage]` = controller, `[compute]` = P520 (`CTRL_IS_COMPUTE=yes`면 controller도). 컨트롤러가 하나라 haproxy/keepalived/proxysql은 AIO 때처럼 끄고 VIP = controller IP. 운영계에서 겪은 keepalived/proxysql 우회 루프는 필요 없다.
4. **외부망은 controller에만.** OVN 게이트웨이 섀시 = `[network]` 그룹(`ovn-controller-network` → `enable-chassis-as-gw`). compute는 `neutron_ovn_distributed_fip`(기본 false)라 br-ex/veth가 필요 없다 — kolla `openvswitch/post-config.yml`의 `computes_need_external_bridge` 조건으로 확인. 그래서 `30-init.sh`는 스터디 `init.sh`와 사실상 같다.

브리지(`brbond0`)는 뺐다. 원래 veth0을 브리지에 물리려고 만든 건데 운영계에서 veth0 미부착으로 바뀐 뒤엔 MAC 스푸핑 편의밖에 남는 게 없다. netplan도 스크립트가 쓰지 않는다 — IP는 설치 때 고정.

## IP는 어디서 오나

- **env.sh에 IP 없음.** controller IP/NIC는 `10-deployer.sh`가 기본 라우트 NIC(또는 `CTRL_IF`)에서 읽고, compute IP는 인자로 받는다. 게이트웨이도 `ip -4 route show default`로 감지.
- `10-deployer.sh`가 확정한 `CTRL_IP/CTRL_IF/COMP_IP/COMP_IF`를 리포의 `.state`(git 제외)에 저장하고, `20-deploy.sh`/`30-init.sh`는 그걸 읽는다. `.state`가 없으면 두 스크립트는 중단.
- **운영계 가드.** `PROTECTED_IPS`(운영계 IP, env.sh)에 걸리는 IP가 나오면 어느 스크립트든 즉시 중단. 관리 NIC 주소가 DHCP(`dynamic`)여도 중단.
- `10-deployer.sh`는 compute가 게이트웨이 경유(`ip route get`에 `via`)면 같은 L2가 아니라고 중단하고, compute의 `hostname`이 `COMP_HOST`인지, 인자 IP가 compute 관리 NIC의 IP인지 확인한다.
- `nova_compute_virt_type`은 compute의 `/dev/kvm`으로 판정한다(없으면 중단 — P520 BIOS에서 VT-x). `CTRL_IS_COMPUTE=yes`면 controller도 확인.
- controller에 `HORIZON_PORT`가 이미 열려 있거나 `docker.io`/`containerd`(Ubuntu 패키지)가 깔려 있으면 `10-deployer.sh` [1/7]에서 중단 — 각각 horizon precheck 실패, docker-ce 충돌 원인.

## 설치 시 체크 (Ubuntu 24.04 server 설치 화면)

- **네트워크:** 케이블 연결된 포트 **하나만** 고정 IP(Manual). 나머지 NIC는 Disabled. subnet `210.94.240.0/24`, gateway `210.94.240.254`, DNS **`210.94.224.10`**(캠퍼스). DHCP로 두면 `00-node-prep.sh`가 중단한다.
- **OpenSSH server 설치** + 비밀번호 로그인 허용 — `10-deployer.sh`가 첫 1회 `ssh-copy-id`로 키를 넣는다.
- **디스크:** 인스턴스 디스크(nova_compute 볼륨)는 `/var/lib/docker` 아래 쌓인다. NVMe를 `/`로 쓸지 `/var/lib/docker`에 따로 마운트할지 설치 때 결정.
- **화면:** GPU 때문에 설치/부팅 화면이 깨지면 GRUB에서 `nomodeset` 추가.

## 운영계 함정 → 위치

| # | 함정 | 위치 |
|---|---|---|
| 1 | `127.0.1.1` 삭제 (RabbitMQ 루프백) | 00 [2/5] |
| 2 | `rp_filter=2` | 00 [3/5] |
| 4 | bootstrap이 docker 그룹 누락 | 10 [6/7] (두 노드) |
| 5 | veth0 미부착 | 00 [4/5] controller만 |
| 6 | 라우터 외부 IP `--fixed-ip` | 30 [2/3] |
| 7 | br-ex IP는 deploy 후 systemd로 | 30 [1/3] |
| 8 | passwords.yml 즉시 백업 | 10 [3/7] |
| 9 | `--dns-nameserver` | 30 [2/3] |
| 10 | FORWARD ACCEPT 명시 | 30 [1/3] |

(3번 "VIP=사설 IP"는 가비아 전용이라 해당 없음. 여기선 VIP = `.180`.)

## 검증 안 된 것 (첫 배포에서 볼 지점)

- **전체가 미검증.** AIO 절차를 멀티노드로 옮긴 것이지 돌려본 적 없다. 스터디 리허설 결과가 먼저 나오면 겹치는 부분(00/30)은 그걸로 갱신.
- 캠퍼스 L2 위 Geneve. 터널 MTU는 OVN이 DHCP로 1442를 내려주니 인스턴스에서 `ip link` 로 확인. 스위치가 UDP 6081을 막으면 compute 인스턴스가 DHCP를 못 받는다 — `docker exec ovn_sb_db ovn-sbctl show` 에 chassis 2개가 보이는데 인스턴스 IP가 안 잡히면 이쪽.
- `kolla_external_fqdn`(`EXTERNAL_FQDN=su-cloud-dev.com`)은 haproxy 없이 동작하는지 운영계에서 본 적 없다. 기본은 비워둠.
- Horizon이 `:80`을 잡는다. 나중에 nginx/Warpgate를 다시 올리면 `HORIZON_PORT`를 바꾸고 `kolla-ansible reconfigure -i /etc/kolla/multinode`.
- 새 P520의 NIC 이름은 받아봐야 안다. `COMP_IF` 비워두면 compute의 기본 라우트 NIC을 잡는다.

## 이후

- P520 두 번째 포트 + ThinkCentre USB NIC으로 직결 사설망을 만들면 `tunnel_interface`만 분리해서 캠퍼스 L2에서 Geneve를 빼낼 수 있다. 인벤토리 호스트 변수 한 줄.
- compute 추가는 `env.sh`에 호스트명 하나 더 + `10-deployer.sh` 인자/`.state` + `[compute]`에 한 줄.
- 운영계 AIO(`.179`)를 나중에 같은 방식으로 controller+compute로 가를 때도 이 리포를 그대로 쓴다 (`env.sh`만 다름).
