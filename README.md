# Azure Update Manager - Patch Dashboard

Live monitoring and management tool for Azure Update Manager patch operations.

## Requirements

- Azure CLI (`az`)
- `jq` 
- Bash 5.0+

## Quick Start

```bash
chmod +x patchblaster.sh
az login
./patchblaster.sh
```

## Features

- Real-time patch status monitoring
- Event stream showing patch installations (last 20 min)
- Bulk operations (restart, patch, assess)
- Failed VM management with error details
- Deallocated VM management

## Usage

Run the script and choose:
- **L** - Live monitoring dashboard (auto-refresh every 30s)
- **F** - Manage failed VMs (restart + retry recommended)
- **D** - Manage deallocated VMs
- **1-3** - Bulk operations on pending VMs

Press **m** in live monitor to return to menu.
