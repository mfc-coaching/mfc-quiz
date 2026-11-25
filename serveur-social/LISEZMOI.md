# Serveur des défis (Supabase)

Classements, amis, duels et Course au sommet.

- `schema.sql` : à coller une fois dans Supabase (SQL Editor > New query > Run). Relançable sans risque.
- Dans Supabase : Authentication > Sign In / Providers > activer **Allow anonymous sign-ins**.
- `social-block.js` : le code de l'app, inséré dans `index.html` par `python3 build.py`.

Semaine de jeu : du dimanche 20 h au dimanche 20 h (heure de Paris). L'XP totale n'est jamais remise à zéro ;
seul le compteur de la semaine repart à zéro. Ne jamais publier la clé « secret » / « service_role ».

## Modération
- Signalements : Supabase > Table Editor > `mfc_reports` (qui, quel pseudo, quelle raison).
- Suspendre un joueur : Table Editor > `mfc_profiles` > colonne `banned` = true. Il disparaît des classements et ne peut plus jouer aux Défis.
- `schema-2-moderation.sql` : mise à jour à coller une fois après `schema.sql` (blocage, signalement, suppression de compte).

## App iOS
- `.github/workflows/ios.yml` construit l'app sur un Mac de GitHub à chaque modification (contrôle).
- Envoi sur TestFlight : Actions > App iOS > Run workflow > cocher « testflight » (après avoir ajouté les secrets ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, APPLE_TEAM_ID).

## MFC Coaching : sauvegarde en ligne
- `schema-4-coaching.sql` : à coller une fois (SQL Editor > New query > Run). Crée les comptes coaching avec code de récupération.
- Utilise la connexion anonyme déjà activée pour les Défis. Rien d'autre à régler.
- Comptes : Table Editor > `mfc_coach_accounts` (prénom, code, date de dernière synchro).
- `schema-5-coach.sql` : espace coach. À coller après le 4, en remplaçant `TON-CODE` (dernière ligne) par le code de récupération du compte coach.
- Retirer le rôle coach : Table Editor > `mfc_coach_accounts` > colonne `is_coach` = false.

## MFC Coaching : notifications
1. Edge Functions > Deploy a new function > Via Editor : nom `mfc-push`, coller `edge-mfc-push/index.ts`, Deploy, puis désactiver « Verify JWT » dans les réglages de la fonction.
2. Coller `schema-6-notifications.sql` dans le SQL Editor (active pg_cron + pg_net et programme l'envoi chaque minute).
- Les clés VAPID sont créées automatiquement (table `mfc_push_keys`). Ne jamais publier la colonne `priv`.
- File d'envoi : Table Editor > `mfc_push_queue` ; abonnés : `mfc_push_subs`.
