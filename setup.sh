#!/usr/bin/env bash
# Serveur de build isolé sur une machine du homelab : Incus + conteneur système
# non privilégié avec Docker, coupé du réseau local, joignable par Coolify via NetBird.
#
# Usage (en root ou via sudo, sur l'hôte Ubuntu) :
#   sudo bash setup.sh            installation complète
#   sudo bash setup.sh netbird    installe / connecte NetBird dans un conteneur existant
#   sudo bash setup.sh check      relance les vérifications d'isolation
#
# Les réponses sont lues sur /dev/tty, donc le mode "curl | bash" reste interactif.
# L'hôte n'est pas modifié au-delà d'Incus : pour durcir son SSH, utiliser vps-setup.
set -Eeuo pipefail

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[ok] %s\033[0m\n' "$*"; }
ko()   { printf '\033[1;31m[KO] %s\033[0m\n' "$*"; FAILED=1; }
trap 'die "Échec ligne $LINENO : $BASH_COMMAND"' ERR

# ask VAR "question" [defaut]
ask() {
  local __ans
  if [[ -n ${3:-} ]]; then
    read -rp "$2 [$3] : " __ans </dev/tty
  else
    read -rp "$2 : " __ans </dev/tty
  fi
  printf -v "$1" '%s' "${__ans:-${3:-}}"
}

# confirm "question" [o|n]  (defaut n)
confirm() {
  local a
  read -rp "$1 [${2:-n}] : " a </dev/tty
  [[ ${a:-${2:-n}} =~ ^[oOyY] ]]
}

# Garde uniquement les clés publiques valides, sans les options type command="..."
extract_keys() { grep -oE '(ssh|ecdsa|sk)-[a-z0-9@.-]+ AAAA[A-Za-z0-9+/=]+( .*)?$' || true; }

ACL=no-lan
# Tout ce qui n'est pas internet : LAN, VLAN, NetBird/Tailscale (100.64/10), lien local.
# L'IP de l'hôte sur le bridge est dans 10/8 : le conteneur ne joint pas non plus l'hôte.
# Incus garde ouverts DHCP et DNS vers le bridge, sinon le conteneur n'aurait pas de réseau.
PRIVATE_RANGES=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16

ct() { incus exec "$CT" -- "$@"; }

bridge_of_default_profile() { incus profile device get default eth0 network 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
ask_container() {
  while :; do
    ask CT "Nom du conteneur" "builder"
    [[ $CT =~ ^[a-z][a-z0-9-]{0,62}$ ]] && break
    warn "Nom invalide (minuscules, chiffres, -, commence par une lettre)."
  done
}

ask_netbird() {
  NB_URL="" NB_KEY=""
  while :; do
    ask NB_URL "URL du serveur NetBird (ex: https://netbird.mondomaine.fr)"
    NB_URL=${NB_URL%/}
    [[ $NB_URL =~ ^https://[^/[:space:]]+(:[0-9]+)?$ ]] && break
    warn "URL invalide (https://hôte, sans chemin)."
  done
  echo "Dans NetBird : Setup Keys > Create, usage unique, expiration courte, groupe 'builder' assigné automatiquement."
  while :; do
    read -rsp "Clé de setup NetBird (masquée) : " NB_KEY </dev/tty; echo
    [[ $NB_KEY =~ ^[A-Za-z0-9-]{20,}$ ]] && break
    warn "Clé invalide."
  done
}

ask_inputs() {
  local cpus mem_gb p

  ask_container
  if incus info "$CT" &>/dev/null; then
    warn "Le conteneur $CT existe déjà : il sera réutilisé (limites mises à jour, configuration réappliquée)."
  fi

  cpus=$(nproc)
  while :; do
    ask CPU "Nombre de CPU pour le conteneur (hôte : $cpus)" "$(( cpus > 1 ? cpus - 1 : 1 ))"
    [[ $CPU =~ ^[0-9]+$ ]] && (( CPU >= 1 && CPU <= cpus )) && break
    warn "Valeur invalide (1-$cpus)."
  done

  mem_gb=$(free -g | awk '/^Mem:/ {print $2}')
  while :; do
    # Laisser au moins 2 Go à l'hôte
    ask MEM "Mémoire du conteneur en Go (hôte : $mem_gb Go)" "$(( mem_gb > 3 ? mem_gb - 2 : 1 ))"
    [[ $MEM =~ ^[0-9]+$ ]] && (( MEM >= 1 && MEM <= mem_gb )) && break
    warn "Valeur invalide (1-$mem_gb)."
  done

  # Compte dédié comme dans vps-setup (doc : coolify.io/docs/core/infrastructure/servers/non-root-user)
  while :; do
    ask COOLIFY_USER "Nom de l'utilisateur Coolify" "coolify"
    [[ $COOLIFY_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $COOLIFY_USER != root ]] && break
    warn "Nom invalide (minuscules, chiffres, _ ou -, 32 caractères max, pas root)."
  done

  COOLIFY_KEY=""
  echo "Dans Coolify : Keys & Tokens > Private Keys > New private key > Generate ED25519 (sans passphrase), copier la clé publique."
  while :; do
    ask p "Clé publique Coolify (vide = l'ajouter plus tard)"
    [[ -z $p ]] && break
    COOLIFY_KEY=$(extract_keys <<<"$p" | head -n1)
    [[ -n $COOLIFY_KEY ]] && ssh-keygen -lf <(printf '%s\n' "$COOLIFY_KEY") 2>/dev/null && break
    warn "Clé invalide, recommencer."; COOLIFY_KEY=""
  done

  NETBIRD=0
  if confirm "Installer NetBird dans le conteneur (pas sur l'hôte) ?" o; then
    NETBIRD=1
    ask_netbird
  fi

  ADMIN_GROUP=0
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] && confirm "Ajouter $SUDO_USER au groupe incus-admin (commande incus sans sudo, équivalent à un accès root) ?" n; then
    ADMIN_GROUP=1
  fi

  NO_SLEEP=0
  if compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then
    confirm "Batterie détectée : empêcher la mise en veille (capot fermé compris) ?" o && NO_SLEEP=1
  fi

  echo
  info "Récapitulatif"
  echo "  Conteneur : $CT (Ubuntu 24.04, non privilégié, Docker imbriqué, démarrage automatique)"
  echo "  Limites   : $CPU CPU, $MEM Go de RAM"
  echo "  Réseau    : ACL $ACL sur le bridge Incus, IPv6 coupé sur le bridge"
  echo "              bloqués : ${PRIVATE_RANGES//,/ }"
  echo "  Coolify   : utilisateur $COOLIFY_USER (sudo sans mot de passe, SSH par clé uniquement, root interdit)"
  echo "              $( [[ -n $COOLIFY_KEY ]] && echo "clé ajoutée" || echo "clé à ajouter plus tard")"
  echo "  NetBird   : $( ((NETBIRD)) && echo "$NB_URL, hostname $CT" || echo non)"
  echo "  incus-admin : $( ((ADMIN_GROUP)) && echo "$SUDO_USER" || echo non)"
  echo "  Pas de veille : $( ((NO_SLEEP)) && echo oui || echo non)"
  confirm "Lancer la configuration ?" o || die "Annulé."
}

# ---------------------------------------------------------------------------
# Étapes hôte
# ---------------------------------------------------------------------------
step_no_sleep() {
  (( NO_SLEEP )) || return 0
  info "Pas de mise en veille"
  install -d -m 755 /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/50-no-sleep.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  # Un redémarrage de logind peut couper la session graphique, pas la session SSH
  systemctl restart systemd-logind
}

# "incus admin init --minimal" échoue quand il ne trouve pas seul de sous-réseau libre :
# on choisit un /24 en 10.x qui ne chevauche aucune route de l'hôte
init_incus() {
  local net gw
  gw=$(ip -4 route show default | awk '{print $3; exit}')
  [[ -n $gw ]] || die "Pas de route par défaut sur l'hôte."
  while :; do
    net="10.$((RANDOM % 256)).$((RANDOM % 256))"
    # Libre si l'hôte l'enverrait par sa route par défaut (aucune route plus précise, /8 compris)
    ip -4 route get "$net.1" | grep -q " via $gw " && break
  done
  incus admin init --preseed <<EOF
networks:
- name: incusbr0
  type: bridge
  config:
    ipv4.address: $net.1/24
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
  driver: dir
profiles:
- name: default
  devices:
    root: {path: /, pool: default, type: disk}
    eth0: {name: eth0, network: incusbr0, type: nic}
EOF
}

# Dépôt officiel Incus (Zabbly) : l'Incus 6.0.0 d'Ubuntu 24.04 ne laisse pas tourner
# Docker depuis les correctifs de sécurité de runc (sysctl ... permission denied)
ZABBLY_FPR=4EFC590696CB15B87C73A3AD82CC8797C838DCFD
install_incus() {
  local key=/etc/apt/keyrings/zabbly.asc fpr codename
  if [[ ! -f /etc/apt/sources.list.d/zabbly-incus-stable.sources ]]; then
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL --max-time 30 https://pkgs.zabbly.com/key.asc -o "$key.tmp"
    fpr=$(gpg --show-keys --with-colons "$key.tmp" | awk -F: '/^fpr/ {print $10; exit}')
    [[ $fpr == "$ZABBLY_FPR" ]] || { rm -f "$key.tmp"; die "Empreinte de la clé Zabbly inattendue : $fpr"; }
    mv "$key.tmp" "$key"
    codename=${VERSION_CODENAME:?}   # lu depuis /etc/os-release dans main()
    cat >/etc/apt/sources.list.d/zabbly-incus-stable.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $codename
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: $key
EOF
  fi
  apt-get update
  # Installe, ou remplace la version Ubuntu déjà présente
  apt-get install -y incus
}

step_incus() {
  info "Incus"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  install_incus
  incus --version
  (( ADMIN_GROUP )) && usermod -aG incus-admin "$SUDO_USER"

  BR=$(bridge_of_default_profile)
  if [[ -z $BR ]]; then
    init_incus
    BR=$(bridge_of_default_profile)
  fi
  [[ -n $BR ]] || die "Pas de réseau sur le profil default d'Incus (incus profile show default)."

  # Les ACL sur un bridge ne fonctionnent qu'avec le pare-feu nftables
  incus info | grep -q 'firewall: nftables' \
    || die "Incus n'utilise pas nftables (règles iptables existantes, Docker sur l'hôte ?) : les ACL du bridge ne s'appliqueraient pas."
  if command -v docker &>/dev/null; then
    warn "Docker est installé sur l'hôte : sa politique FORWARD peut bloquer internet dans le conteneur."
  fi
}

step_network() {
  info "Isolation réseau : ACL $ACL sur $BR"
  local acls
  # Une seule famille d'adresses à filtrer
  incus network set "$BR" ipv6.address=none

  incus network acl show "$ACL" &>/dev/null || incus network acl create "$ACL"
  # edit remplace toutes les règles : relancer le script redonne toujours la même ACL
  incus network acl edit "$ACL" <<EOF
description: Bloque le réseau local et l'hôte, laisse sortir vers internet (incus-builder)
egress:
- action: reject
  destination: $PRIVATE_RANGES
  state: enabled
- action: allow
  destination: 0.0.0.0/0
  state: enabled
ingress: []
EOF

  acls=$(incus network get "$BR" security.acls)
  if [[ -z $acls ]]; then
    incus network set "$BR" security.acls="$ACL"
  elif [[ ,$acls, != *",$ACL,"* ]]; then
    incus network set "$BR" security.acls="$acls,$ACL"
  fi

  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "UFW actif sur l'hôte : autorisation du bridge $BR"
    # Accès à l'hôte depuis le conteneur déjà limité par l'ACL (DHCP et DNS seulement)
    ufw allow in on "$BR"
    ufw route allow in on "$BR"
    ufw route allow out on "$BR"
  fi
}

step_container() {
  info "Conteneur $CT"
  if ! incus info "$CT" &>/dev/null; then
    incus init images:ubuntu/24.04 "$CT"
  fi
  incus config set "$CT" \
    security.nesting=true \
    security.syscalls.intercept.mknod=true \
    security.syscalls.intercept.setxattr=true \
    limits.cpu="$CPU" \
    limits.memory="${MEM}GiB" \
    boot.autostart=true
  # NetBird crée son interface WireGuard via /dev/net/tun
  incus config device show "$CT" | grep -q '^tun:' \
    || incus config device add "$CT" tun unix-char path=/dev/net/tun
  if [[ $(incus info "$CT" | awk '/^Status:/ {print $2}') == RUNNING ]]; then
    incus restart "$CT"
  else
    incus start "$CT"
  fi

  for _ in {1..30}; do
    ct getent hosts deb.debian.org &>/dev/null && return 0
    sleep 2
  done
  die "Pas de DNS dans le conteneur après 60 s. Tester sans l'ACL : incus network unset $BR security.acls"
}

# ---------------------------------------------------------------------------
# Étapes conteneur
# ---------------------------------------------------------------------------
step_provision() {
  info "Docker et SSH dans $CT"
  incus exec "$CT" --env COOLIFY_USER="$COOLIFY_USER" --env COOLIFY_KEY="$COOLIFY_KEY" -- bash -s <<'EOF'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
apt-get install -y curl ca-certificates openssh-server sudo unattended-upgrades iputils-ping

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

if ! command -v docker &>/dev/null; then
  # Téléchargé puis exécuté : un téléchargement interrompu ne lance rien
  curl -fsSL --max-time 60 https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi
# Rotation des logs, sans écraser une config existante
if [[ ! -f /etc/docker/daemon.json ]]; then
  install -d -m 755 /etc/docker
  cat >/etc/docker/daemon.json <<'CONF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
CONF
  systemctl restart docker
fi
systemctl enable docker
# Le cache de build grossit sans limite : nettoyage hebdomadaire
cat >/etc/cron.d/docker-prune <<'CONF'
0 5 * * 0 root docker builder prune -af --filter until=168h >/dev/null 2>&1; docker image prune -af --filter until=168h >/dev/null 2>&1
CONF

# Utilisateur Coolify, comme vps-setup : 'NP' = compte déverrouillé sans mot de passe
# utilisable (un compte verrouillé refuse aussi les clés SSH)
if ! id "$COOLIFY_USER" &>/dev/null; then
  useradd --create-home --user-group --shell /bin/bash --password 'NP' "$COOLIFY_USER"
elif [[ $(passwd -S "$COOLIFY_USER" | awk '{print $2}') == L ]]; then
  usermod -p 'NP' "$COOLIFY_USER"
fi
home=$(getent passwd "$COOLIFY_USER" | cut -d: -f6)
install -d -m 700 -o "$COOLIFY_USER" -g "$COOLIFY_USER" "$home/.ssh"
ak=$home/.ssh/authorized_keys
touch "$ak"
if [[ -n $COOLIFY_KEY ]] && ! grep -qxF "$COOLIFY_KEY" "$ak"; then echo "$COOLIFY_KEY" >>"$ak"; fi
chown "$COOLIFY_USER:$COOLIFY_USER" "$ak"
chmod 600 "$ak"

sudoers=/etc/sudoers.d/$COOLIFY_USER
echo "$COOLIFY_USER ALL=(ALL) NOPASSWD: ALL" >"$sudoers.tmp"
chmod 440 "$sudoers.tmp"
visudo -cf "$sudoers.tmp" >/dev/null || { rm -f "$sudoers.tmp"; echo "Règle sudoers invalide" >&2; exit 1; }
mv "$sudoers.tmp" "$sudoers"
[[ $(su - "$COOLIFY_USER" -c 'sudo -n whoami') == root ]]

mkdir -p /data/coolify
chown -R "$COOLIFY_USER:$COOLIFY_USER" /data/coolify
chmod -R o-rwx /data/coolify

cat >/etc/ssh/sshd_config.d/00-hardening.conf <<CONF
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowUsers $COOLIFY_USER
CONF
install -d -m 755 /run/sshd
sshd -t
systemctl enable ssh
systemctl restart ssh
EOF
}

step_netbird() {
  info "NetBird dans $CT"
  # Clé lue sur stdin : elle n'apparaît ni dans la liste des processus de l'hôte ni dans l'historique
  incus exec "$CT" --env NB_MANAGEMENT_URL="$NB_URL" --env NB_HOSTNAME="$CT" -- bash -c '
    set -Eeuo pipefail
    read -r NB_SETUP_KEY; export NB_SETUP_KEY
    if ! command -v netbird &>/dev/null; then
      curl -fsSL --max-time 60 https://pkgs.netbird.io/install.sh -o /tmp/netbird-install.sh
      sh /tmp/netbird-install.sh
      rm -f /tmp/netbird-install.sh
    fi
    netbird up --management-url "$NB_MANAGEMENT_URL" --hostname "$NB_HOSTNAME"
  ' <<<"$NB_KEY"
  ct netbird status
}

coolify_user() { ct awk '$1 == "AllowUsers" {print $2}' /etc/ssh/sshd_config.d/00-hardening.conf 2>/dev/null || true; }

netbird_ip() { ct netbird status 2>/dev/null | awk '/NetBird IP:/ {sub(/\/.*/, "", $3); print $3}'; }

# ---------------------------------------------------------------------------
# Vérifications
# ---------------------------------------------------------------------------
step_check() {
  info "Vérifications"
  local gw br_ip nb cu
  FAILED=0
  BR=${BR:-$(bridge_of_default_profile)}
  br_ip=$(incus network get "$BR" ipv4.address); br_ip=${br_ip%/*}
  gw=$(ip -4 route show default | awk '{print $3; exit}')

  if ct curl -fsS -o /dev/null --max-time 15 https://deb.debian.org; then ok "Internet joignable"; else ko "Internet injoignable"; fi

  if [[ -n $gw ]] && ping -c1 -W2 "$gw" &>/dev/null; then
    if ct ping -c1 -W2 "$gw" &>/dev/null; then ko "Box $gw joignable depuis le conteneur"; else ok "Box $gw injoignable depuis le conteneur"; fi
  else
    warn "Passerelle $gw ne répond pas au ping depuis l'hôte : test LAN impossible."
  fi

  if ct timeout 3 bash -c "</dev/tcp/$br_ip/22" &>/dev/null; then
    ko "SSH de l'hôte ($br_ip:22) joignable depuis le conteneur"
  else
    ok "Hôte ($br_ip) injoignable depuis le conteneur"
  fi

  if ct docker run --rm hello-world &>/dev/null; then
    ok "Docker fonctionne ($(ct docker info -f '{{.Driver}}'))"
  else
    ko "docker run hello-world échoue : incus exec $CT -- docker run --rm hello-world"
  fi

  if ct systemctl is-active --quiet ssh; then ok "SSH actif dans le conteneur"; else ko "SSH inactif dans le conteneur"; fi
  cu=$(coolify_user)
  if [[ -z $cu ]]; then
    ko "Pas d'utilisateur Coolify dans AllowUsers (/etc/ssh/sshd_config.d/00-hardening.conf)"
  elif ! ct test -s "/home/$cu/.ssh/authorized_keys"; then
    warn "Aucune clé Coolify : incus exec $CT -- bash -c 'cat >>/home/$cu/.ssh/authorized_keys' <<<'ssh-ed25519 AAAA...'"
  fi

  if ct sh -c 'command -v netbird' &>/dev/null; then
    nb=$(netbird_ip)
    if ct netbird status | grep -q 'Management: Connected'; then ok "NetBird connecté (${nb:-IP inconnue})"; else ko "NetBird non connecté : incus exec $CT -- netbird status"; fi
  fi
  return 0
}

summary() {
  local nb
  nb=$(netbird_ip || true)
  info "Terminé"
  (( FAILED )) && warn "Au moins une vérification a échoué (voir [KO] plus haut)."
  echo "Shell dans le conteneur : sudo incus exec $CT -- bash"
  echo
  echo "Dans NetBird :"
  echo "  - politique coolify -> builder, TCP 22, non bidirectionnelle"
  echo "  - politique builder -> coolify, port du registry"
  echo "  - aucune route vers le LAN distribuée au groupe builder"
  echo
  echo "Dans Coolify : Servers > Add"
  echo "  IP ${nb:-<IP NetBird du conteneur>}, port 22, utilisateur $(coolify_user), clé générée dans Coolify"
  echo "  cocher \"Use it as a build server\""
}

# ---------------------------------------------------------------------------
# Tout est dans main() : un téléchargement tronqué via "curl | bash" ne lance rien.
main() {
  [[ $EUID -eq 0 ]] || die "À lancer en root (ou avec sudo)."
  { : </dev/tty; } 2>/dev/null || die "Pas de terminal interactif (/dev/tty) disponible."
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ ${ID:-} != ubuntu ]]; then
    confirm "Système détecté : ${PRETTY_NAME:-inconnu}, prévu pour Ubuntu. Continuer ?" n || exit 1
  fi

  FAILED=0
  case ${1:-} in
    "") ;;
    netbird)
      command -v incus &>/dev/null || die "Incus n'est pas installé : lancer d'abord le script sans paramètre."
      ask_container
      incus info "$CT" &>/dev/null || die "Conteneur $CT introuvable."
      ask_netbird; step_netbird; return 0 ;;
    check)
      ask_container
      incus info "$CT" &>/dev/null || die "Conteneur $CT introuvable."
      step_check; return "$FAILED" ;;
    *) die "Étape inconnue : $1 (étapes disponibles : netbird, check)" ;;
  esac

  ask_inputs
  step_no_sleep
  step_incus
  step_network
  step_container
  step_provision
  (( NETBIRD )) && step_netbird
  step_check
  summary
}

main "$@"
