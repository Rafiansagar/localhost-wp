<?php
// localhost-wp error catcher, loaded by localhost-wp.php before every request.
//
// Records the PHP errors a site's requests report into logs\errors\<site>.jsonl,
// one JSON line per distinct error per request (repeats in the same request are
// counted, not repeated). The dashboard groups them across requests.
//
// It only watches: PHP's own handling goes on unchanged (the handler returns
// false), so debug.log, display_errors and WordPress's fatal error page behave
// exactly as before. It records what PHP reports, i.e. what error_reporting
// allows (with WP_DEBUG off WordPress leaves out notices and deprecations), and
// nothing silenced with @.
//
// Only requests to a site (document root sites\<name>\public) are recorded.

// A constant, not class_exists(): PHP declares a top-level class before the
// file runs, so class_exists() would already be true on the first load.
if (PHP_SAPI === 'cli' || defined('LOCALHOST_WP_ERROR_CATCHER')) {
    return;
}
define('LOCALHOST_WP_ERROR_CATCHER', true);

final class LocalhostWpErrorCatcher
{
    const MAX_PER_REQUEST = 200;          // distinct errors kept from one request
    const ROTATE_AT       = 4194304;      // 4 MB: <site>.jsonl becomes <site>.old.jsonl
    const FATAL           = 85;           // E_ERROR | E_PARSE | E_CORE_ERROR | E_COMPILE_ERROR: never reach a handler

    public static $site  = '';
    public static $items = array();

    public static function handle($type, $message, $file = '', $line = 0)
    {
        if (error_reporting() & $type) {
            self::add((int) $type, (string) $message, (string) $file, (int) $line);
        }
        return false;   // PHP's own logging and display go on as usual
    }

    public static function add($type, $message, $file, $line)
    {
        $key = $type . '|' . $file . '|' . $line . '|' . $message;
        if (isset(self::$items[$key])) {
            self::$items[$key]['n']++;
            return;
        }
        if (count(self::$items) >= self::MAX_PER_REQUEST) {
            return;
        }
        // Uncaught exceptions carry their stack trace in the message.
        $trace = '';
        $at = strpos($message, "\nStack trace:");
        if ($at !== false) {
            $trace   = substr($message, $at + 1, 6000);
            $message = substr($message, 0, $at);
        }
        $item = array(
            't'    => time(),
            'type' => $type,
            'msg'  => substr($message, 0, 2000),
            'file' => $file,
            'line' => $line,
            'n'    => 1,
        );
        if ($trace !== '') {
            $item['trace'] = $trace;
        }
        self::$items[$key] = $item;
    }

    public static function shutdown()
    {
        $last = error_get_last();
        if ($last && ($last['type'] & self::FATAL)) {
            self::add((int) $last['type'], (string) $last['message'], (string) $last['file'], (int) $last['line']);
        }
        if (!self::$items) {
            return;
        }
        $url    = isset($_SERVER['REQUEST_URI']) ? substr((string) $_SERVER['REQUEST_URI'], 0, 400) : '';
        $method = isset($_SERVER['REQUEST_METHOD']) ? (string) $_SERVER['REQUEST_METHOD'] : '';
        $flags  = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | (defined('JSON_INVALID_UTF8_SUBSTITUTE') ? JSON_INVALID_UTF8_SUBSTITUTE : 0);
        $out    = '';
        foreach (self::$items as $item) {
            $item['url']    = $url;
            $item['method'] = $method;
            $json = json_encode($item, $flags);
            if ($json !== false) {
                $out .= $json . "\n";
            }
        }
        $dir = dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . 'logs' . DIRECTORY_SEPARATOR . 'errors';
        if (!is_dir($dir)) {
            @mkdir($dir, 0777, true);
        }
        $file = $dir . DIRECTORY_SEPARATOR . self::$site . '.jsonl';
        if (is_file($file) && filesize($file) > self::ROTATE_AT) {
            @rename($file, $dir . DIRECTORY_SEPARATOR . self::$site . '.old.jsonl');
        }
        @file_put_contents($file, $out, FILE_APPEND | LOCK_EX);
    }
}

$localhost_wp_root = isset($_SERVER['DOCUMENT_ROOT']) ? (string) $_SERVER['DOCUMENT_ROOT'] : '';
if (preg_match('~[\\\\/]sites[\\\\/]([A-Za-z0-9_-]+)[\\\\/]public[\\\\/]?$~', $localhost_wp_root, $localhost_wp_m)) {
    LocalhostWpErrorCatcher::$site = $localhost_wp_m[1];
    set_error_handler(array('LocalhostWpErrorCatcher', 'handle'));
    register_shutdown_function(array('LocalhostWpErrorCatcher', 'shutdown'));
}
unset($localhost_wp_root, $localhost_wp_m);
