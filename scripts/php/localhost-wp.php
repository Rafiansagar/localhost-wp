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

// The Stack page's live OPcache numbers: ?__localhost_wp=status (or =opcache-reset)
// on any PHP page, from this PC only. The dashboard asks through phpMyAdmin's
// index.php; anyone else gets the page as usual.
if (isset($_GET['__localhost_wp']) && PHP_SAPI !== 'cli'
    && in_array(isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '', array('127.0.0.1', '::1'), true)) {
    $localhost_wp_ok = function_exists('opcache_get_status');
    if ($_GET['__localhost_wp'] === 'opcache-reset' && $localhost_wp_ok) {
        opcache_reset();
    }
    $localhost_wp_s = $localhost_wp_ok ? @opcache_get_status(false) : false;
    $localhost_wp_c = $localhost_wp_ok ? @opcache_get_configuration() : false;
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    echo json_encode(array(
        'loaded'  => extension_loaded('Zend OPcache'),
        'enabled' => is_array($localhost_wp_s) && !empty($localhost_wp_s['opcache_enabled']),
        'full'    => is_array($localhost_wp_s) && !empty($localhost_wp_s['cache_full']),
        'used'    => is_array($localhost_wp_s) ? $localhost_wp_s['memory_usage']['used_memory'] : 0,
        'wasted'  => is_array($localhost_wp_s) ? $localhost_wp_s['memory_usage']['wasted_memory'] : 0,
        'memory'  => is_array($localhost_wp_c) ? $localhost_wp_c['directives']['opcache.memory_consumption'] : 0,
        'files'   => is_array($localhost_wp_s) ? $localhost_wp_s['opcache_statistics']['num_cached_scripts'] : 0,
        'maxFiles'=> is_array($localhost_wp_s) ? $localhost_wp_s['opcache_statistics']['max_cached_keys'] : 0,
        'hits'    => is_array($localhost_wp_s) ? $localhost_wp_s['opcache_statistics']['hits'] : 0,
        'misses'  => is_array($localhost_wp_s) ? $localhost_wp_s['opcache_statistics']['misses'] : 0,
        'since'   => is_array($localhost_wp_s) ? $localhost_wp_s['opcache_statistics']['start_time'] : 0,
    ));
    exit;
}

$localhost_wp_config = dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . 'config' . DIRECTORY_SEPARATOR;
foreach (array('error-catcher', 'mail-catcher', 'network-catcher') as $localhost_wp_catcher) {
    $localhost_wp_state = $localhost_wp_config . $localhost_wp_catcher . '.txt';
    if (is_file($localhost_wp_state) && strtolower(trim((string) @file_get_contents($localhost_wp_state))) === 'off') {
        continue;
    }
    require __DIR__ . DIRECTORY_SEPARATOR . $localhost_wp_catcher . '.php';
}
unset($localhost_wp_config, $localhost_wp_catcher, $localhost_wp_state);
