27/10/2026 0:00–0:30
Créer le projet GitLab avec les dossiers infra/ app/ k8s/ policies/ vault/ falco/ mcp/ docs/, le README et docs/journal.md. Miroir vers GitHub : repo GitHub vide (sans README ni licence), token à granularité fine limité à ce repo (Contents en lecture et écriture, avec expiration), puis Settings > Repository > Mirroring repositories en Push. Cocher « Mirror only protected branches » pour que la branche demo de la DJ3 reste sur GitLab. En haut du README : « Miroir. Le projet et la CI vivent sur GitLab. »
chore: structure du repo, README et journal

27/10 4h 
Sur le Pi (OS 64 bits) : Docker, gitlab-runner en executor Docker, tag rpi, concurrent = 1. Créer le runner depuis l'interface du projet GitLab et ne jamais committer son token. Activer l'émulation amd64 avec l'image tonistiigi/binfmt. 
Attention risque : un runner qui accède au socket Docker équivaut à root sur le Pi > acceptable pour un lab 
Attention le piège au moment de faire register sur la PI pour register un nouveau runner qui va aller taper sur gitlab pour chercher des jobs, je l'ai pas fait avec sudo la première fois et du coup le fichier de conf c'est créé dans mon home et pas dans /etc/... runner machin. On a donc bien refait le register en sudo