#!/usr/bin/env bash
# Tests d'isolation et de SSH du conteneur, en root sur l'hôte : sudo bash test.sh [conteneur]
# Crée le temps du test une interface factice, deux petits serveurs (TCP 8099, UDP 9099),
# une clé SSH temporaire et un utilisateur "intrus" dans le conteneur ; tout est retiré à la fin.
set -uo pipefail
CT=${1:-builder}
PASS=0 FAIL=0
ct() { incus exec "$CT" -- "$@"; }
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
# expect_ok "desc" cmd... / expect_ko "desc" cmd...
expect_ok() { local d=$1; shift; if "$@" &>/dev/null; then pass "$d"; else fail "$d"; fi; }
expect_ko() { local d=$1; shift; if "$@" &>/dev/null; then fail "$d"; else pass "$d"; fi; }
tcp() { timeout 4 bash -c "</dev/tcp/$1/$2"; }

BR=$(incus profile device get default eth0 network)
BR_IP=$(incus network get "$BR" ipv4.address); BR_IP=${BR_IP%/*}
HOST_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<NF; i++) if ($i=="src") {print $(i+1); exit}}')
GW=$(ip -4 route show default | awk '{print $3; exit}')
CT_IP=$(incus list "^$CT\$" -c 4 -f csv | grep -oE '10\.[0-9.]+ \(eth0\)' | cut -d' ' -f1)
echo "bridge=$BR_IP host=$HOST_IP gw=$GW ct=$CT_IP"

# Faux services sur l'hôte : un sur chaque plage privée (LAN, hôte, NetBird, 172.16/12)
ip link add dummy-test type dummy 2>/dev/null
ip addr add 100.80.0.1/32 dev dummy-test 2>/dev/null
ip addr add 172.20.0.1/32 dev dummy-test 2>/dev/null
ip addr add 192.168.77.1/32 dev dummy-test 2>/dev/null
ip link set dummy-test up
# Dossier vide servi : rien à lire pour un autre appareil du LAN pendant le test
EMPTY=$(mktemp -d)
python3 -m http.server 8099 --bind 0.0.0.0 --directory "$EMPTY" &>/dev/null &
WEB=$!
python3 - <<'EOF' &
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 9099))
while True:
    d, a = s.recvfrom(100); s.sendto(b"pong", a)
EOF
UDP=$!
sleep 1
trap 'kill $WEB $UDP 2>/dev/null; rm -rf "$EMPTY"; ip link del dummy-test 2>/dev/null; ct sed -i "/ incus-builder-test\$/d" "/home/${U:-x}/.ssh/authorized_keys" 2>/dev/null' EXIT
udp() { ct python3 -c "import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3); s.sendto(b'ping',('$1',$2)); sys.exit(0 if s.recv(10)==b'pong' else 1)"; }

echo "== Témoins : les services répondent depuis l'hôte"
for ip in "$HOST_IP" "$BR_IP" 100.80.0.1 172.20.0.1 192.168.77.1; do expect_ok "hôte -> $ip:8099" tcp "$ip" 8099; done
expect_ok "hôte -> ping passerelle $GW" ping -c1 -W2 "$GW"

echo "== Conteneur -> internet"
expect_ok "HTTPS internet" ct curl -fsS -o /dev/null --max-time 15 https://deb.debian.org
expect_ok "DNS (résolveur du bridge)" ct getent hosts github.com
command -v python3 &>/dev/null || { echo 'python3 requis sur l hôte'; exit 1; }
ct apt-get install -y -qq python3-minimal &>/dev/null
expect_ok "DNS UDP direct vers 1.1.1.1" ct python3 -c "import socket; s=socket.socket(2,2); s.settimeout(3); s.sendto(bytes.fromhex('abcd01000001000000000000076578616d706c6503636f6d0000010001'),('1.1.1.1',53)); s.recv(512)"

echo "== Conteneur -> réseau local et hôte (doivent échouer)"
expect_ko "ping passerelle $GW" ct ping -c1 -W2 "$GW"
for ip in "$HOST_IP" "$BR_IP" 100.80.0.1 172.20.0.1 192.168.77.1; do expect_ko "TCP $ip:8099" ct timeout 4 bash -c "</dev/tcp/$ip/8099"; done
expect_ko "SSH de l'hôte $BR_IP:22" ct timeout 4 bash -c "</dev/tcp/$BR_IP/22"
expect_ko "UDP $HOST_IP:9099" udp "$HOST_IP" 9099
expect_ko "UDP 100.80.0.1:9099" udp 100.80.0.1 9099
expect_ko "DNS UDP vers la passerelle $GW:53" ct python3 -c "import socket; s=socket.socket(2,2); s.settimeout(3); s.sendto(bytes.fromhex('abcd01000001000000000000076578616d706c6503636f6d0000010001'),('$GW',53)); s.recv(512)"
expect_ko "IPv6 vers internet" ct curl -6 -fsS -o /dev/null --max-time 8 https://deb.debian.org

echo "== Build Docker dans le conteneur (même isolation)"
expect_ok "docker: HTTPS internet" ct docker run --rm alpine wget -q -O /dev/null -T 10 https://deb.debian.org
expect_ok "docker: DNS" ct docker run --rm alpine nslookup github.com
expect_ko "docker: TCP $HOST_IP:8099" ct docker run --rm alpine wget -q -O /dev/null -T 4 "http://$HOST_IP:8099"
expect_ko "docker: TCP 100.80.0.1:8099" ct docker run --rm alpine wget -q -O /dev/null -T 4 http://100.80.0.1:8099
expect_ko "docker: ping $GW" ct docker run --rm alpine ping -c1 -W2 "$GW"
expect_ok "docker build" ct bash -c 'd=$(mktemp -d); printf "FROM alpine\nRUN apk add --no-cache curl && curl -fsS -o /dev/null https://deb.debian.org\n" >$d/Dockerfile; docker build -q --no-cache $d'

echo "== Hôte / LAN -> conteneur (entrée refusée)"
expect_ko "hôte -> conteneur $CT_IP:22" tcp "$CT_IP" 22

echo "== SSH du conteneur"
U=$(ct awk '$1=="AllowUsers"{print $2}' /etc/ssh/sshd_config.d/00-hardening.conf)
cfg=$(ct sshd -T)
expect_ok "PermitRootLogin no" grep -qx 'permitrootlogin no' <<<"$cfg"
expect_ok "PasswordAuthentication no" grep -qx 'passwordauthentication no' <<<"$cfg"
expect_ok "AllowUsers $U" grep -qx "allowusers $U" <<<"$cfg"
# Clé temporaire ajoutée à l'utilisateur Coolify, retirée à la fin
ct rm -f /tmp/k /tmp/k.pub
ct ssh-keygen -q -t ed25519 -N '' -C incus-builder-test -f /tmp/k
ct bash -c "cat /tmp/k.pub >>/home/$U/.ssh/authorized_keys"
o='-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /tmp/k'
expect_ok "clé Coolify : connexion $U + sudo root" ct bash -c "[[ \$(ssh $o $U@127.0.0.1 sudo -n whoami) == root ]]"
expect_ok "$U : docker via sudo" ct ssh $o "$U@127.0.0.1" sudo -n docker ps
expect_ok "$U : /data/coolify lui appartient" ct bash -c "[[ \$(stat -c %U /data/coolify) == $U ]]"
expect_ko "root refusé avec la même clé" ct ssh $o root@127.0.0.1 true
ct useradd -m intrus &>/dev/null; ct install -d -m 700 -o intrus /home/intrus/.ssh
ct cp "/home/$U/.ssh/authorized_keys" /home/intrus/.ssh/; ct chown intrus /home/intrus/.ssh/authorized_keys
expect_ko "autre utilisateur refusé (AllowUsers)" ct ssh $o intrus@127.0.0.1 true
ct userdel -r intrus &>/dev/null
expect_ko "mot de passe refusé" ct ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o ConnectTimeout=5 "$U@127.0.0.1" true
ct sed -i '/ incus-builder-test$/d' "/home/$U/.ssh/authorized_keys"
ct rm -f /tmp/k /tmp/k.pub

echo "== Prérequis NetBird dans le conteneur"
expect_ok "/dev/net/tun présent" ct test -c /dev/net/tun
expect_ok "création d'une interface TUN" ct bash -c 'ip tuntap add dev tuntest mode tun && ip link del tuntest'
expect_ok "création d'une interface WireGuard noyau" ct bash -c 'ip link add wgtest type wireguard && ip link del wgtest'

echo "== Hôte"
expect_ok "ACL $BR = no-lan" bash -c "[[ \$(incus network get $BR security.acls) == *no-lan* ]]"
expect_ok "conteneur non privilégié" bash -c "[[ \$(incus config get $CT security.privileged) != true ]]"
expect_ok "root du conteneur mappé sur un UID non root de l'hôte" bash -c "ps -o uid= -p \$(incus info $CT | awk '/^PID:/{print \$2}') | grep -qv '^ *0$'"
expect_ok "démarrage automatique" bash -c "[[ \$(incus config get $CT boot.autostart) == true ]]"

echo
echo "RESULTAT : $PASS PASS, $FAIL FAIL"
(( FAIL == 0 ))
