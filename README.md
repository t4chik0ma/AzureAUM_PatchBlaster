# Azure Update Manager - Patch Dashboard

Live monitoring and management tool for Azure Update Manager patch operations across subscriptions in a tenant.

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

- Real-time patch status monitoring - placing VMs into a patch success category; succeeded, failed, running, etc 
- Event stream showing patch installations per the AUM history log
- Bulk operations (restart, patch, assess)
- Identify failed VMs and their error details
- Deallocated VM management - time to wake up, it's patching time!


