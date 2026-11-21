<?php
// The front controller of the nginx and waf scenarios' sites
// (tests/varnish/run.sh). One line per request in the pool's log
// (/var/log/php/<pool>.log), so the suite sees which requests reached PHP.
// The answer counts the requests for its URL (a file per URL in the site's
// var/), and shows the client address, HTTPS and whether the front key
// header reached PHP. It is cacheable for 60 s, for max_age=<n> seconds, or
// private with private=1.
error_log('noix-varnish ' . ($_SERVER['REQUEST_URI'] ?? ''));
$file = __DIR__ . '/var/' . md5($_SERVER['REQUEST_URI'] ?? '');
$handle = fopen($file, 'c+');
flock($handle, LOCK_EX);
$count = (int) stream_get_contents($handle) + 1;
ftruncate($handle, 0);
rewind($handle);
fwrite($handle, (string) $count);
flock($handle, LOCK_UN);
fclose($handle);
if (isset($_GET['private'])) {
    header('Cache-Control: private');
} else {
    header('Cache-Control: public, max-age=' . (int) ($_GET['max_age'] ?? 60));
}
printf(
    "count=%d remote_addr=%s https=%s front=%s\n",
    $count,
    $_SERVER['REMOTE_ADDR'] ?? '',
    $_SERVER['HTTPS'] ?? '',
    array_key_exists('HTTP_X_NOIX_FRONT', $_SERVER) || getenv('HTTP_X_NOIX_FRONT') !== false ? 'set' : 'unset'
);
