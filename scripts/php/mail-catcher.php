<?php
// localhost-wp: loaded before every PHP request (php.ini auto_prepend_file).
// Makes sure WordPress mail ends up in the mail catcher (http://localhost:8025)
// and never goes out for real. Scripts that are not WordPress ignore all of it.
//
// WordPress is not loaded yet at this point, so filters go into $wp_filter
// directly; WordPress turns entries found there into normal hooks when it loads.

// 1) SMTP plugins send through their own service (Gmail, SendGrid, Brevo...),
//    past PHP's mail settings. Their own constants switch them to PHP mail;
//    their settings pages then show the mailer as set by a constant, and nothing
//    is saved to the database. Defined here, before wp-config.php, so they win.
foreach (array(
    'WPMS_ON'             => true,     // WP Mail SMTP
    'WPMS_MAILER'         => 'mail',
    'EASY_WP_SMTP_ON'     => true,     // Easy WP SMTP
    'EASY_WP_SMTP_MAILER' => 'mail',
) as $localhost_wp_name => $localhost_wp_value) {
    if (!defined($localhost_wp_name)) {
        define($localhost_wp_name, $localhost_wp_value);
    }
}
unset($localhost_wp_name, $localhost_wp_value);

// 2) Any other plugin that turns WordPress's mailer into SMTP: switched back to
//    PHP mail as the very last step before sending. The mail is also tagged with
//    the site's folder name (Mailpit reads X-Tags), so the dashboard can show
//    each site's own mail.
$GLOBALS['wp_filter']['phpmailer_init'][PHP_INT_MAX][] = array(
    'function'      => static function ($phpmailer) {
        if (!is_object($phpmailer)) {
            return;
        }
        if (method_exists($phpmailer, 'isMail')) {
            $phpmailer->isMail();
        }
        $root = isset($_SERVER['DOCUMENT_ROOT']) ? (string) $_SERVER['DOCUMENT_ROOT'] : '';
        if (method_exists($phpmailer, 'addCustomHeader')
            && preg_match('~[\\\\/]sites[\\\\/]([A-Za-z0-9_-]+)[\\\\/]public[\\\\/]?$~', $root, $m)) {
            $phpmailer->addCustomHeader('X-Tags', $m[1]);
        }
    },
    'accepted_args' => 1,
);

// 3) WordPress sends from wordpress@<site host>. For a site on localhost that is
//    "wordpress@localhost", which WordPress's own address check rejects (no dot
//    in the domain), so the mail would be dropped. This swaps in an address that
//    passes. Addresses a site or plugin sets itself are kept.
$GLOBALS['wp_filter']['wp_mail_from'][10][] = array(
    'function'      => static function ($from) {
        $at     = strrpos((string) $from, '@');
        $domain = $at === false ? '' : substr($from, $at + 1);
        return strpos($domain, '.') === false ? 'wordpress@localhost.test' : $from;
    },
    'accepted_args' => 1,
);
