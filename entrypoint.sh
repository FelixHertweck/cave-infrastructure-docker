#!/bin/bash
set -e

# Source OpenStack credentials if available
# Use 'set -a' to export all variables in the sourced file
if [ -f /.openrc ]; then
    echo "[INFO] Sourcing OpenStack credentials from .openrc..."
    set -a
    source /.openrc
    set +a
fi

# Validate that OS_PASSWORD is set (required for OpenStack CLI)
if [ -z "$OS_PASSWORD" ]; then
    echo "[ERROR] OS_PASSWORD is not set!"
    echo "[ERROR] Make sure to either:"
    echo "[ERROR]   1. Define OS_PASSWORD in .env file, OR"
    echo "[ERROR]   2. Include OS_PASSWORD in .openrc file"
    exit 1
fi

echo "[INFO] OpenStack credentials validated. Ready to proceed."

# Execute the command passed to the container
"$@"
EXIT_CODE=$?

# Print completion status
if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    DEPLOYMENT COMPLETED                    ║"
    echo "║                         ✓ READY                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
else
    echo ""
    echo "✗ Deployment failed with exit code $EXIT_CODE"
    echo ""
fi

exit $EXIT_CODE
