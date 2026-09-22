<?php
// Merge above "That's all, stop editing!" in wp-config.php (do not add a second <?php).
// Define actual secrets securely; these placeholders are NOT usable credentials.
define('TXBRIDGE_SERVERS', [
    'main' => [
        'url' => 'https://bridge.example.com/txbridge',
        'key_id' => 'wordpress',
        'secret' => 'REPLACE_WITH_SAME_API_SECRET_AS_FIVEM',
        'webhook_secret' => 'REPLACE_WITH_SAME_WEBHOOK_SECRET_AS_FIVEM',
        'public_status' => false, // Set true only to publish the limited status widget.
        'label' => 'Example Roleplay',
    ],
]);
define('TXBRIDGE_ALLOW_INTERNAL_PROXY', false);
define('TXBRIDGE_RETENTION_DAYS', 30);
define('TXBRIDGE_DELETE_DATA_ON_UNINSTALL', false);
