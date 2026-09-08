#!/usr/bin/env bash
# =============================================================================
# backup-dev.sh — 기존 개발계(.180)를 밀기 전에 한 번. 결과 tar를 Tailscale로 운영계나 로컬에 옮길 것.
#   포함: /etc/kolla(passwords.yml!), warpgate 설정, nginx, letsencrypt(su-cloud-dev.com), netplan, ssh 호스트키, portal 소스 위치 목록
# =============================================================================
set -euo pipefail
OUT="$HOME/dev-backup-$(hostname)-$(date +%F).tar.gz"
sudo tar czf "$OUT" --ignore-failed-read \
    /etc/kolla /etc/netplan /etc/nginx /etc/letsencrypt /etc/ssh/ssh_host_* \
    /var/lib/warpgate /etc/systemd/system/veth-setup.service /etc/systemd/system/br-ex-gw.service \
    /etc/sysctl.d/99-kolla.conf /etc/hosts 2>/dev/null || true
sudo chown "$USER" "$OUT"; chmod 600 "$OUT"
echo "== $OUT"; tar tzf "$OUT" | head -30
echo
echo "홈 디렉토리에 남은 레포/작업물 (수동 확인):"; ls -d ~/*/ 2>/dev/null
echo "docker 볼륨 (portal DB 등):"; sudo docker volume ls 2>/dev/null || true
echo
echo "옮기기 예:  scp $OUT ubuntu@100.119.138.65:~/   (또는 로컬로)"
