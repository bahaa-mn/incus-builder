# incus-builder

Serveur de build Coolify sur une machine du homelab (laptop sous Ubuntu Server, par exemple), sans VM et sans ouvrir de port sur le réseau local.

Le script installe [Incus](https://linuxcontainers.org/incus/) et crée un conteneur système non privilégié qui fait tourner Docker. Le conteneur est coupé du réseau local et de l'hôte, il ne sort que vers internet. NetBird, installé dans le conteneur (pas sur l'hôte), permet à Coolify de s'y connecter en SSH.

```
VPS Coolify  <── NetBird (sortant, chiffré) ──>  hôte Ubuntu
                                                 └─ conteneur Incus "builder"
                                                    Docker + SSH, coupé du LAN
```

## Utilisation

Le dépôt est privé : copier le script sur l'hôte, puis le lancer en root.

```bash
gh api repos/bahaa-mn/incus-builder/contents/setup.sh -H 'Accept: application/vnd.github.raw' > setup.sh
# ou depuis votre machine : scp setup.sh <user>@<hote>:
sudo bash setup.sh
```

Le script pose ses questions au début, affiche un récapitulatif, fait tout, puis lance les vérifications.

## Ce que le script demande

- nom du conteneur (`builder` par défaut)
- nombre de CPU et mémoire (par défaut : tout sauf 1 CPU et 2 Go laissés à l'hôte)
- nom de l'utilisateur Coolify (`coolify` par défaut) et sa clé publique, générée dans Coolify (optionnelle, ajoutable plus tard)
- NetBird (optionnel) : URL du serveur, clé de setup (saisie masquée), IP NetBird du serveur Coolify et port(s) de son registry (5000 par défaut)
- ajout de l'utilisateur au groupe `incus-admin` (optionnel, équivalent root)
- sur un laptop (batterie détectée) : pas de mise en veille, capot fermé compris

## Ce qu'il fait

**Hôte**
- installe Incus depuis le dépôt officiel [Zabbly](https://github.com/zabbly/incus) (empreinte de la clé vérifiée) : l'Incus 6.0.0 d'Ubuntu 24.04 ne fait plus tourner Docker depuis les correctifs de sécurité de runc (`open sysctl net.ipv4.ip_unprivileged_port_start ... permission denied`). Une version Ubuntu déjà installée est remplacée
- l'initialise s'il ne l'est pas déjà (bridge par défaut `incusbr0` en `10.x.y.0/24` qui ne chevauche aucune route de l'hôte)
- crée un bridge dédié au builder, `builderbr0`, en `10.x.y.0/24` libre et sans IPv6 : aucune autre instance ne le partage, et le bridge par défaut de l'hôte (et ses autres conteneurs) n'est pas modifié
- pose l'ACL `no-lan` sur `builderbr0` : rejet de `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` (NetBird, Tailscale), `169.254.0.0/16`, du multicast et du broadcast, **de toutes les adresses IPv4 de l'hôte** (une IP publique de l'hôte serait sinon joignable) **et des réseaux connectés ou routés par l'hôte** (LAN en adresses publiques, routes VPN ; les routes par la passerelle par défaut et celles plus larges que /8 restent ouvertes, c'est internet), tout le reste autorisé vers internet. Incus laisse passer DHCP et DNS vers le bridge
- si UFW est actif : autorise le trafic du bridge (le filtrage reste fait par l'ACL)
- si l'hôte change d'adresse ou de routes (nouvelle IP publique, nouveau VPN), relancer le script pour mettre l'ACL à jour : `setup.sh check` teste toutes les adresses actuelles de l'hôte et signale celles qui seraient joignables

**Conteneur** (Ubuntu 24.04)
- `security.nesting` pour Docker, `/dev/net/tun` pour NetBird, limites CPU et mémoire, démarrage automatique
- mises à jour de sécurité automatiques
- Docker (get.docker.com), rotation des logs, nettoyage hebdomadaire du cache de build et des images de plus de 7 jours
- utilisateur Coolify comme dans vps-setup ([doc non-root user](https://coolify.io/docs/core/infrastructure/servers/non-root-user)) : clé Coolify, sudo sans mot de passe, `/data/coolify`. Un compte déjà présent dans le conteneur (système, `ubuntu`) est refusé ; après un changement de nom, l'ancien compte est verrouillé et perd sudo
- SSH par clé uniquement, root interdit, seul l'utilisateur Coolify autorisé (`AllowUsers`)
- NetBird depuis son dépôt apt (empreinte de la clé vérifiée), `netbird up` avec l'URL et la clé de setup, hostname = nom du conteneur
- filtre nftables sur le tunnel `wt0`, rechargé au démarrage (sans lui, NetBird ne démarre pas) : seul Coolify peut joindre le SSH du conteneur, et le conteneur comme ses builds Docker ne joignent que le registry de Coolify par le tunnel (autres ports, autres pairs et routes NetBird bloqués)
- les sorties du conteneur affichées pendant le script (apt, Docker, NetBird) sont débarrassées des caractères de contrôle : un conteneur compromis ne peut pas réécrire l'affichage du terminal

Relancer le script sur un conteneur existant le réutilise : limites, ACL et configuration sont réappliquées. Un conteneur installé par une version précédente (sur le bridge par défaut) est déplacé sur `builderbr0`, puis l'ACL est retirée du bridge par défaut, seulement s'il ne reste plus d'instance dessus.

## Étapes seules

| Commande | Ce qu'elle fait |
|---|---|
| `sudo bash setup.sh netbird` | installe et connecte NetBird dans un conteneur existant (nouvelle clé de setup, autre serveur, nouvelle IP ou nouveau port de registry de Coolify) |
| `sudo bash setup.sh check` | relance les vérifications |

Vérifications : internet joignable, box injoignable depuis le conteneur, SSH de l'hôte injoignable depuis le conteneur, `docker run hello-world`, SSH actif, NetBird connecté, filtre `wt0` en place.

## Tests complets

```bash
sudo bash test.sh [conteneur]
```

50 tests (plus un par adresse supplémentaire de l'hôte, et deux si NetBird est installé), chacun avec un témoin depuis l'hôte pour qu'un échec attendu ne soit pas dû à un service absent :

- internet : HTTPS, DNS par le bridge, DNS UDP direct
- refusés depuis le conteneur, en TCP, UDP et ping : passerelle, IP de l'hôte (LAN et bridge), SSH de l'hôte, chacune des adresses de l'hôte, une adresse NetBird (100.64/10), 172.16/12, un autre sous-réseau 192.168, DNS de la box, IPv6
- la même chose depuis un conteneur Docker lancé dans le builder (c'est là que tournent les builds), plus un `docker build` complet
- entrée refusée : l'hôte ne joint pas le SSH du conteneur
- SSH : clé Coolify acceptée avec sudo et Docker, root refusé avec la même clé, autre utilisateur refusé, mot de passe refusé
- NetBird : `/dev/net/tun`, création d'interfaces TUN et WireGuard, filtre `wt0` chargé et rechargé au démarrage
- conteneur non privilégié (root du conteneur = UID non root sur l'hôte), démarrage automatique, seul conteneur sur son bridge

Le test crée le temps de son exécution une interface factice, deux petits serveurs, une clé SSH et un utilisateur temporaires, et retire tout à la fin.

Validé sur une VM Ubuntu 24.04 neuve (arm64), installation complète puis relance du script sur le conteneur existant : 50/50. Validé aussi en mise à jour depuis la version précédente, avec une adresse non privée sur l'hôte et un autre conteneur sur le bridge par défaut : 51/51, l'hôte et l'autre conteneur sont injoignables. Filtre `wt0` testé avec un faux tunnel et deux faux pairs : seul le registry du pair Coolify est joignable (depuis le conteneur comme depuis Docker), et seul Coolify joint le SSH du conteneur. Un sous-réseau 198.18.3.0/24 routé par l'hôte est bloqué.

## Après le script

La liste complète des vérifications à faire et des limites connues est dans [SECURITY.md](SECURITY.md).

**NetBird**
- supprimer la politique `Default` (tous vers tous) après avoir recréé vos accès homelab
- politique `coolify -> builder`, TCP 22, non bidirectionnelle
- politique `builder -> coolify`, port du registry (le même que celui donné au script)
- aucune route vers le LAN distribuée au groupe `builder`
- vérification depuis le conteneur : `netbird status -d` ne doit lister que Coolify

**Coolify** : Servers > Add, IP NetBird du conteneur, port 22, utilisateur `coolify`, clé générée dans Coolify, cocher "Use it as a build server". Dans chaque application : ce build server et une image dans le registry.

## Commandes utiles

```bash
sudo incus exec builder -- bash                  # shell dans le conteneur
sudo incus exec builder -- netbird status -d     # pairs NetBird visibles
sudo incus network acl show no-lan               # règles d'isolation
sudo incus config set builder limits.memory=12GiB
sudo incus delete -f builder                     # repartir de zéro
```

Ajouter la clé Coolify après coup :

```bash
sudo incus exec builder -- bash -c 'cat >>/home/coolify/.ssh/authorized_keys' <<<'ssh-ed25519 AAAA... coolify'
```

## Limites connues

- Les ACL d'un bridge Incus exigent le pare-feu nftables : le script s'arrête si Incus utilise iptables (cas fréquent quand Docker tourne aussi sur l'hôte).
- Le laptop éteint, les déploiements qui utilisent ce build server échouent. Les applications en ligne continuent de tourner depuis le registry.
- L'hôte lui-même (SSH, pare-feu, Fail2ban) n'est pas durci par ce script : voir [vps-setup](https://github.com/bahaa-mn/vps-setup).
