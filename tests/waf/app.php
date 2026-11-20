<?php
// The front controller of the host scenario's app and secure sites
// (tests/waf/run.sh): one line per request in the pool's log
// (/var/log/php/app.log), so the suite sees which requests reached PHP, and
// the client address and the scheme and port PHP was given.
error_log('noix-app ' . ($_SERVER['REQUEST_URI'] ?? ''));
echo json_encode([
    'remote_addr' => $_SERVER['REMOTE_ADDR'] ?? '',
    'https' => $_SERVER['HTTPS'] ?? '',
    'server_port' => $_SERVER['SERVER_PORT'] ?? '',
]), "\n";
