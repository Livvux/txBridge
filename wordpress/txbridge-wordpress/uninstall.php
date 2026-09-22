<?php
if (!defined('WP_UNINSTALL_PLUGIN')) { exit; }
wp_clear_scheduled_hook('txbridge_cleanup');
// Preserve inbox unless the operator explicitly opts into destructive removal.
if (defined('TXBRIDGE_DELETE_DATA_ON_UNINSTALL') && TXBRIDGE_DELETE_DATA_ON_UNINSTALL) {
    global $wpdb;
    $wpdb->query('DROP TABLE IF EXISTS ' . $wpdb->prefix . 'txbridge_events');
}
