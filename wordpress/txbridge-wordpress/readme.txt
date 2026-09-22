=== txBridge for WordPress ===
Requires at least: 6.0
Requires PHP: 8.1
Stable tag: 0.1.0
License: MIT

Signed FiveM/txAdmin event inbox, private application client and opt-in public server-status shortcode.
This is a self-hosted integration-test candidate, not an official txAdmin API or a replacement panel.

== Installation ==
Activate the plugin and configure TXBRIDGE_SERVERS in wp-config.php using the examples in the full txBridge project.
Configure the FiveM txbridge resource to send signed HTTPS webhooks to /wp-json/txbridge/v1/webhook.
For private server reads/actions, configure a restricted HTTPS reverse proxy and a matching API client key.
No real credentials are supplied. Never put shared secrets or txAdmin session cookies in frontend JavaScript.

== Public status ==
Explicitly enable public_status for the configured server and use [txbridge_status server="main"].
Tools > txBridge shows the latest observations. Stale telemetry does not prove that a server is offline.

== Data handling ==
Activation creates a site-specific event inbox table. Retention defaults to 30 days with scheduled cleanup.
Data survives deactivation/uninstall unless TXBRIDGE_DELETE_DATA_ON_UNINSTALL is explicitly true.
Source events may be missed while the resource is stopped. Application hooks are not exactly-once transactions.
Read the full project's INSTALLATION, WORDPRESS, SECURITY and TESTING documentation before production use.
