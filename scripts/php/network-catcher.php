<?php
// localhost-wp network catcher, loaded by localhost-wp.php before every request.
//
// Records every call a site makes through WordPress's HTTP API (wp_remote_get,
// wp_remote_post, ... which is what plugins, themes and core use) into
// logs\network\<site>.jsonl: host, URL (secrets in the query masked), status
// or error, time taken, size, and the plugin or theme that made it.
//
// It can also block calls, so a page never hangs on a dead or slow server.
// config\network-rules.json (written by the dashboard) says what:
//   mode  "log"   record only (default)
//         "slow"  block the hosts in "auto" (slow or timing out lately)
//         "all"   block every external host
//   block hosts blocked by hand, in every mode
// A blocked call fails at once with a WP_Error, as if the host were offline.
// Local calls (localhost, private addresses, the site itself) are never blocked.
//
// Not seen: code that calls cURL or file_get_contents directly.

if (PHP_SAPI === 'cli' || defined('LOCALHOST_WP_NETWORK_CATCHER')) {
    return;
}
define('LOCALHOST_WP_NETWORK_CATCHER', true);

final class LocalhostWpNetworkCatcher
{
    const ROTATE_AT = 4194304;   // 4 MB: <site>.jsonl becomes <site>.old.jsonl

    public static $site    = '';
    public static $pending = array();   // url => list of started calls (newest last)
    private static $rules  = null;

    private static function base()
    {
        return dirname(__DIR__, 2) . DIRECTORY_SEPARATOR;
    }

    private static function rules()
    {
        if (self::$rules === null) {
            $f = self::base() . 'config' . DIRECTORY_SEPARATOR . 'network-rules.json';
            $r = is_file($f) ? json_decode((string) @file_get_contents($f), true) : null;
            $r = is_array($r) ? $r : array();
            self::$rules = array(
                'mode'  => isset($r['mode']) && in_array($r['mode'], array('log', 'slow', 'all'), true) ? $r['mode'] : 'log',
                'block' => array_map('strtolower', isset($r['block']) && is_array($r['block']) ? $r['block'] : array()),
                'auto'  => array_map('strtolower', isset($r['auto']) && is_array($r['auto']) ? $r['auto'] : array()),
            );
        }
        return self::$rules;
    }

    public static function isLocal($host)
    {
        $host = strtolower(trim((string) $host, '[]'));
        if ($host === '' || $host === 'localhost' || substr($host, -10) === '.localhost' || substr($host, -5) === '.test') {
            return true;
        }
        if (isset($_SERVER['HTTP_HOST']) && $host === strtolower(preg_replace('~:\d+$~', '', (string) $_SERVER['HTTP_HOST']))) {
            return true;
        }
        if (filter_var($host, FILTER_VALIDATE_IP)) {
            return !filter_var($host, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE);
        }
        return false;
    }

    // Values of key=, token=, license= and the like are masked before anything is written.
    public static function maskUrl($url)
    {
        $url = (string) $url;
        $q = strpos($url, '?');
        if ($q === false) {
            return substr($url, 0, 600);
        }
        $parts = explode('&', substr($url, $q + 1));
        foreach ($parts as &$p) {
            $eq = strpos($p, '=');
            if ($eq !== false && preg_match('~(key|token|secret|pass|license|licence|auth|sig|nonce|code|session)~i', urldecode(substr($p, 0, $eq)))) {
                $p = substr($p, 0, $eq) . '=***';
            }
        }
        unset($p);
        return substr(substr($url, 0, $q) . '?' . implode('&', $parts), 0, 600);
    }

    // The plugin or theme closest to the call, else WordPress itself.
    private static function caller()
    {
        foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 40) as $f) {
            if (empty($f['file'])) {
                continue;
            }
            if (preg_match('~[\\\\/]wp-content[\\\\/](plugins|mu-plugins|themes)[\\\\/]([^\\\\/]+)~i', $f['file'], $m)) {
                $kind = strtolower($m[1]) === 'themes' ? 'theme' : 'plugin';
                return $kind . ':' . preg_replace('~\.php$~i', '', $m[2]);
            }
        }
        return 'core';
    }

    // pre_http_request, run last: blocks the call or notes when it started.
    public static function before($preempt, $args, $url)
    {
        if ($preempt !== false) {
            return $preempt;   // another plugin answered it already
        }
        $host  = strtolower((string) parse_url((string) $url, PHP_URL_HOST));
        $local = self::isLocal($host);
        $call  = array(
            'start'  => microtime(true),
            'caller' => self::caller(),
            'host'   => $host,
            'local'  => $local,
            'async'  => isset($args['blocking']) && !$args['blocking'],
            'method' => isset($args['method']) ? strtoupper((string) $args['method']) : 'GET',
        );
        if (!$local) {
            $r = self::rules();
            $why = in_array($host, $r['block'], true) ? 'manual'
                : ($r['mode'] === 'all' ? 'all'
                : ($r['mode'] === 'slow' && in_array($host, $r['auto'], true) ? 'slow' : ''));
            if ($why !== '') {
                self::write($call, $url, array('blocked' => $why, 'ms' => 0, 'error' => 'Blocked by localhost-wp'));
                return new WP_Error('localhost_wp_blocked', sprintf('Blocked by localhost-wp (network catcher): %s', $host));
            }
        }
        self::$pending[(string) $url][] = $call;
        return $preempt;
    }

    // http_api_debug: the call is done.
    public static function after($response, $context, $class, $args, $url)
    {
        $url = (string) $url;
        if ($context !== 'response' || empty(self::$pending[$url])) {
            return;
        }
        $call = array_pop(self::$pending[$url]);
        $out  = array('ms' => (int) round((microtime(true) - $call['start']) * 1000));
        if (is_wp_error($response)) {
            $out['error'] = substr($response->get_error_message(), 0, 300);
        } else {
            $out['code'] = (int) wp_remote_retrieve_response_code($response);
            $len = wp_remote_retrieve_header($response, 'content-length');
            $out['size'] = $len !== '' ? (int) $len : strlen((string) wp_remote_retrieve_body($response));
        }
        self::write($call, $url, $out);
    }

    private static function write($call, $url, $out)
    {
        $line = array_merge(array(
            't'      => time(),
            'method' => $call['method'],
            'url'    => self::maskUrl($url),
            'host'   => $call['host'],
            'caller' => isset($call['caller']) ? $call['caller'] : self::caller(),
        ), $out);
        if ($call['local']) {
            $line['local'] = true;
        }
        if ($call['async']) {
            $line['async'] = true;
        }
        if (isset($_SERVER['REQUEST_URI'])) {
            $line['page'] = substr((string) $_SERVER['REQUEST_URI'], 0, 300);
        }
        $json = json_encode($line, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | (defined('JSON_INVALID_UTF8_SUBSTITUTE') ? JSON_INVALID_UTF8_SUBSTITUTE : 0));
        if ($json === false) {
            return;
        }
        $dir = self::base() . 'logs' . DIRECTORY_SEPARATOR . 'network';
        if (!is_dir($dir)) {
            @mkdir($dir, 0777, true);
        }
        $file = $dir . DIRECTORY_SEPARATOR . self::$site . '.jsonl';
        if (is_file($file) && filesize($file) > self::ROTATE_AT) {
            @rename($file, $dir . DIRECTORY_SEPARATOR . self::$site . '.old.jsonl');
        }
        @file_put_contents($file, $json . "\n", FILE_APPEND | LOCK_EX);
    }
}

// WordPress is not loaded yet: hooks go straight into $wp_filter, which
// WordPress turns into normal hooks when it loads.
$localhost_wp_root = isset($_SERVER['DOCUMENT_ROOT']) ? (string) $_SERVER['DOCUMENT_ROOT'] : '';
if (preg_match('~[\\\\/]sites[\\\\/]([A-Za-z0-9_-]+)[\\\\/]public[\\\\/]?$~', $localhost_wp_root, $localhost_wp_m)) {
    LocalhostWpNetworkCatcher::$site = $localhost_wp_m[1];
    $GLOBALS['wp_filter']['pre_http_request'][PHP_INT_MAX][] = array(
        'function'      => array('LocalhostWpNetworkCatcher', 'before'),
        'accepted_args' => 3,
    );
    $GLOBALS['wp_filter']['http_api_debug'][PHP_INT_MAX][] = array(
        'function'      => array('LocalhostWpNetworkCatcher', 'after'),
        'accepted_args' => 5,
    );
}
unset($localhost_wp_root, $localhost_wp_m);
