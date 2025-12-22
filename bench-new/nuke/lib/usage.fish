function print_usage
    echo "Usage: nuke.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -f, --force, -y, --yes    Skip confirmation prompts"
    echo "  -h, --help                Show this help"
    echo ""
    echo "Examples:"
    echo "  nuke.fish             Interactive cleanup with confirmations"
    echo "  nuke.fish --force     Destroy everything without prompts"
end
