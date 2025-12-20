#!/usr/bin/env fish
# SSH into the orchestrator instance via the bastion host
# Usage: ./ssh-orchestrator.fish [command]
#
# Examples:
#   ./ssh-orchestrator.fish                    # Interactive shell
#   ./ssh-orchestrator.fish "docker ps"        # Run a command
#   ./ssh-orchestrator.fish "docker logs -f orchestrator-orchestrator-1"

set -l SCRIPT_DIR (dirname (status --current-filename))

# Get connection info from terraform
set -l bastion_ip (terraform -chdir="$SCRIPT_DIR" output -raw bastion_public_ip 2>/dev/null)
set -l orchestrator_ip (terraform -chdir="$SCRIPT_DIR" output -raw orchestrator_public_ip 2>/dev/null)
set -l key_name (terraform -chdir="$SCRIPT_DIR" output -raw key_name 2>/dev/null)

if test -z "$bastion_ip" -o -z "$orchestrator_ip"
    echo "Error: Could not get connection info from terraform."
    echo "Make sure terraform has been applied."
    exit 1
end

# Try common key locations
set -l key_path ""
for path in ~/.ssh/$key_name.pem ~/.ssh/$key_name ~/.$key_name.pem
    if test -f "$path"
        set key_path "$path"
        break
    end
end

if test -z "$key_path"
    echo "Error: Could not find SSH key. Tried:"
    echo "  ~/.ssh/$key_name.pem"
    echo "  ~/.ssh/$key_name"
    echo "  ~/.$key_name.pem"
    exit 1
end

# Build SSH command with ProxyCommand (works reliably)
set -l ssh_opts -i "$key_path" -o StrictHostKeyChecking=no -o ProxyCommand="ssh -i $key_path -o StrictHostKeyChecking=no -W %h:%p ec2-user@$bastion_ip"

if test (count $argv) -gt 0
    # Run command
    ssh $ssh_opts ec2-user@$orchestrator_ip "sudo $argv"
else
    # Interactive shell
    echo "Connecting to orchestrator ($orchestrator_ip) via bastion ($bastion_ip)..."
    ssh $ssh_opts ec2-user@$orchestrator_ip
end
