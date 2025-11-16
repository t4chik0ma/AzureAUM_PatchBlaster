#!/bin/bash

# Enhanced Azure Bulk Patch Management Tool with Live Monitoring
# Ctrl+C to exit monitoring mode

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Global variable to track if we're in live monitor mode
LIVE_MONITOR_MODE=false
LAST_SEEN_EVENTS_FILE=$(mktemp)

# Function to handle Ctrl+C - different behavior based on context
handle_interrupt() {
    if [ "$LIVE_MONITOR_MODE" = true ]; then
        echo -e "\n${CYAN}Interrupted. Returning to main menu...${NC}"
        LIVE_MONITOR_MODE=false
        sleep 1
    else
        echo -e "\n${RED}Emergency exit requested!${NC}"
        echo -e "${YELLOW}Killing any running background operations...${NC}"
        # Kill any background Azure CLI operations
        jobs -p | xargs -r kill -TERM 2>/dev/null
        sleep 2
        # Force kill if they're still running
        jobs -p | xargs -r kill -KILL 2>/dev/null
        echo -e "${RED}Script terminated.${NC}"
        exit 1
    fi
}

# Trap Ctrl+C with context-aware handling
trap 'handle_interrupt' INT

# Function to get machines with pending updates
get_pending_machines() {
    echo "Getting machines with pending updates..."
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[].id" -o tsv -q '
patchassessmentresources
| extend prop=todynamic(properties)
| extend assessedAt=todatetime(prop.lastModifiedDateTime)
| where assessedAt >= ago(24h) and tostring(prop.osType) == "Windows"
| extend cls=todynamic(prop["availablePatchCountByClassification"])
| extend TotalAvailable =
  coalesce(toint(cls["security"]),0)+coalesce(toint(cls["critical"]),0)+coalesce(toint(cls["updateRollup"]),0)+
  coalesce(toint(cls["featurePack"]),0)+coalesce(toint(cls["tools"]),0)+
  coalesce(toint(cls["servicePack"]),0)+coalesce(toint(cls["other"]),0)+coalesce(toint(cls["updates"]),0)
| summarize arg_max(assessedAt, TotalAvailable, prop, cls) by id
| where toint(TotalAvailable) > 0
| project id
'
}

# Function to get machines currently in progress (installing updates)
get_inprogress_machines() {
    echo "Getting machines currently installing updates..."
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[].id" -o tsv -q '
patchinstallationresources
| extend p = todynamic(properties)
| where todatetime(p.startDateTime) >= ago(24h) and tostring(p.status) == "InProgress"
| project id
'
}

# Function to get machines currently rebooting/restarting (actively transitioning)
get_rebooting_machines() {
    echo "Getting machines currently rebooting..."
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[]" -o json -q '
Resources
| where type == "microsoft.compute/virtualmachines"
| extend powerState = tostring(properties.extended.instanceView.powerState.displayStatus)
| extend provisioningState = tostring(properties.provisioningState)
| where powerState == "VM starting" or powerState == "VM stopping" or powerState == "VM deallocating" or provisioningState == "Updating"
| project id, powerState, provisioningState
' | jq -r '.[].id' 2>/dev/null
}

# Function to get deallocated machines
get_deallocated_machines() {
    echo "Getting deallocated machines..."
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[]" -o json -q '
Resources
| where type == "microsoft.compute/virtualmachines"
| extend powerState = tostring(properties.extended.instanceView.powerState.displayStatus)
| where powerState == "VM deallocated"
| project id, powerState
' | jq -r '.[].id' 2>/dev/null
}

# Function to get recently completed patch installations
get_recently_completed() {
    echo "Getting recently completed patch installations..."
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[].id" -o tsv -q '
patchinstallationresources
| extend p = todynamic(properties)
| where todatetime(p.startDateTime) >= ago(24h) 
| where tostring(p.status) in ("Succeeded", "Failed", "CompletedWithWarnings")
| where todatetime(p.lastModifiedDateTime) >= ago(1h)
| project id
'
}

# Function to get machines that failed patching
get_failed_machines() {
    echo "Getting machines with failed patch installations..."
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[].id" -o tsv -q '
patchinstallationresources
| extend p = todynamic(properties)
| where todatetime(p.startDateTime) >= ago(24h) 
| where tostring(p.status) == "Failed"
| project id
'
}

# Function to get VMs with no recent assessment data
get_no_assessment_machines() {
    echo "Getting machines with no recent assessment data..."
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[].id" -o tsv -q '
Resources
| where type == "microsoft.compute/virtualmachines"
| where tostring(properties.storageProfile.osDisk.osType) == "Windows"
| where tostring(properties.extended.instanceView.powerState.displayStatus) == "VM running"
| join kind=leftouter (
    patchassessmentresources
    | extend prop=todynamic(properties)
    | extend assessedAt=todatetime(prop.lastModifiedDateTime)
    | where assessedAt >= ago(7d)
    | project id, hasRecentAssessment=true
) on id
| where isnull(hasRecentAssessment)
| project id
'
}

# Function to trigger patch assessment
trigger_assessment() {
    local subscription="$1"
    local resource_group="$2"
    local vm_name="$3"
    
    echo "Triggering assessment on VM: $vm_name in RG: $resource_group (Sub: ${subscription:0:8}...)"
    az vm assess-patches --subscription "$subscription" --resource-group "$resource_group" --name "$vm_name" --no-wait
}

# Function to extract VM names and resource groups from resource IDs
parse_vm_info() {
    local resource_id="$1"
    echo "$resource_id" | awk -F'/' '{
        for(i=1; i<=NF; i++) {
            if($i == "subscriptions" && i+1 <= NF) sub_id = $(i+1)
            if($i == "resourceGroups" && i+1 <= NF) rg = $(i+1)
            if($i == "virtualMachines" && i+1 <= NF) vm_name = $(i+1)
        }
        print sub_id " " rg " " vm_name
    }'
}

# Function to issue start command for deallocated VMs
start_vm() {
    local subscription="$1"
    local resource_group="$2"
    local vm_name="$3"
    
    echo "Starting VM: $vm_name in RG: $resource_group (Sub: ${subscription:0:8}...)"
    az vm start --subscription "$subscription" --resource-group "$resource_group" --name "$vm_name" --no-wait
}

# Function to issue restart command
restart_vm() {
    local subscription="$1"
    local resource_group="$2"
    local vm_name="$3"
    
    echo "Restarting VM: $vm_name in RG: $resource_group (Sub: ${subscription:0:8}...)"
    az vm restart --subscription "$subscription" --resource-group "$resource_group" --name "$vm_name" --no-wait
}

# Function to issue update installation command
install_updates() {
    local subscription="$1"
    local resource_group="$2"
    local vm_name="$3"
    
    echo "Installing updates on VM: $vm_name in RG: $resource_group (Sub: ${subscription:0:8}...)"
    
    az vm install-patches --subscription "$subscription" --resource-group "$resource_group" --name "$vm_name" \
        --classifications-to-include-win "Critical" "Security" "UpdateRollup" "FeaturePack" "ServicePack" "Definition" "Tools" "Updates" \
        --maximum-duration "PT4H" \
        --reboot-setting "IfRequired" \
        --no-wait
}

# Function to get recent AUM history events (installations only, no assessments)
get_aum_history() {
    local minutes_ago="${1:-20}"  # Default to last 20 minutes
    SUBS=$(az account list --query "[?state=='Enabled'].id" -o tsv)
    
    az graph query --subscriptions $(echo $SUBS) --query "data[]" -o json -q "
patchinstallationresources
| where type =~ 'microsoft.compute/virtualmachines/patchinstallationresults' or type =~ 'microsoft.hybridcompute/machines/patchinstallationresults'
| where todatetime(properties.lastModifiedDateTime) > ago(${minutes_ago}m)
| where tostring(properties.status) in~ ('Succeeded','Failed','CompletedWithWarnings','InProgress')
| parse id with * 'achines/' resourceName '/patchInstallationResults/' *
| parse id with * '/resourceGroups/' resourceGroup '/providers/' *
| extend eventType = 'Installation'
| extend p = todynamic(properties)
| extend status = tostring(p.status)
| extend startDateTime = todatetime(p.startDateTime)
| extend lastModifiedDateTime = todatetime(p.lastModifiedDateTime)
| extend startedBy = tostring(p.startedBy)
| extend rebootStatus = tostring(p.rebootStatus)
| extend errorCode = tostring(p.error.code)
| extend errorMessage = tostring(p.error.message)
| project id, resourceName, resourceGroup, eventType, status, startDateTime, lastModifiedDateTime, startedBy, rebootStatus, errorCode, errorMessage
| order by lastModifiedDateTime desc
| limit 30
" 2>/dev/null
}

# Function to calculate time ago in human readable format
time_ago() {
    local timestamp="$1"
    local now=$(date +%s)
    
    # Convert timestamp to epoch - handle ISO 8601 format
    local event_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo "$now")
    
    local diff=$((now - event_epoch))
    
    if [ $diff -lt 60 ]; then
        echo "${diff}s ago"
    elif [ $diff -lt 3600 ]; then
        echo "$((diff / 60))m ago"
    elif [ $diff -lt 86400 ]; then
        echo "$((diff / 3600))h ago"
    else
        echo "$((diff / 86400))d ago"
    fi
}

# Function to create event hash for tracking new events
get_event_hash() {
    local event_json="$1"
    local timestamp=$(echo "$event_json" | jq -r '.lastModifiedDateTime // empty' 2>/dev/null)
    local resource_id=$(echo "$event_json" | jq -r '.id // empty' 2>/dev/null)
    local status=$(echo "$event_json" | jq -r '.status // empty' 2>/dev/null)
    local event_type=$(echo "$event_json" | jq -r '.eventType // empty' 2>/dev/null)
    echo "${timestamp}|${resource_id}|${status}|${event_type}" | md5sum | cut -d' ' -f1
}

# Function to format AUM history event for display
format_history_event() {
    local event_json="$1"
    local is_new="${2:-false}"
    
    # Extract fields using jq
    local timestamp=$(echo "$event_json" | jq -r '.lastModifiedDateTime // empty' 2>/dev/null)
    local resource_name=$(echo "$event_json" | jq -r '.resourceName // empty' 2>/dev/null)
    local resource_group=$(echo "$event_json" | jq -r '.resourceGroup // empty' 2>/dev/null)
    local event_type=$(echo "$event_json" | jq -r '.eventType // empty' 2>/dev/null)
    local status=$(echo "$event_json" | jq -r '.status // empty' 2>/dev/null)
    local reboot_status=$(echo "$event_json" | jq -r '.rebootStatus // empty' 2>/dev/null)
    local error_message=$(echo "$event_json" | jq -r '.errorMessage // empty' 2>/dev/null)
    local started_by=$(echo "$event_json" | jq -r '.startedBy // empty' 2>/dev/null)
    
    # Skip if no data
    if [ -z "$timestamp" ] || [ -z "$resource_name" ]; then
        return
    fi
    
    # Format timestamp (extract time only)
    local time_only=$(echo "$timestamp" | grep -oP '\d{2}:\d{2}:\d{2}' || echo "${timestamp:11:8}")
    
    # Calculate time ago
    local ago=$(time_ago "$timestamp")
    
    # New event indicator
    local new_marker=" "
    if [ "$is_new" = "true" ]; then
        new_marker="*"
    fi
    
    # Event type indicator (always Installation now, but keeping structure)
    local type_symbol="[I]"
    
    # Status display
    local status_symbol=""
    case "$status" in
        "InProgress")
            status_symbol="[>>]"
            ;;
        "Succeeded")
            status_symbol="[OK]"
            ;;
        "Failed")
            status_symbol="[!!]"
            ;;
        "CompletedWithWarnings")
            status_symbol="[WN]"
            ;;
        *)
            status_symbol="[??]"
            ;;
    esac
    
    # Build the line with time ago and resource group
    printf "%s %8s %-9s %4s %-16s %-18s" "$new_marker" "$time_only" "$ago" "$status_symbol" "${resource_name:0:16}" "${resource_group:0:18}"
    
    # Add status text
    printf " %-13s" "${status:0:13}"
    
    # Add reboot info if available
    if [ -n "$reboot_status" ] && [ "$reboot_status" != "null" ] && [ "$reboot_status" != "NotNeeded" ] && [ "$reboot_status" != "empty" ]; then
        printf " RB:%s" "${reboot_status:0:8}"
    fi
    
    # Add who started it if available
    if [ -n "$started_by" ] && [ "$started_by" != "null" ] && [ "$started_by" != "empty" ]; then
        local starter=$(echo "$started_by" | grep -oP 'User|Schedule|Platform' || echo "${started_by:0:6}")
        printf " %s" "$starter"
    fi
    
    # Add error details on next line if failed
    if [ "$status" = "Failed" ] && [ -n "$error_message" ] && [ "$error_message" != "null" ] && [ "$error_message" != "empty" ]; then
        echo ""
        # Truncate error message to fit width
        local error_display=$(echo "$error_message" | cut -c1-85)
        printf "             Error: %s" "$error_display"
    fi
}
safe_count() {
    local file="$1"
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        echo 0
        return
    fi
    local count=$(grep -c . "$file" 2>/dev/null | tr -d ' \t\n\r' || echo 0)
    if [ -z "$count" ] || [ "$count" = "" ]; then
        echo 0
    else
        echo "$count"
    fi
}

# Function to display live status dashboard
show_live_status() {
    LIVE_MONITOR_MODE=true
    local refresh_interval=30
    
    while [ "$LIVE_MONITOR_MODE" = true ]; do
        # Clear screen and show header
        clear
        echo -e "${WHITE}========================================${NC}"
        echo -e "${WHITE}  Azure Patch Management Live Monitor  ${NC}"
        echo -e "${WHITE}========================================${NC}"
        echo -e "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "Press ${YELLOW}Ctrl+C${NC} to return to main menu | ${RED}Ctrl+C twice${NC} to emergency exit"
        echo
        
        # Get current status counts
        echo -e "${CYAN}Gathering current status...${NC}"
        
        # Create temp files for each status
        local pending_file=$(mktemp)
        local inprogress_file=$(mktemp)
        local rebooting_file=$(mktemp)
        local completed_file=$(mktemp)
        local failed_file=$(mktemp)
        local deallocated_file=$(mktemp)
        
        # Get all status types in parallel for faster updates
        get_pending_machines > "$pending_file" 2>/dev/null &
        local pending_pid=$!
        
        get_inprogress_machines > "$inprogress_file" 2>/dev/null &
        local inprogress_pid=$!
        
        get_rebooting_machines > "$rebooting_file" 2>/dev/null &
        local rebooting_pid=$!
        
        get_recently_completed > "$completed_file" 2>/dev/null &
        local completed_pid=$!
        
        get_failed_machines > "$failed_file" 2>/dev/null &
        local failed_pid=$!
        
        get_deallocated_machines > "$deallocated_file" 2>/dev/null &
        local deallocated_pid=$!
        
        # Wait for all background jobs to complete
        wait $pending_pid $inprogress_pid $rebooting_pid $completed_pid $failed_pid $deallocated_pid
        
        # Clean up the output files (remove status messages)
        sed -i '/Getting machines/d' "$pending_file" 2>/dev/null
        sed -i '/Getting machines/d' "$inprogress_file" 2>/dev/null
        sed -i '/Getting machines/d' "$rebooting_file" 2>/dev/null
        sed -i '/Getting machines/d' "$completed_file" 2>/dev/null
        sed -i '/Getting machines/d' "$failed_file" 2>/dev/null
        sed -i '/Getting deallocated/d' "$deallocated_file" 2>/dev/null
        
        # Count the results using safe_count function
        local pending_count=$(safe_count "$pending_file")
        local inprogress_count=$(safe_count "$inprogress_file")
        local rebooting_count=$(safe_count "$rebooting_file")
        local completed_count=$(safe_count "$completed_file")
        local failed_count=$(safe_count "$failed_file")
        local deallocated_count=$(safe_count "$deallocated_file")
        
        # Calculate machines that need attention (pending but not in progress)
        local target_file=$(mktemp)
        local pending_vms=$(mktemp)
        local inprogress_vms=$(mktemp)
        
        # Convert to VM identifiers for comparison
        while IFS= read -r resource_id; do
            if [ -n "$resource_id" ]; then
                vm_info=$(parse_vm_info "$resource_id")
                read -r subscription rg vm_name <<< "$vm_info"
                echo "${vm_name}|${rg}|${subscription}" >> "$pending_vms"
            fi
        done < "$pending_file"
        
        while IFS= read -r resource_id; do
            if [ -n "$resource_id" ]; then
                vm_info=$(parse_vm_info "$resource_id")
                read -r subscription rg vm_name <<< "$vm_info"
                echo "${vm_name}|${rg}|${subscription}" >> "$inprogress_vms"
            fi
        done < "$inprogress_file"
        
        # Find target machines (pending but not in progress)
        if [ -s "$inprogress_vms" ]; then
            comm -23 <(sort "$pending_vms" 2>/dev/null) <(sort "$inprogress_vms" 2>/dev/null) > "$target_file" 2>/dev/null
        else
            cp "$pending_vms" "$target_file" 2>/dev/null
        fi
        
        local target_count=$(safe_count "$target_file")
        
        # Clear the "gathering" message
        clear
        echo -e "${WHITE}========================================${NC}"
        echo -e "${WHITE}  Azure Patch Management Live Monitor  ${NC}"
        echo -e "${WHITE}========================================${NC}"
        echo -e "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "Press ${YELLOW}Ctrl+C${NC} to return to main menu | ${RED}Ctrl+C twice${NC} to emergency exit"
        echo
        
        # Display the status dashboard
        echo -e "${WHITE}Current Patch Status:${NC}"
        echo -e "┌─────────────────────────────────────────┬───────┐"
        printf "│ %-39s │ %5s │\n" "Status" "Count"
        echo -e "├─────────────────────────────────────────┼───────┤"
        
        # Color-coded status display
        printf "│ ${GREEN}%-31s${NC} │ %5s │\n" "✓ Updates Installing" "$inprogress_count"
        printf "│ ${BLUE}%-31s${NC} │ %5s │\n" "↻ Machines Rebooting/Starting" "$rebooting_count"
        printf "│ ${YELLOW}%-31s${NC} │ %5s │\n" "⚠ Pending Updates (Ready)" "$target_count"
        printf "│ ${MAGENTA}%-31s${NC} │ %5s │\n" "○ Total with Pending Updates" "$pending_count"
        printf "│ ${CYAN}%-31s${NC} │ %5s │\n" "✓ Recently Completed (1h)" "$completed_count"
        printf "│ ${RED}%-31s${NC} │ %5s │\n" "✗ Failed Installations" "$failed_count"
        printf "│ ${WHITE}%-31s${NC} │ %5s │\n" "⏸ Deallocated VMs" "$deallocated_count"
        
        echo -e "└─────────────────────────────────────────┴───────┘"
        echo
        
        # Show some detail if there are target machines
        if [ "$target_count" -gt 0 ]; then
            echo -e "${YELLOW}Machines Ready for Patching:${NC}"
            echo -e "────────────────────────────"
            local display_count=0
            while IFS='|' read -r vm_name rg subscription; do
                if [ -n "$vm_name" ] && [ $display_count -lt 5 ]; then
                    printf "  %-25s (%-20s)\n" "$vm_name" "$rg"
                    display_count=$((display_count + 1))
                fi
            done < "$target_file"
            
            if [ "$target_count" -gt 5 ]; then
                echo "  ... and $((target_count - 5)) more machines"
            fi
            echo
        fi
        
        # Show activity summary
        local total_active=$((inprogress_count + rebooting_count))
        if [ "$total_active" -gt 0 ]; then
            echo -e "${GREEN}Active Operations: $total_active machines${NC}"
        else
            echo -e "${WHITE}No active patch operations${NC}"
        fi
        
        if [ "$failed_count" -gt 0 ]; then
            echo -e "${RED}⚠ Warning: $failed_count machines have failed patch installations${NC}"
        fi
        
        if [ "$deallocated_count" -gt 0 ]; then
            echo -e "${WHITE}Note: $deallocated_count machines are deallocated and need to be started${NC}"
        fi
        
        echo
        echo -e "${WHITE}Patch Installation Stream (last 20 min) - New events marked with *${NC}"
        echo "=============================================================================================="
        printf "  %-8s %-9s %-4s %-16s %-18s %-13s %s\n" "Time" "Ago" "Stat" "VM Name" "Resource Group" "Status" "Notes"
        echo "----------------------------------------------------------------------------------------------"
        
        # Get and display recent history
        local history_file=$(mktemp)
        local current_events=$(mktemp)
        get_aum_history 20 > "$history_file" 2>/dev/null
        
        if [ -s "$history_file" ]; then
            # Parse JSON array and check for new events
            local event_count=0
            echo "$(<"$history_file")" | jq -c '.[]' 2>/dev/null | while read -r event && [ $event_count -lt 20 ]; do
                local event_hash=$(get_event_hash "$event")
                local is_new="false"
                
                # Check if this is a new event
                if [ -f "$LAST_SEEN_EVENTS_FILE" ]; then
                    if ! grep -q "^${event_hash}$" "$LAST_SEEN_EVENTS_FILE" 2>/dev/null; then
                        is_new="true"
                    fi
                else
                    # First run, mark all as old
                    is_new="false"
                fi
                
                # Store event hash for next iteration
                echo "$event_hash" >> "$current_events"
                
                # Format and display the event
                format_history_event "$event" "$is_new"
                echo ""
                event_count=$((event_count + 1))
            done
            
            # Update the last seen events file
            if [ -f "$current_events" ]; then
                mv "$current_events" "$LAST_SEEN_EVENTS_FILE"
            fi
        else
            echo "  No patch installations in last 20 minutes"
        fi
        
        echo "=============================================================================================="
        echo -e "${GRAY}Legend: [OK]=Success [!!]=Fail [>>]=InProgress [WN]=Warning${NC}"
        echo -e "${GRAY}(* = new since last refresh | Assessments hidden)${NC}"
        rm -f "$history_file" "$current_events"
        
        echo
        echo -e "${WHITE}Actions Available:${NC}"
        echo -e "  ${CYAN}m${NC} - Return to main menu"
        echo -e "  ${CYAN}r${NC} - Refresh now"
        echo -e "  ${CYAN}t${NC} - Show target machine details"
        echo -e "  ${CYAN}f${NC} - Show failed machines"
        echo -e "  ${CYAN}F${NC} - Manage failed machines (restart/retry)"
        echo -e "  ${CYAN}d${NC} - Show deallocated machines"
        echo -e "  ${CYAN}s${NC} - Start all deallocated machines"
        echo -e "  ${RED}q${NC} - Emergency exit (kill all operations)"
        
        # Cleanup temp files
        rm -f "$pending_file" "$inprogress_file" "$rebooting_file" "$completed_file" "$failed_file" "$deallocated_file"
        rm -f "$target_file" "$pending_vms" "$inprogress_vms"
        
        # Calculate next refresh time
        local next_refresh=$(date -d "+${refresh_interval} seconds" '+%H:%M:%S' 2>/dev/null || date -v+${refresh_interval}S '+%H:%M:%S' 2>/dev/null)
        
        # Wait for user input or timeout
        echo
        echo -e "${GRAY}Refreshing at: ${next_refresh} | Press: [m]enu [r]efresh [t]argets [f]ailed [F]ailed-mgmt [d]eallocated [s]tart-deallocated [q]uit${NC}"
        
        read -t $refresh_interval -n 1 -s input
        case $input in
            m|M)
                echo -e "\n${CYAN}Returning to main menu...${NC}"
                LIVE_MONITOR_MODE=false
                return
                ;;
            r|R)
                echo -e "\n${CYAN}Refreshing now...${NC}"
                continue
                ;;
            t|T)
                show_target_details
                read -p "Press Enter to continue..." -n 1
                ;;
            f)
                show_failed_details
                read -p "Press Enter to continue..." -n 1
                ;;
            F)
                manage_failed_vms
                ;;
            d|D)
                show_deallocated_details
                read -p "Press Enter to continue..." -n 1
                ;;
            s|S)
                start_deallocated_vms
                ;;
            q|Q)
                emergency_exit
                ;;
        esac
    done
    LIVE_MONITOR_MODE=false
}

# Function to show detailed target machine information
show_target_details() {
    clear
    echo -e "${WHITE}Target Machines Details${NC}"
    echo -e "======================="
    echo
    
    # Get the current target machines
    local pending_file=$(mktemp)
    local inprogress_file=$(mktemp)
    local target_file=$(mktemp)
    local pending_vms=$(mktemp)
    local inprogress_vms=$(mktemp)
    
    get_pending_machines > "$pending_file" 2>/dev/null
    get_inprogress_machines > "$inprogress_file" 2>/dev/null
    
    sed -i '/Getting machines/d' "$pending_file" 2>/dev/null
    sed -i '/Getting machines/d' "$inprogress_file" 2>/dev/null
    
    # Convert to VM identifiers
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            echo "${vm_name}|${rg}|${subscription}" >> "$pending_vms"
        fi
    done < "$pending_file"
    
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            echo "${vm_name}|${rg}|${subscription}" >> "$inprogress_vms"
        fi
    done < "$inprogress_file"
    
    # Find target machines
    if [ -s "$inprogress_vms" ]; then
        comm -23 <(sort "$pending_vms" 2>/dev/null) <(sort "$inprogress_vms" 2>/dev/null) > "$target_file" 2>/dev/null
    else
        cp "$pending_vms" "$target_file" 2>/dev/null
    fi
    
    printf "%-30s %-25s %-12s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s %-25s %-12s\n" "-------" "--------------" "------------"
    
    while IFS='|' read -r vm_name rg subscription; do
        if [ -n "$vm_name" ]; then
            printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
        fi
    done < "$target_file"
    
    rm -f "$pending_file" "$inprogress_file" "$target_file" "$pending_vms" "$inprogress_vms"
}

# Function to show failed machine details
show_failed_details() {
    clear
    echo -e "${RED}Failed Machines Details${NC}"
    echo -e "======================="
    echo
    
    local failed_file=$(mktemp)
    get_failed_machines > "$failed_file" 2>/dev/null
    sed -i '/Getting machines/d' "$failed_file" 2>/dev/null
    
    if [ ! -s "$failed_file" ]; then
        echo "No failed machines found."
        rm -f "$failed_file"
        return
    fi
    
    printf "%-30s %-25s %-12s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s %-25s %-12s\n" "-------" "--------------" "------------"
    
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
        fi
    done < "$failed_file"
    
    rm -f "$failed_file"
}

# Function to show deallocated machine details
show_deallocated_details() {
    clear
    echo -e "${WHITE}Deallocated Machines Details${NC}"
    echo -e "============================"
    echo
    
    local deallocated_file=$(mktemp)
    get_deallocated_machines > "$deallocated_file" 2>/dev/null
    sed -i '/Getting deallocated/d' "$deallocated_file" 2>/dev/null
    
    if [ ! -s "$deallocated_file" ]; then
        echo "No deallocated machines found."
        rm -f "$deallocated_file"
        return
    fi
    
    printf "%-30s %-25s %-12s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s %-25s %-12s\n" "-------" "--------------" "------------"
    
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
        fi
    done < "$deallocated_file"
    
    rm -f "$deallocated_file"
}

# Function to start all deallocated VMs
start_deallocated_vms() {
    echo -e "\n${CYAN}Getting deallocated machines...${NC}"
    
    local deallocated_file=$(mktemp)
    local deallocated_vms=$(mktemp)
    
    get_deallocated_machines > "$deallocated_file" 2>/dev/null
    sed -i '/Getting deallocated/d' "$deallocated_file" 2>/dev/null
    
    local deallocated_count=$(safe_count "$deallocated_file")
    
    if [ "$deallocated_count" -eq 0 ]; then
        echo "No deallocated machines found."
        rm -f "$deallocated_file" "$deallocated_vms"
        if [ "$LIVE_MONITOR_MODE" = true ]; then
            sleep 2
        else
            read -p "Press Enter to continue..." -n 1
        fi
        return
    fi
    
    # Convert to VM identifiers
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            echo "${vm_name}|${rg}|${subscription}" >> "$deallocated_vms"
        fi
    done < "$deallocated_file"
    
    echo -e "${YELLOW}Found $deallocated_count deallocated machines:${NC}"
    echo
    printf "%-30s %-25s %-12s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s %-25s %-12s\n" "-------" "--------------" "------------"
    while IFS='|' read -r vm_name rg subscription; do
        if [ -n "$vm_name" ]; then
            printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
        fi
    done < "$deallocated_vms"
    
    echo
    read -p "Start all $deallocated_count deallocated VMs? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo -e "${CYAN}Starting deallocated VMs...${NC}"
        while IFS='|' read -r vm_name rg subscription; do
            if [ -n "$vm_name" ]; then
                start_vm "$subscription" "$rg" "$vm_name" &
                # Limit concurrent operations
                (($(jobs -r | wc -l) >= 10)) && wait
            fi
        done < "$deallocated_vms"
        wait
        echo -e "${GREEN}All start commands issued (VMs starting in background).${NC}"
        
        if [ "$LIVE_MONITOR_MODE" = true ]; then
            sleep 3
        else
            echo -e "${CYAN}Switching to live monitor to track startup progress...${NC}"
            sleep 2
            show_live_status
        fi
    else
        echo "Operation cancelled."
        if [ "$LIVE_MONITOR_MODE" = false ]; then
            read -p "Press Enter to continue..." -n 1
        fi
    fi
    
    rm -f "$deallocated_file" "$deallocated_vms"
}

# Function to manage failed VMs from live monitor or main menu
manage_failed_vms() {
    clear
    echo -e "${RED}=== Failed VM Management ===${NC}"
    echo
    
    local failed_file=$(mktemp)
    local failed_vms=$(mktemp)
    
    echo -e "${CYAN}Getting machines with failed patch installations...${NC}"
    get_failed_machines > "$failed_file" 2>/dev/null
    sed -i '/Getting machines/d' "$failed_file" 2>/dev/null
    
    local failed_count=$(safe_count "$failed_file")
    
    if [ "$failed_count" -eq 0 ]; then
        echo -e "${GREEN}No failed machines found.${NC}"
        rm -f "$failed_file" "$failed_vms"
        if [ "$LIVE_MONITOR_MODE" = true ]; then
            sleep 2
        else
            read -p "Press Enter to continue..." -n 1
        fi
        return
    fi
    
    # Convert to VM identifiers
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            echo "${vm_name}|${rg}|${subscription}" >> "$failed_vms"
        fi
    done < "$failed_file"
    
    echo -e "${RED}Found $failed_count machines with failed patch installations:${NC}"
    echo "==========================================================="
    printf "%-30s %-25s %-12s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s %-25s %-12s\n" "-------" "--------------" "------------"
    while IFS='|' read -r vm_name rg subscription; do
        if [ -n "$vm_name" ]; then
            printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
        fi
    done < "$failed_vms"
    
    echo
    echo -e "${WHITE}Available Actions:${NC}"
    echo -e "${BLUE}1)${NC} Restart all failed VMs (clears transient issues)"
    echo -e "${BLUE}2)${NC} Trigger fresh assessment on failed VMs"
    echo -e "${BLUE}3)${NC} Retry patch installation on failed VMs"
    echo -e "${BLUE}4)${NC} Restart + Retry patches (recommended)"
    echo -e "${BLUE}5)${NC} Export failed VM list to file"
    echo -e "${BLUE}6)${NC} Return to previous menu"
    echo
    
    read -p "Select an action (1-6): " choice
    
    case $choice in
        1)
            echo
            read -p "Are you sure you want to restart all $failed_count failed VMs? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                echo -e "${CYAN}Restarting failed VMs...${NC}"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        restart_vm "$subscription" "$rg" "$vm_name" &
                        # Limit concurrent operations
                        (($(jobs -r | wc -l) >= 10)) && wait
                    fi
                done < "$failed_vms"
                wait
                echo -e "${GREEN}All restart commands issued (VMs restarting in background).${NC}"
                echo -e "${CYAN}Switching to live monitor to track progress...${NC}"
                sleep 2
                rm -f "$failed_file" "$failed_vms"
                if [ "$LIVE_MONITOR_MODE" = false ]; then
                    show_live_status
                fi
                return
            else
                echo "Operation cancelled."
            fi
            ;;
        2)
            echo
            read -p "Trigger fresh assessment on all $failed_count failed VMs? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                echo -e "${CYAN}Triggering assessments on failed VMs...${NC}"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        trigger_assessment "$subscription" "$rg" "$vm_name" &
                        # Limit concurrent operations
                        (($(jobs -r | wc -l) >= 10)) && wait
                    fi
                done < "$failed_vms"
                wait
                echo -e "${GREEN}All assessment commands issued (running in background).${NC}"
                echo -e "${YELLOW}Wait a few minutes for assessments to complete, then check the pending updates.${NC}"
            else
                echo "Operation cancelled."
            fi
            ;;
        3)
            echo
            echo -e "${YELLOW}Warning: Retrying patches without restarting may fail again if the issue is transient.${NC}"
            echo -e "${YELLOW}Consider option 4 (Restart + Retry) for better success rate.${NC}"
            echo
            read -p "Retry patch installation on all $failed_count failed VMs? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                echo -e "${CYAN}Retrying patch installations on failed VMs...${NC}"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        install_updates "$subscription" "$rg" "$vm_name"
                    fi
                done < "$failed_vms"
                echo -e "${GREEN}All patch installation commands issued.${NC}"
                echo -e "${CYAN}Switching to live monitor to track progress...${NC}"
                sleep 2
                rm -f "$failed_file" "$failed_vms"
                if [ "$LIVE_MONITOR_MODE" = false ]; then
                    show_live_status
                fi
                return
            else
                echo "Operation cancelled."
            fi
            ;;
        4)
            echo
            echo -e "${CYAN}Recommended workflow: Restart VMs, wait for boot, then retry patches${NC}"
            read -p "Execute restart + retry patches on all $failed_count failed VMs? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                echo -e "${CYAN}Step 1/2: Restarting failed VMs...${NC}"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        restart_vm "$subscription" "$rg" "$vm_name" &
                        # Limit concurrent operations
                        (($(jobs -r | wc -l) >= 10)) && wait
                    fi
                done < "$failed_vms"
                wait
                echo -e "${GREEN}All restart commands issued.${NC}"
                echo
                echo -e "${YELLOW}Waiting 60 seconds for VMs to restart before retrying patches...${NC}"
                for i in {60..1}; do
                    echo -ne "\rWaiting: ${i} seconds remaining...  "
                    sleep 1
                done
                echo
                echo
                echo -e "${CYAN}Step 2/2: Retrying patch installations...${NC}"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        install_updates "$subscription" "$rg" "$vm_name"
                        sleep 2  # Stagger the patch commands
                    fi
                done < "$failed_vms"
                echo -e "${GREEN}All patch retry commands issued.${NC}"
                echo -e "${CYAN}Switching to live monitor to track progress...${NC}"
                sleep 2
                rm -f "$failed_file" "$failed_vms"
                if [ "$LIVE_MONITOR_MODE" = false ]; then
                    show_live_status
                fi
                return
            else
                echo "Operation cancelled."
            fi
            ;;
        5)
            OUTPUT_FILE="failed_vms_$(date +%Y%m%d_%H%M%S).txt"
            {
                echo "Failed VMs - $(date)"
                echo "===================="
                echo "Machines with failed patch installations:"
                echo
                printf "%-30s %-25s %-40s\n" "VM Name" "Resource Group" "Subscription ID"
                printf "%-30s %-25s %-40s\n" "-------" "--------------" "---------------"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        printf "%-30s %-25s %-40s\n" "$vm_name" "$rg" "$subscription"
                    fi
                done < "$failed_vms"
            } > "$OUTPUT_FILE"
            echo -e "${GREEN}Failed VM list exported to: $OUTPUT_FILE${NC}"
            ;;
        6)
            echo "Returning to previous menu..."
            ;;
        *)
            echo "Invalid selection."
            ;;
    esac
    
    rm -f "$failed_file" "$failed_vms"
    if [ "$choice" != "1" ] && [ "$choice" != "3" ] && [ "$choice" != "4" ]; then
        if [ "$LIVE_MONITOR_MODE" = true ]; then
            sleep 1
        else
            read -p "Press Enter to continue..." -n 1
        fi
    fi
}

# Enhanced main execution
main_menu() {
    while true; do
        clear
        echo -e "${WHITE}=== Azure Bulk Patch Management Tool ===${NC}"
        echo -e "Analyzing current patch status..."
        echo

        # Get the lists
        PENDING_FILE=$(mktemp)
        INPROGRESS_FILE=$(mktemp)

        get_pending_machines > "$PENDING_FILE"
        get_inprogress_machines > "$INPROGRESS_FILE"

        # Remove the "Getting..." messages and keep only resource IDs
        sed -i '/Getting machines/d' "$PENDING_FILE" 2>/dev/null
        sed -i '/Getting machines/d' "$INPROGRESS_FILE" 2>/dev/null

        # Convert resource IDs to VM identifiers for comparison
        PENDING_VMS=$(mktemp)
        INPROGRESS_VMS=$(mktemp)

        # Extract VM identifiers from pending machines
        while IFS= read -r resource_id; do
            if [ -n "$resource_id" ]; then
                vm_info=$(parse_vm_info "$resource_id")
                read -r subscription rg vm_name <<< "$vm_info"
                echo "${vm_name}|${rg}|${subscription}" >> "$PENDING_VMS"
            fi
        done < "$PENDING_FILE"

        # Extract VM identifiers from in-progress machines  
        while IFS= read -r resource_id; do
            if [ -n "$resource_id" ]; then
                vm_info=$(parse_vm_info "$resource_id")
                read -r subscription rg vm_name <<< "$vm_info"
                echo "${vm_name}|${rg}|${subscription}" >> "$INPROGRESS_VMS"
            fi
        done < "$INPROGRESS_FILE"

        # Find machines that are pending but not in progress
        TARGET_VMS=$(mktemp)
        if [ -s "$INPROGRESS_VMS" ]; then
            comm -23 <(sort "$PENDING_VMS") <(sort "$INPROGRESS_VMS") > "$TARGET_VMS"
        else
            cp "$PENDING_VMS" "$TARGET_VMS"
        fi

        PENDING_COUNT=$(safe_count "$PENDING_FILE")
        INPROGRESS_COUNT=$(safe_count "$INPROGRESS_FILE")
        TARGET_COUNT=$(safe_count "$TARGET_VMS")

        echo -e "${WHITE}Analysis Results:${NC}"
        echo -e "  ${MAGENTA}Machines with pending updates: $PENDING_COUNT${NC}"
        echo -e "  ${GREEN}Machines currently in progress: $INPROGRESS_COUNT${NC}"
        echo -e "  ${YELLOW}Target machines (pending but not in progress): $TARGET_COUNT${NC}"
        echo

        if [ "$TARGET_COUNT" -eq 0 ]; then
            echo -e "${GREEN}No target machines found. All pending machines are already in progress.${NC}"
            echo
            echo -e "${CYAN}Available Options:${NC}"
            echo -e "${BLUE}L)${NC} Live Status Monitor"
            echo -e "${BLUE}4)${NC} Trigger assessment on all VMs with no recent assessment data"
            echo -e "${BLUE}D)${NC} Show and manage deallocated VMs"
            echo -e "${BLUE}F)${NC} Show and manage failed VMs"
            echo -e "${BLUE}8)${NC} Exit"
            echo
            read -p "Select an action: " choice
            
            case $choice in
                L|l)
                    show_live_status
                    ;;
                4)
                    trigger_assessment_no_recent
                    ;;
                D|d)
                    manage_deallocated_vms
                    ;;
                F|f)
                    manage_failed_vms
                    ;;
                8)
                    cleanup_and_exit
                    ;;
                *)
                    echo "Invalid selection."
                    read -p "Press Enter to continue..." -n 1
                    ;;
            esac
            continue
        fi

        echo -e "${YELLOW}Target machines (pending updates but not currently patching):${NC}"
        echo "============================================================"
        while IFS='|' read -r vm_name rg subscription; do
            if [ -n "$vm_name" ]; then
                printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
            fi
        done < "$TARGET_VMS"

        echo
        echo -e "${WHITE}Available Actions:${NC}"
        echo -e "${BLUE}L)${NC} ${CYAN}Live Status Monitor${NC}"
        echo -e "${BLUE}1)${NC} Restart all target VMs"
        echo -e "${BLUE}2)${NC} Install updates on all target VMs"
        echo -e "${BLUE}3)${NC} Trigger assessment on all target VMs (pending updates)"
        echo -e "${BLUE}4)${NC} Trigger assessment on VMs with no recent assessment data"
        echo -e "${BLUE}5)${NC} Show detailed resource IDs"
        echo -e "${BLUE}6)${NC} Export list to file"
        echo -e "${BLUE}7)${NC} Refresh status"
        echo -e "${BLUE}D)${NC} ${WHITE}Show and manage deallocated VMs${NC}"
        echo -e "${BLUE}F)${NC} ${RED}Show and manage failed VMs${NC}"
        echo -e "${BLUE}8)${NC} Exit"
        echo -e "${RED}9)${NC} ${RED}Emergency Exit (Kill All Operations)${NC}"
        echo

        read -p "Select an action: " choice

        case $choice in
            L|l)
                show_live_status
                ;;
            1)
                execute_restart_all
                ;;
            2)
                execute_install_all
                ;;
            3)
                execute_assessment_targets
                ;;
            4)
                trigger_assessment_no_recent
                ;;
            5)
                show_detailed_ids
                ;;
            6)
                export_to_file
                ;;
            7)
                echo -e "${CYAN}Refreshing status...${NC}"
                sleep 1
                ;;
            D|d)
                manage_deallocated_vms
                ;;
            F|f)
                manage_failed_vms
                ;;
            8)
                cleanup_and_exit
                ;;
            9)
                emergency_exit
                ;;
            *)
                echo "Invalid selection."
                read -p "Press Enter to continue..." -n 1
                ;;
        esac

        # Cleanup temp files after each iteration
        rm -f "$PENDING_FILE" "$INPROGRESS_FILE" "$PENDING_VMS" "$INPROGRESS_VMS" "$TARGET_VMS"
    done
}

# Function to execute restart all
execute_restart_all() {
    echo
    read -p "Are you sure you want to restart $TARGET_COUNT VMs? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo -e "${CYAN}Initiating restarts...${NC}"
        while IFS='|' read -r vm_name rg subscription; do
            if [ -n "$vm_name" ]; then
                restart_vm "$subscription" "$rg" "$vm_name" &
                # Limit concurrent operations
                (($(jobs -r | wc -l) >= 10)) && wait
            fi
        done < "$TARGET_VMS"
        wait
        echo -e "${GREEN}All restart commands issued (running in background).${NC}"
        echo -e "${CYAN}Switching to live monitor to track progress...${NC}"
        sleep 2
        show_live_status
    else
        echo "Operation cancelled."
        read -p "Press Enter to continue..." -n 1
    fi
}

# Function to execute install all
execute_install_all() {
    echo
    read -p "Are you sure you want to install updates on $TARGET_COUNT VMs? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo -e "${CYAN}Initiating update installations...${NC}"
        while IFS='|' read -r vm_name rg subscription; do
            if [ -n "$vm_name" ]; then
                install_updates "$subscription" "$rg" "$vm_name"
            fi
        done < "$TARGET_VMS"
        echo -e "${GREEN}All update installation commands issued.${NC}"
        echo -e "${CYAN}Switching to live monitor to track progress...${NC}"
        sleep 2
        show_live_status
    else
        echo "Operation cancelled."
        read -p "Press Enter to continue..." -n 1
    fi
}

# Function to execute assessment on targets
execute_assessment_targets() {
    echo
    read -p "Are you sure you want to trigger assessment on $TARGET_COUNT VMs with pending updates? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo -e "${CYAN}Initiating patch assessments on target VMs...${NC}"
        while IFS='|' read -r vm_name rg subscription; do
            if [ -n "$vm_name" ]; then
                trigger_assessment "$subscription" "$rg" "$vm_name" &
                # Limit concurrent operations
                (($(jobs -r | wc -l) >= 10)) && wait
            fi
        done < "$TARGET_VMS"
        wait
        echo -e "${GREEN}All assessment commands issued (running in background).${NC}"
        read -p "Press Enter to continue..." -n 1
    else
        echo "Operation cancelled."
        read -p "Press Enter to continue..." -n 1
    fi
}

# Function to trigger assessment on machines with no recent assessment
trigger_assessment_no_recent() {
    echo
    echo -e "${CYAN}Getting VMs with no recent assessment data (last 7 days)...${NC}"
    NO_ASSESSMENT_FILE=$(mktemp)
    get_no_assessment_machines > "$NO_ASSESSMENT_FILE"
    
    sed -i '/Getting machines with no recent assessment/d' "$NO_ASSESSMENT_FILE" 2>/dev/null
    
    NO_ASSESSMENT_COUNT=$(safe_count "$NO_ASSESSMENT_FILE")
    
    if [ "$NO_ASSESSMENT_COUNT" -eq 0 ]; then
        echo "No VMs found without recent assessment data."
        rm -f "$NO_ASSESSMENT_FILE"
        read -p "Press Enter to continue..." -n 1
        return
    fi
    
    echo -e "${YELLOW}Found $NO_ASSESSMENT_COUNT VMs without recent assessment data:${NC}"
    echo
    
    NO_ASSESSMENT_VMS=$(mktemp)
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            echo "${vm_name}|${rg}|${subscription}" >> "$NO_ASSESSMENT_VMS"
        fi
    done < "$NO_ASSESSMENT_FILE"
    
    printf "%-30s %-25s %-12s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s %-25s %-12s\n" "-------" "--------------" "------------"
    while IFS='|' read -r vm_name rg subscription; do
        if [ -n "$vm_name" ]; then
            printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
        fi
    done < "$NO_ASSESSMENT_VMS"
    
    echo
    read -p "Trigger assessment on these $NO_ASSESSMENT_COUNT VMs? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo -e "${CYAN}Initiating patch assessments...${NC}"
        while IFS='|' read -r vm_name rg subscription; do
            if [ -n "$vm_name" ]; then
                trigger_assessment "$subscription" "$rg" "$vm_name" &
                # Limit concurrent operations
                (($(jobs -r | wc -l) >= 10)) && wait
            fi
        done < "$NO_ASSESSMENT_VMS"
        wait
        echo -e "${GREEN}All assessment commands issued (running in background).${NC}"
    else
        echo "Operation cancelled."
    fi
    
    rm -f "$NO_ASSESSMENT_FILE" "$NO_ASSESSMENT_VMS"
    read -p "Press Enter to continue..." -n 1
}

# Function to show detailed resource IDs
show_detailed_ids() {
    echo
    echo -e "${WHITE}Detailed Resource IDs:${NC}"
    echo "===================="
    printf "%-30s | %-25s | %s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s | %-25s | %s\n" "-------" "--------------" "------------"
    while IFS='|' read -r vm_name rg subscription; do
        if [ -n "$vm_name" ]; then
            printf "%-30s | %-25s | %s\n" "$vm_name" "$rg" "$subscription"
        fi
    done < "$TARGET_VMS"
    read -p "Press Enter to continue..." -n 1
}

# Function to export list to file
export_to_file() {
    OUTPUT_FILE="target_vms_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "Target VMs for Bulk Operations - $(date)"
        echo "========================================"
        echo "Machines with pending updates but not currently patching:"
        echo
        printf "%-30s %-25s %-40s\n" "VM Name" "Resource Group" "Subscription ID"
        printf "%-30s %-25s %-40s\n" "-------" "--------------" "---------------"
        while IFS='|' read -r vm_name rg subscription; do
            if [ -n "$vm_name" ]; then
                printf "%-30s %-25s %-40s\n" "$vm_name" "$rg" "$subscription"
            fi
        done < "$TARGET_VMS"
    } > "$OUTPUT_FILE"
    echo -e "${GREEN}List exported to: $OUTPUT_FILE${NC}"
    read -p "Press Enter to continue..." -n 1
}

# Function to manage deallocated VMs from main menu
manage_deallocated_vms() {
    clear
    echo -e "${WHITE}=== Deallocated VM Management ===${NC}"
    echo
    
    local deallocated_file=$(mktemp)
    local deallocated_vms=$(mktemp)
    
    echo -e "${CYAN}Getting deallocated machines...${NC}"
    get_deallocated_machines > "$deallocated_file" 2>/dev/null
    sed -i '/Getting deallocated/d' "$deallocated_file" 2>/dev/null
    
    local deallocated_count=$(safe_count "$deallocated_file")
    
    if [ "$deallocated_count" -eq 0 ]; then
        echo -e "${GREEN}No deallocated machines found.${NC}"
        rm -f "$deallocated_file" "$deallocated_vms"
        read -p "Press Enter to continue..." -n 1
        return
    fi
    
    # Convert to VM identifiers
    while IFS= read -r resource_id; do
        if [ -n "$resource_id" ]; then
            vm_info=$(parse_vm_info "$resource_id")
            read -r subscription rg vm_name <<< "$vm_info"
            echo "${vm_name}|${rg}|${subscription}" >> "$deallocated_vms"
        fi
    done < "$deallocated_file"
    
    echo -e "${WHITE}Found $deallocated_count deallocated machines:${NC}"
    echo "============================================"
    printf "%-30s %-25s %-12s\n" "VM Name" "Resource Group" "Subscription"
    printf "%-30s %-25s %-12s\n" "-------" "--------------" "------------"
    while IFS='|' read -r vm_name rg subscription; do
        if [ -n "$vm_name" ]; then
            printf "%-30s %-25s %-12s\n" "$vm_name" "$rg" "${subscription:0:8}..."
        fi
    done < "$deallocated_vms"
    
    echo
    echo -e "${WHITE}Available Actions:${NC}"
    echo -e "${BLUE}1)${NC} Start all deallocated VMs"
    echo -e "${BLUE}2)${NC} Export deallocated VM list to file"
    echo -e "${BLUE}3)${NC} Return to main menu"
    echo
    
    read -p "Select an action (1-3): " choice
    
    case $choice in
        1)
            echo
            read -p "Are you sure you want to start all $deallocated_count deallocated VMs? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                echo -e "${CYAN}Starting deallocated VMs...${NC}"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        start_vm "$subscription" "$rg" "$vm_name" &
                        # Limit concurrent operations
                        (($(jobs -r | wc -l) >= 10)) && wait
                    fi
                done < "$deallocated_vms"
                wait
                echo -e "${GREEN}All start commands issued (VMs starting in background).${NC}"
                echo -e "${CYAN}Switching to live monitor to track startup progress...${NC}"
                sleep 2
                rm -f "$deallocated_file" "$deallocated_vms"
                show_live_status
                return
            else
                echo "Operation cancelled."
            fi
            ;;
        2)
            OUTPUT_FILE="deallocated_vms_$(date +%Y%m%d_%H%M%S).txt"
            {
                echo "Deallocated VMs - $(date)"
                echo "========================"
                echo "Machines that are currently deallocated:"
                echo
                printf "%-30s %-25s %-40s\n" "VM Name" "Resource Group" "Subscription ID"
                printf "%-30s %-25s %-40s\n" "-------" "--------------" "---------------"
                while IFS='|' read -r vm_name rg subscription; do
                    if [ -n "$vm_name" ]; then
                        printf "%-30s %-25s %-40s\n" "$vm_name" "$rg" "$subscription"
                    fi
                done < "$deallocated_vms"
            } > "$OUTPUT_FILE"
            echo -e "${GREEN}Deallocated VM list exported to: $OUTPUT_FILE${NC}"
            ;;
        3)
            echo "Returning to main menu..."
            ;;
        *)
            echo "Invalid selection."
            ;;
    esac
    
    rm -f "$deallocated_file" "$deallocated_vms"
    if [ "$choice" != "1" ]; then
        read -p "Press Enter to continue..." -n 1
    fi
}

# Function to emergency exit (kill all operations)
emergency_exit() {
    echo -e "\n${RED}=== EMERGENCY EXIT ===${NC}"
    echo -e "${YELLOW}This will immediately terminate all running Azure operations!${NC}"
    echo -e "${YELLOW}Any patch installations or assessments in progress will be interrupted.${NC}"
    echo
    read -p "Are you sure you want to emergency exit? (yes/no): " confirm
    
    if [ "$confirm" = "yes" ]; then
        echo -e "${RED}Emergency exit confirmed. Terminating all operations...${NC}"
        
        # Kill all background jobs
        echo -e "${YELLOW}Killing background Azure CLI operations...${NC}"
        jobs -p | xargs -r kill -TERM 2>/dev/null
        sleep 2
        
        # Force kill any remaining processes
        jobs -p | xargs -r kill -KILL 2>/dev/null
        
        # Also kill any az processes that might be running
        pkill -f "az vm" 2>/dev/null || true
        pkill -f "az graph" 2>/dev/null || true
        
        echo -e "${RED}All operations terminated. Exiting script.${NC}"
        exit 1
    else
        echo -e "${CYAN}Emergency exit cancelled.${NC}"
        if [ "$LIVE_MONITOR_MODE" = true ]; then
            sleep 1
        else
            read -p "Press Enter to continue..." -n 1
        fi
    fi
}

# Function to cleanup and exit
cleanup_and_exit() {
    echo -e "${CYAN}Graceful exit - cleaning up background jobs...${NC}"
    # Kill any background jobs gracefully
    jobs -p | xargs -r kill -TERM 2>/dev/null
    sleep 1
    # Clean up tracking file
    rm -f "$LAST_SEEN_EVENTS_FILE"
    echo -e "${GREEN}Clean exit completed.${NC}"
    exit 0
}

# Check if Azure CLI is installed and logged in
if ! command -v az &> /dev/null; then
    echo -e "${RED}Error: Azure CLI is not installed or not in PATH${NC}"
    exit 1
fi

if ! az account show &> /dev/null; then
    echo -e "${RED}Error: Not logged in to Azure CLI. Please run 'az login' first.${NC}"
    exit 1
fi

# Start the main menu
main_menu
