<?php
$uri = urldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
$file = __DIR__ . '/' . $uri;

if ($uri && $uri !== '/' && file_exists($file) && is_file($file)) {
    return false;
}

$routes = [
    '/' => 'index.html',
    '/schedy.html' => 'schedy.html',
];

if (isset($routes[$uri])) {
    $path = __DIR__ . '/' . $routes[$uri];
    if (file_exists($path)) {
        $ext = pathinfo($path, PATHINFO_EXTENSION);
        $types = [
            'html' => 'text/html',
            'css' => 'text/css',
            'js' => 'application/javascript',
            'json' => 'application/json',
            'png' => 'image/png',
            'jpg' => 'image/jpeg',
            'ico' => 'image/x-icon',
            'svg' => 'image/svg+xml',
        ];
        header('Content-Type: ' . ($types[$ext] ?? 'application/octet-stream'));
        readfile($path);
        return true;
    }
}

http_response_code(404);
echo 'Not found';
