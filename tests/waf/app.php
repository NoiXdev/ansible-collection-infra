<?php
// The front controller of the host scenario's app and secure sites
// (tests/waf/run.sh): one line per request in the pool's log
// (/var/log/php/app.log), so the suite sees which requests reached PHP, and
// the client address and the scheme and port PHP was given, or a streamed
// answer on /stream.
error_log('noix-app ' . ($_SERVER['REQUEST_URI'] ?? ''));
// /stream: a streamed answer, the first line at once and the second after
// 4 s; X-Accel-Buffering: no keeps nginx from buffering it.
if (str_starts_with($_SERVER['REQUEST_URI'] ?? '', '/stream')) {
    header('X-Accel-Buffering: no');
    while (ob_get_level() > 0) {
        ob_end_flush();
    }
    echo "first\n";
    flush();
    sleep(4);
    echo "second\n";
    exit;
}
echo json_encode([
    'remote_addr' => $_SERVER['REMOTE_ADDR'] ?? '',
    'https' => $_SERVER['HTTPS'] ?? '',
    'server_port' => $_SERVER['SERVER_PORT'] ?? '',
]), "\n";
