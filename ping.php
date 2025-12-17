<?php
/**
 * Simple Ping Endpoint for Container Health Checks
 * Provides a lightweight HTTP endpoint for basic health verification
 */

// Set content type
header('Content-Type: application/json');

// Simple response with timestamp
$response = [
    'status' => 'ok',
    'timestamp' => date('c'),
    'service' => 'matomo'
];

http_response_code(200);
echo json_encode($response);
exit();