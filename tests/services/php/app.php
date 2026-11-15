<?php
// What a pool sees of itself, for tests/services/php/verify.yml.
echo json_encode([
    'version' => PHP_VERSION,
    'user' => posix_getpwuid(posix_geteuid())['name'],
    'app_env' => getenv('APP_ENV'),
    'note' => getenv('NOTE'),
    'open_basedir' => ini_get('open_basedir'),
    'memory_limit' => ini_get('memory_limit'),
    'session_save_path' => session_save_path(),
    'upload_tmp_dir' => ini_get('upload_tmp_dir'),
    'sys_temp_dir' => sys_get_temp_dir(),
    'error_reporting' => ini_get('error_reporting'),
    'extensions' => array_map('strtolower', get_loaded_extensions()),
]), "\n";
