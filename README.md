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
- clé publique Coolify (optionnelle, ajoutable plus tard)
- NetBird (optionnel) : URL du serveur et clé de setup, saisie masquée
- ajout de l'utilisateur au groupe `incus-admin` (optionnel, équivalent root)
- sur un laptop (batterie détectée) : pas de mise en veille, capot fermé compris

## Ce qu'il fait

**Hôte**
- installe Incus (`apt`) et l'initialise (`incus admin init --minimal`) s'il ne l'est pas déjà
- coupe l'IPv6 sur le bridge Incus, pour n'avoir qu'une famille d'adresses à filtrer
- pose l'ACL `no-lan` sur le bridge : rejet de `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` (NetBird, Tailscale) et `169.254.0.0/16`, tout le reste autorisé vers internet. L'IP de l'hôte sur le bridge est dans ces plages : le conteneur ne joint pas l'hôte. Incus laisse passer DHCP et DNS vers le bridge
- si UFW est actif : autorise le trafic du bridge (le filtrage reste fait par l'ACL)

**Conteneur** (Ubuntu 24.04)
- `security.nesting` pour Docker, `/dev/net/tun` pour NetBird, limites CPU et mémoire, démarrage automatique
- mises à jour de sécurité automatiques
- Docker (get.docker.com), rotation des logs, nettoyage hebdomadaire du cache de build et des images de plus de 7 jours
- SSH par clé uniquement, seul root autorisé. Le root d'un conteneur non privilégié n'a aucun droit sur l'hôte
- NetBird : `netbird up` avec l'URL et la clé de setup, hostname = nom du conteneur

Relancer le script sur un conteneur existant le réutilise : limites, ACL et configuration sont réappliquées.

## Étapes seules

| Commande | Ce qu'elle fait |
|---|---|
| `sudo bash setup.sh netbird` | installe et connecte NetBird dans un conteneur existant (nouvelle clé de setup, autre serveur) |
| `sudo bash setup.sh check` | relance les vérifications |

Vérifications : internet joignable, box injoignable depuis le conteneur, SSH de l'hôte injoignable depuis le conteneur, `docker run hello-world`, SSH actif, NetBird connecté.

## Après le script

**NetBird**
- supprimer la politique `Default` (tous vers tous) après avoir recréé vos accès homelab
- politique `coolify -> builder`, TCP 22, non bidirectionnelle
- politique `builder -> coolify`, port du registry
- aucune route vers le LAN distribuée au groupe `builder`
- vérification depuis le conteneur : `netbird status -d` ne doit lister que Coolify

**Coolify** : Servers > Add, IP NetBird du conteneur, port 22, utilisateur `root`, clé générée dans Coolify, cocher "Use it as a build server". Dans chaque application : ce build server et une image dans le registry.

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
sudo incus exec builder -- bash -c 'cat >>/root/.ssh/authorized_keys' <<<'ssh-ed25519 AAAA... coolify'
```

## Limites connues

- Les ACL d'un bridge Incus exigent le pare-feu nftables : le script s'arrête si Incus utilise iptables (cas fréquent quand Docker tourne aussi sur l'hôte).
- Docker dans un conteneur Incus peut buter sur AppArmor selon les versions (`permission denied` au lancement d'un conteneur) : la vérification `hello-world` le signale.
- Le laptop éteint, les déploiements qui utilisent ce build server échouent. Les applications en ligne continuent de tourner depuis le registry.
- L'hôte lui-même (SSH, pare-feu, Fail2ban) n'est pas durci par ce script : voir [vps-setup](https://github.com/bahaa-mn/vps-setup).
