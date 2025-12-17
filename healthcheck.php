<?php
/**
 * Health Check Endpoint for Matomo Container
 * Provides lightweight health status verification for container orchestration
 */

// Allow access from Docker health checks and internal requests
$allowed_access = (
    php_sapi_name() === 'cli' || 
    (isset($_SERVER['HTTP_USER_AGENT']) && strpos($_SERVER['HTTP_USER_AGENT'], 'healthcheck') !== false) ||
    (isset($_SERVER['REMOTE_ADDR']) && $_SERVER['REMOTE_ADDR'] === '127.0.0.1') ||
    !isset($_SERVER['HTTP_USER_AGENT'])
);

if (!$allowed_access) {
    http_response_code(403);
    exit('Access denied');
}

// Set content type for HTTP responses
if (php_sapi_name() !== 'cli') {
    header('Content-Type: application/json');
}

$health_status = [
    'status' => 'healthy',
    'timestamp' => date('c'),
    'checks' => []
];

$overall_healthy = true;

/**
 * Check database connectivity
 */
function check_database() {
    $host = getenv('MATOMO_DATABASE_HOST') ?: 'mariadb';
    $user = getenv('MATOMO_DATABASE_USERNAME') ?: 'user';
    $pass = getenv('MATOMO_DATABASE_PASSWORD') ?: 'password';
    $name = getenv('MATOMO_DATABASE_DBNAME') ?: 'matomo';
    
    try {
        $start_time = microtime(true);
        $mysqli = new mysqli($host, $user, $pass, $name);
        
        if ($mysqli->connect_errno) {
            return [
                'name' => 'database',
                'status' => 'unhealthy',
                'message' => 'Connection failed: ' . $mysqli->connect_error,
                'response_time_ms' => round((microtime(true) - $start_time) * 1000, 2)
            ];
        }
        
        // Test a simple query
        $result = $mysqli->query('SELECT 1');
        if (!$result) {
            $mysqli->close();
            return [
                'name' => 'database',
                'status' => 'unhealthy',
                'message' => 'Query failed: ' . $mysqli->error,
                'response_time_ms' => round((microtime(true) - $start_time) * 1000, 2)
            ];
        }
        
        $response_time = round((microtime(true) - $start_time) * 1000, 2);
        $mysqli->close();
        
        return [
            'name' => 'database',
            'status' => 'healthy',
            'message' => 'Connected successfully',
            'response_time_ms' => $response_time
        ];
        
    } catch (Exception $e) {
        return [
            'name' => 'database',
            'status' => 'unhealthy',
            'message' => 'Exception: ' . $e->getMessage(),
            'response_time_ms' => round((microtime(true) - $start_time) * 1000, 2)
        ];
    }
}

/**
 * Check Apache process status
 */
function check_apache() {
    // Check if Apache processes are running
    $apache_processes = shell_exec('pgrep -f apache2 2>/dev/null | wc -l');
    $process_count = intval(trim($apache_processes));
    
    if ($process_count === 0) {
        return [
            'name' => 'apache',
            'status' => 'unhealthy',
            'message' => 'No Apache processes found',
            'process_count' => $process_count
        ];
    }
    
    // Check if Apache is responding to requests
    $start_time = microtime(true);
    $context = stream_context_create([
        'http' => [
            'timeout' => 3,
            'user_agent' => 'healthcheck-internal'
        ]
    ]);
    
    // Try to make a simple HTTP request to localhost
    $response = @file_get_contents('http://localhost/', false, $context);
    $response_time = round((microtime(true) - $start_time) * 1000, 2);
    
    if ($response === false) {
        return [
            'name' => 'apache',
            'status' => 'unhealthy',
            'message' => 'Apache not responding to HTTP requests',
            'process_count' => $process_count,
            'response_time_ms' => $response_time
        ];
    }
    
    return [
        'name' => 'apache',
        'status' => 'healthy',
        'message' => 'Apache responding normally',
        'process_count' => $process_count,
        'response_time_ms' => $response_time
    ];
}

/**
 * Check container readiness
 */
function check_readiness() {
    // Check if container initialization is complete
    if (!file_exists('/tmp/container_ready')) {
        return [
            'name' => 'readiness',
            'status' => 'unhealthy',
            'message' => 'Container initialization not complete'
        ];
    }
    
    return [
        'name' => 'readiness',
        'status' => 'healthy',
        'message' => 'Container initialization complete'
    ];
}

/**
 * Check file system access
 */
function check_filesystem() {
    $critical_dirs = [
        '/var/www/html/config',
        '/var/www/html/tmp',
        '/var/www/html/tmp/cache'
    ];
    
    $issues = [];
    
    foreach ($critical_dirs as $dir) {
        if (!is_dir($dir)) {
            $issues[] = "Directory missing: $dir";
            continue;
        }
        
        if (!is_writable($dir)) {
            $issues[] = "Directory not writable: $dir";
            continue;
        }
        
        // Test file creation
        $test_file = $dir . '/.healthcheck_test_' . uniqid();
        if (!@touch($test_file)) {
            $issues[] = "Cannot create files in: $dir";
            continue;
        }
        
        // Clean up test file
        @unlink($test_file);
    }
    
    if (!empty($issues)) {
        return [
            'name' => 'filesystem',
            'status' => 'unhealthy',
            'message' => 'File system issues detected',
            'issues' => $issues
        ];
    }
    
    return [
        'name' => 'filesystem',
        'status' => 'healthy',
        'message' => 'All critical directories accessible',
        'checked_directories' => count($critical_dirs)
    ];
}

// Perform all health checks
$health_status['checks'][] = check_readiness();
$health_status['checks'][] = check_database();
$health_status['checks'][] = check_apache();
$health_status['checks'][] = check_filesystem();

// Determine overall health status
foreach ($health_status['checks'] as $check) {
    if ($check['status'] !== 'healthy') {
        $overall_healthy = false;
        break;
    }
}

$health_status['status'] = $overall_healthy ? 'healthy' : 'unhealthy';

// Output results
if (php_sapi_name() === 'cli') {
    // CLI output
    echo json_encode($health_status, JSON_PRETTY_PRINT) . "\n";
    exit($overall_healthy ? 0 : 1);
} else {
    // HTTP response
    http_response_code($overall_healthy ? 200 : 503);
    echo json_encode($health_status);
    exit();
}