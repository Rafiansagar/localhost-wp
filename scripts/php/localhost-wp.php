<?php
// localhost-wp: loaded before every PHP request (php.ini auto_prepend_file).
// Loads the catchers that are on. Each one is switched off by "off" in
// config\<name>.txt (the dashboard writes it). That file is read here on every
// request, so switching needs no PHP restart.
//
//   error-catcher.php    every PHP error a site reports, for the dashboard's Errors page
//   mail-catcher.php     WordPress mail into the local inbox, never out
//   network-catcher.php  the calls a site makes to the internet; can block slow hosts
//
// Mail itself also depends on php.ini's SMTP lines, which ensure-mail.ps1 sets.

$localhost_wp_config = dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . 'config' . DIRECTORY_SEPARATOR;
foreach (array('error-catcher', 'mail-catcher', 'network-catcher') as $localhost_wp_catcher) {
    $localhost_wp_state = $localhost_wp_config . $localhost_wp_catcher . '.txt';
    if (is_file($localhost_wp_state) && strtolower(trim((string) @file_get_contents($localhost_wp_state))) === 'off') {
        continue;
    }
    require __DIR__ . DIRECTORY_SEPARATOR . $localhost_wp_catcher . '.php';
}
unset($localhost_wp_config, $localhost_wp_catcher, $localhost_wp_state);
