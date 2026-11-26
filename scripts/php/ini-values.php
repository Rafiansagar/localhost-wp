<?php
// localhost-wp: prints php.ini's values for the Stack page's PHP & MySQL card
// (run by scripts\helper\tuning.ps1 with php.exe, never through a website).
// get_cfg_var() reads php.ini itself, and unset lines fall back to PHP's
// defaults (OPcache's: 128 MB and 10,000 files). max_execution_time is 0 on the
// command line however it's read, so tuning.ps1 takes that one from php.ini's text.
if (PHP_SAPI !== 'cli') {
    return;
}
function localhost_wp_cfg($name, $default)
{
    $v = get_cfg_var($name);
    return $v === false || $v === '' ? $default : $v;
}
$opcache = extension_loaded('Zend OPcache');
echo json_encode(array(
    'opcache'       => $opcache && (bool) localhost_wp_cfg('opcache.enable', '1'),
    'opcacheMemory' => (int) localhost_wp_cfg('opcache.memory_consumption', 128),
    'opcacheFiles'  => (int) localhost_wp_cfg('opcache.max_accelerated_files', 10000),
    'memoryLimit'   => (string) localhost_wp_cfg('memory_limit', '128M'),
    'uploadMax'     => (string) localhost_wp_cfg('upload_max_filesize', '2M'),
    'postMax'       => (string) localhost_wp_cfg('post_max_size', '8M'),
    'maxExecution'  => (int) localhost_wp_cfg('max_execution_time', 30),
));
