#!/usr/bin/env fish
# SSH into a task runner instance via the bastion host
# Usage: ./ssh-task-runner.fish <bastion_ip> <task_runner_ip> [command]
#
# Examples:
#   ./ssh-task-runner.fish 1.2.3.4 10.0.1.50                    # Interactive shell
#   ./ssh-task-runner.fish 1.2.3.4 10.0.1.50 "docker ps"        # Run a command

set -l SCRIPT_DIR (dirname (status --current-filename))

if test (count $argv) -lt 2
    gum style --foreground 196 "Usage: ./ssh-task-runner.fish <bastion_ip> <task_runner_ip> [command]"
    echo ""
    gum style --foreground 245 "Examples:"
    echo "  ./ssh-task-runner.fish 1.2.3.4 10.0.1.50                    # Interactive shell"
    echo "  ./ssh-task-runner.fish 1.2.3.4 10.0.1.50 \"docker ps\"        # Run a command"
    exit 1
end

set -l bastion_ip $argv[1]
set -l task_runner_ip $argv[2]
set -l command $argv[3..-1]

# Try to get key name from terraform, fall back to common names
set -l key_name (terraform -chdir="$SCRIPT_DIR" output -raw key_name 2>/dev/null)
if test -z "$key_name"
    set key_name "railsbencher"
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
    gum style --foreground 196 "Error: Could not find SSH key. Tried:"
    echo "  ~/.ssh/$key_name.pem"
    echo "  ~/.ssh/$key_name"
    echo "  ~/.$key_name.pem"
    exit 1
end

# Build SSH command with ProxyCommand (works reliably)
set -l ssh_opts -i "$key_path" -o StrictHostKeyChecking=no -o ProxyCommand="ssh -i $key_path -o StrictHostKeyChecking=no -W %h:%p ec2-user@$bastion_ip"

if test (count $command) -gt 0
    # Run command
    ssh $ssh_opts ec2-user@$task_runner_ip "sudo $command"
else
    # Interactive shell
    gum style --foreground 212 "Connecting to task runner ($task_runner_ip) via bastion ($bastion_ip)..."
    ssh $ssh_opts ec2-user@$task_runner_ip
end
