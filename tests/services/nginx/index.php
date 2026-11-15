<?php
// The prod site's front controller, for tests/services/nginx/verify.yml.
// /app-404 answers the app's own 404, which nginx passes through.
if (str_starts_with($_SERVER['REQUEST_URI'] ?? '', '/app-404')) {
    http_response_code(404);
}
echo json_encode([
    'script' => 'index.php',
    'user' => posix_getpwuid(posix_geteuid())['name'],
    'uri' => $_SERVER['REQUEST_URI'] ?? '',
    'https' => $_SERVER['HTTPS'] ?? '',
    'body' => strlen(file_get_contents('php://input')),
]), "\n";
