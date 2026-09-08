# SU-Cloud 개발계 — Kolla-Ansible 멀티노드 (controller + compute)

기존 개발계(ThinkCentre, `.180`, AIO)를 밀고 **controller**로, 목요일에 들어오는 새 P520(`.181`)을 **compute**로 쓰는 2노드 구성.
근거는 전부 SU-Cloud 운영계(`.179`, AIO/OVN) 구축 기록이고, 스터디용 `setup.sh`/`init.sh`(가비아 AIO)에서 검증된 함정 처리를 그대로 가져왔다.
스터디 스크립트는 `openstack-study` 리포에 따로 있다. 이 리포는 학교 환경 전용.

```
                캠퍼스 LAN 210.94.240.0/24  (gw .254, MAC ACL)
  ─────────────┬──────────────────────────────┬─────────────
               │ .180                         │ .181
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
# 1. 두 노드 Ubuntu 24.04 server 설치, 유저 ubuntu, 고정 IP (.180 / .181)
git clone https://github.com/cjm0423/openstack && cd openstack
cp env.example env.sh && vi env.sh          # 값 확인 (env.sh는 .gitignore)

# 2. controller (.180)
./00-node-prep.sh                           # 새 설치라 IP가 아직 아니면: --role controller --write-netplan
# 3. compute (.181)
./00-node-prep.sh                           # 마찬가지: --role compute --write-netplan
# 4. controller
./10-deployer.sh                            # venv → 인벤토리/globals → bootstrap(두 노드) → prechecks → READY
exit                                        # docker 그룹 반영
tmux new -s kolla
./20-deploy.sh                              # pull → deploy → post-deploy → 검증
./30-init.sh                                # br-ex 게이트웨이 + provider/tenant/router/cirros/flavor/SG
```

전부 재실행 안전. `globals.yml`은 `# >>> su-cloud >>>` 블록만 스크립트가 관리하고 나머지는 kolla 예제 그대로.

## 목요일 전에 해둘 것

- **새 P520 MAC 등록.** 캠퍼스 스위치가 MAC ACL을 걸어서(7월 개발계 사건) 미등록 NIC은 ARP는 되고 IP가 안 나간다. X550-T2 포트 둘 중 쓸 포트 하나의 MAC만 교수님께 `.181`로 등록 요청. 받자마자 `ip link` 로 MAC 확인 → 등록 → 그다음 설치. `00-node-prep.sh`가 게이트웨이 ping 실패 시 이 경고를 낸다.
- ThinkCentre가 지금 노트북 MAC으로 스푸핑 중이면, 재설치 후에도 그대로 써야 하는지 결정 (`env.sh`의 `CTRL_MAC`). 등록된 MAC이 있으면 비워두면 된다.
- `backup-dev.sh` 로 `passwords.yml`, Warpgate 설정, nginx, `su-cloud-dev.com` 인증서 백업.

## AIO(운영계·스터디)와 달라지는 지점 — 딱 네 개

1. **원격 bootstrap.** `bootstrap-servers`가 SSH로 compute에 들어가 docker를 깐다. 그래서 `00-node-prep.sh`가 compute에 NOPASSWD sudo를 만들고, `10-deployer.sh`가 controller 키를 `ssh-copy-id`(첫 1회만 비밀번호)로 넣는다. 인벤토리에서 controller는 `ansible_connection=local` + venv python, compute는 SSH + 시스템 python. 이 차이 때문에 docker SDK가 controller는 venv에 `pip`로, compute는 bootstrap이 `python3-docker`를 apt로 깐다(Ubuntu 24.04 externally-managed 처리 — 컬렉션 `docker_sdk` 롤 확인).
2. **/etc/hosts 양쪽.** `127.0.1.1` 치환 + 두 노드 이름 등록. kolla `etc_hosts` 롤도 같은 일을 하지만 prechecks 전에 로컬에서 확정.
3. **인벤토리 `multinode`.** `[control]/[network]/[monitoring]/[storage]` = controller, `[compute]` = P520 (`CTRL_IS_COMPUTE=yes`면 controller도). 컨트롤러가 하나라 haproxy/keepalived/proxysql은 AIO 때처럼 끄고 VIP = controller IP. 운영계에서 겪은 keepalived/proxysql 우회 루프는 필요 없다.
4. **외부망은 controller에만.** OVN 게이트웨이 섀시 = `[network]` 그룹(`ovn-controller-network` → `enable-chassis-as-gw`). compute는 `neutron_ovn_distributed_fip`(기본 false)라 br-ex/veth가 필요 없다 — kolla `openvswitch/post-config.yml`의 `computes_need_external_bridge` 조건으로 확인. 그래서 `30-init.sh`는 스터디 `init.sh`와 사실상 같다.

브리지(`brbond0`)는 뺐다. 원래 veth0을 브리지에 물리려고 만든 건데 운영계에서 veth0 미부착으로 바뀐 뒤엔 MAC 스푸핑 편의밖에 남는 게 없고, 그건 netplan `macaddress:` 로 NIC에 직접 준다.

## 운영계 함정 → 위치

| # | 함정 | 위치 |
|---|---|---|
| 1 | `127.0.1.1` 치환 (RabbitMQ 루프백) | 00 [2/6] |
| 2 | `rp_filter=2` | 00 [4/6] |
| 4 | bootstrap이 docker 그룹 누락 | 10 [6/7] (두 노드) |
| 5 | veth0 미부착 | 00 [5/6] controller만 |
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
- 새 P520의 NIC 이름은 받아봐야 안다. `COMP_IF` 비워두면 기본 라우트 NIC을 잡는다.

## 이후

- P520 두 번째 포트 + ThinkCentre USB NIC으로 직결 사설망을 만들면 `tunnel_interface`만 분리해서 캠퍼스 L2에서 Geneve를 빼낼 수 있다. 인벤토리 호스트 변수 한 줄.
- compute 추가는 `env.sh`에 노드 하나 더 + `[compute]`에 한 줄. 지금 구조가 그대로 확장된다.
- 운영계 AIO(`.179`)를 나중에 같은 방식으로 controller+compute로 가를 때도 이 리포를 그대로 쓴다 (`env.sh`만 다름).
