#!/bin/bash
# Health check wrapper script for Docker HEALTHCHECK

# Try to access the health check endpoint via HTTP
curl -f -s -H "User-Agent: healthcheck-docker" http://localhost/healthcheck.php > /dev/null 2>&1
exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo "Health check passed"
    exit 0
else
    echo "Health check failed"
    exit 1
fi