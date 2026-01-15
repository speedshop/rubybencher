#!/usr/bin/env bash
# Load secrets from fnox/1Password into environment
# This script is sourced by mise via _.source directive

eval "$(fnox export --format=env --no-color)"
