#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                 CAVE Infrastructure Menu                   ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

main() {
    print_header
    
    echo -e "What would you like to do?"
    echo -e "  ${YELLOW}1)${NC} Deploy Infrastructure (deploy-wrapper.sh)"
    echo -e "  ${YELLOW}2)${NC} Build Base Images (build-images.sh)"
    echo -e "  ${YELLOW}3)${NC} Destroy Infrastructure (exterminate.sh)"
    echo -e "  ${YELLOW}Q)${NC} Quit"
    echo ""
    
    read -p "Select an action [1-3, Q]: " choice
    echo ""

    case "$choice" in
        1)
            exec /cave/deploy-wrapper.sh
            ;;
        2)
            exec /cave/build-images.sh
            ;;
        3)
            # Find possible lab prefixes if possible
            default_prefix="${LAB_PREFIX:-}"
            if [ -n "$default_prefix" ]; then
                read -p "Enter Lab Prefix to destroy [$default_prefix]: " prefix
                prefix="${prefix:-$default_prefix}"
            else
                read -p "Enter Lab Prefix to destroy: " prefix
            fi
            
            if [ -n "$prefix" ]; then
                exec /cave/backend/exterminate.sh "$prefix"
            else
                echo -e "${RED}Error: Lab prefix cannot be empty.${NC}"
                exit 1
            fi
            ;;
        q|Q)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid selection.${NC}"
            exit 1
            ;;
    esac
}

main "$@"