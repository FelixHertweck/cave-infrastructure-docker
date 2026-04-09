#!/bin/bash
set -e

# Source OpenStack credentials if available
if [ -f /.openrc ]; then
    source /.openrc
fi

# Execute the command passed to the container
exec "$@"
