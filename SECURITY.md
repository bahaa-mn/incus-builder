# Sécurité : incus-builder

Ce document dit ce que le script protège, ce qu'il ne peut pas faire à votre place, et les limites connues.

## Ce qui est protégé

Le code des builds (Dockerfile, dépendances téléchargées) est considéré comme non fiable. S'il prend le contrôle du conteneur, il ne doit pas pouvoir atteindre :

| Cible | Protection | Vérifiée par |
|---|---|---|
| L'hôte | conteneur non privilégié (root du conteneur = UID non root sur l'hôte) | `test.sh` |
| Le réseau local | ACL `no-lan` : plages privées, multicast, broadcast et **toutes les adresses de l'hôte** rejetées | `test.sh`, `setup.sh check` |
| Les autres conteneurs de l'hôte | bridge dédié `builderbr0`, aucune autre instance dessus | `test.sh` |
| Les autres pairs NetBird et les routes NetBird | filtre nftables sur `wt0` dans le conteneur : entrée limitée au SSH de Coolify, sortie limitée à Coolify | `test.sh`, `setup.sh check` |
| Le shell root de l'opérateur | les valeurs lues dans le conteneur (utilisateur, IP NetBird) sont revalidées avant d'être affichées | relecture de code |

Les paquets Incus (Zabbly) et NetBird viennent de leurs dépôts apt, avec une clé dont l'empreinte est inscrite dans le script.

## À faire de votre côté

Le script ne peut pas vérifier ces points : ils dépendent de comptes et de réglages hors de la machine.

**NetBird** (tableau de bord)
- [ ] supprimer la politique `Default` (tous vers tous), après avoir recréé vos autres accès
- [ ] clé de setup à usage unique, expiration courte, qui n'attribue que le groupe `builder`
- [ ] politique `coolify -> builder`, TCP 22, non bidirectionnelle
- [ ] politique `builder -> coolify`, port du registry uniquement
- [ ] aucune route réseau distribuée au groupe `builder`
- [ ] depuis le conteneur, `netbird status -d` ne liste que Coolify

Le filtre `wt0` du conteneur bloque déjà les autres pairs. Les politiques NetBird sont la seconde barrière, et la seule qui protège si le conteneur est compromis en root (il peut retirer son propre filtre).

**Hôte**
- [ ] durcir l'hôte lui-même (SSH, pare-feu, mises à jour) : voir [vps-setup](https://github.com/bahaa-mn/vps-setup)
- [ ] après un changement d'adresse de l'hôte (nouvelle IP publique, nouvelle interface), relancer `sudo bash setup.sh` : l'ACL contient les adresses présentes lors de l'installation. `setup.sh check` signale une adresse joignable
- [ ] si l'IP NetBird de Coolify change, relancer `sudo bash setup.sh netbird`
- [ ] ne pas ajouter d'utilisateur au groupe `incus-admin` sans raison : c'est un accès root à l'hôte
- [ ] lancer `test.sh` depuis un dossier où vous seul pouvez écrire (le dossier personnel, pas `/tmp`)

**Coolify**
- [ ] clé SSH générée dans Coolify, sans passphrase, propre à ce serveur

## Limites connues

- **Docker est installé par `get.docker.com`**, sans épinglage de clé : on fait confiance au serveur de Docker au moment de l'installation.
- **Root dans le conteneur peut défaire le filtre `wt0`**. Le filtre protège contre un processus de build non root et contre une erreur de politique NetBird, pas contre une compromission complète du conteneur : les politiques NetBird restent nécessaires.
- **L'utilisateur Coolify a sudo sans mot de passe** dans le conteneur, comme l'exige Coolify. Quiconque a la clé Coolify est root dans le conteneur, mais pas sur l'hôte.
- **Nom de l'utilisateur Coolify** : un compte déjà présent dans le conteneur et non créé par le script (système ou `ubuntu`) est refusé. Après un changement de nom, l'ancien compte est verrouillé et perd sudo.
- **Laptop éteint** : les déploiements qui utilisent ce build server échouent ; les applications déjà déployées continuent de tourner.

## Audits

- Octobre 2026, premier passage (profil standard) : une faille confirmée (valeur du conteneur dans une commande à coller), corrigée ; cinq pistes vérifiées sur VM, corrigées.

## Signaler une faille

Par un avis de sécurité privé sur GitHub (onglet Security du dépôt), pas par une issue publique.
