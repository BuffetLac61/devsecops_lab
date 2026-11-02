### Script pour reconfigurer rapidement vault
Comme vault est en mode dev à chaque redémarrage on perd la configuration 
Donc on peut exécuter ce script pour exécuter à travers un exec sur le pods vault les commandes de config
Les commandes permettent d'activer l'authent à vault par les autres pods via token
et indique à vault l'api kubernetes par défaut

