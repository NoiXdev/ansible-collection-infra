<?php
// The prod site's front controller, for tests/services/nginx/verify.yml.
echo json_encode([
    'script' => 'index.php',
    'user' => posix_getpwuid(posix_geteuid())['name'],
    'uri' => $_SERVER['REQUEST_URI'] ?? '',
    'https' => $_SERVER['HTTPS'] ?? '',
]), "\n";
