# 소스로 확인한 사실 (kolla-ansible 22.0.0 wheel + ansible-collection-kolla stable/2026.1, 2026-09-08)

| 사실 | 근거 |
|---|---|
| `--use-test-images`는 `prechecks`에만 있음. `pull`/`deploy`에 붙이면 `unrecognized arguments` | `kolla_ansible/cli/commands.py` `Prechecks.get_parser` |
| `enable_ovn = enable_neutron and neutron_plugin_agent == 'ovn'` — `neutron_plugin_agent: "ovn"` 한 줄로 OVN 전환 | `group_vars/all/ovn.yml:2` |
| OVN 게이트웨이 섀시 = `ovn-controller-network` 그룹(=`[network]`) → `enable-chassis-as-gw` | `roles/ovn-controller/tasks/setup-ovs.yml:29`, `inventory/multinode` `[ovn-controller-network:children] network` |
| br-ex 생성·`neutron_external_interface` 편입은 `[network]` 그룹 또는 (`[compute]` and `computes_need_external_bridge`) | `roles/openvswitch/tasks/post-config.yml:36,52` |
| `computes_need_external_bridge` = DVR or `enable_neutron_provider_networks` or `neutron_ovn_distributed_fip`; 셋 다 기본 false → compute에 br-ex 없음 | `group_vars/all/neutron.yml:47-57` |
| tenant 네트워크 타입: OVN이면 geneve | `group_vars/all/neutron.yml:43` |
| `kolla_external_vip_address` 기본 = internal VIP, `kolla_external_fqdn` 기본 = VIP | `group_vars/all/common.yml:183-191` |
| `nova_compute_virt_type` 기본 kvm | `group_vars/all/nova.yml:14` |
| `etc_hosts` 롤이 `127.0.1.1 <hostname>` 줄을 제거하고 baremetal 전 노드를 `api_interface` 주소로 등록, cloud-init `manage_etc_hosts` 비활성화 | 컬렉션 `roles/etc_hosts/tasks/etc-hosts.yml` |
| docker SDK: python이 externally-managed(24.04)이고 `virtualenv` 미지정이면 apt `python3-docker`/`python3-dbus` 설치, 아니면 pip `docker>=7.0.0` | 컬렉션 `roles/docker_sdk/defaults/main.yml` |
| 컬렉션 버전 고정: `stable/2026.1` | `share/kolla-ansible/requirements.yml` |
| 인벤토리 호스트별 `network_interface=...` override 가능 | `inventory/multinode` 주석 (`compute01 neutron_external_interface=eth0 api_interface=em1 ...`) |
| `globals.yml`(과 `passwords.yml`)은 `-e @globals.yml` extra vars로 전달 → 인벤토리 호스트 변수보다 우선. 노드별 값(`network_interface` 등)은 globals에 두면 안 됨 | `kolla_ansible/ansible.py` `build_args` |
