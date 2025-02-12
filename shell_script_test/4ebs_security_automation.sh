#!/bin/bash

# Configuration file for control mappings
cat > control_mappings.yaml << 'EOF'
controls:
  "EBS snapshots should not be publicly restorable":
    function: "ensure_private_snapshots"
    description: "Ensures EBS snapshots are not publicly accessible"
  "Attached EBS volumes should have encryption enabled":
    function: "ensure_encrypted_volumes"
    description: "Ensures attached EBS volumes are encrypted"
  "EBS volumes should be protected by a backup plan":
    function: "ensure_backup_plan"
    description: "Ensures EBS volumes are protected by backup plans"
  "EBS encryption by default should be enabled":
    function: "ensure_ebs_encryption_default"
    description: "Ensures EBS encryption by default is enabled"
  "EBS volumes should be attached to EC2 instances":
    function: "ensure_ebs_attached"
    description: "Ensures EBS volumes are attached to EC2 instances"
  "EBS snapshots should be encrypted":
    function: "ensure_snapshot_encryption"
    description: "Ensures EBS snapshots are encrypted"
  "EBS volume snapshots should exist":
    function: "ensure_snapshots_exist"
    description: "Ensures EBS volumes have snapshots"
  "Attached EBS volumes should have delete on termination enabled":
    function: "ensure_delete_on_termination"
    description: "Ensures attached EBS volumes have delete on termination enabled"
EOF

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BLUE='\033[0;34m'

# Arrays to store resources
declare -a need_fix=()
declare -a compliant=()
declare -a not_found=()

# Function to log messages
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO") echo -e "${BLUE}[$timestamp] INFO: $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] SUCCESS: $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] WARNING: $message${NC}" ;;
        "ERROR") echo -e "${RED}[$timestamp] ERROR: $message${NC}" ;;
        *) echo "[$timestamp] $message" ;;
    esac
}

# Function to check AWS CLI configuration
check_aws_configuration() {
    log "INFO" "Checking AWS CLI configuration..."
    if ! command -v aws &> /dev/null; then
        log "ERROR" "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    if ! aws sts get-caller-identity &> /dev/null; then
        log "ERROR" "AWS CLI is not properly configured. Please run 'aws configure' first."
        exit 1
    fi
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    REGION=$(aws configure get region)
    log "SUCCESS" "AWS CLI configured (Account: $ACCOUNT_ID, Region: $REGION)"
}

# Function to validate AWS resources
validate_resource() {
    local resource_id=$1
    local resource_type=$2
    case $resource_type in
        "volume") aws ec2 describe-volumes --volume-ids "$resource_id" &>/dev/null && return 0 ;;
        "snapshot") aws ec2 describe-snapshots --snapshot-ids "$resource_id" --owner-ids "$ACCOUNT_ID" &>/dev/null && return 0 ;;
    esac
    return 1
}

# Function to ensure snapshots are private
ensure_private_snapshots() {
    local snapshot_id=$1
    log "INFO" "Checking if snapshot $snapshot_id is public..."
    
    if ! validate_resource "$snapshot_id" "snapshot"; then
        not_found+=("Snapshot|$snapshot_id")
        log "ERROR" "Snapshot $snapshot_id not found"
        return 1
    fi
    
    local permissions
    permissions=$(aws ec2 describe-snapshot-attribute \
        --snapshot-id "$snapshot_id" \
        --attribute createVolumePermission \
        --query "CreateVolumePermissions" \
        --output json)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check snapshot permissions"
        return 1
    fi

    if [[ "$permissions" != "[]" ]]; then
        need_fix+=("Snapshot|$snapshot_id|Public access")
        log "WARNING" "Snapshot $snapshot_id is public"
    else
        compliant+=("Snapshot|$snapshot_id|Private access")
        log "SUCCESS" "Snapshot $snapshot_id is private"
    fi
}

# Function to check if EBS volumes are encrypted
ensure_encrypted_volumes() {
    local volume_id=$1
    log "INFO" "Checking encryption for volume: $volume_id"
    
    if ! validate_resource "$volume_id" "volume"; then
        not_found+=("Volume|$volume_id")
        log "ERROR" "Volume $volume_id not found"
        return 1
    fi
    
    local status
    status=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query "Volumes[0].Encrypted" --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check volume encryption"
        return 1
    fi

    if [[ "$status" == "false" ]]; then
        need_fix+=("Volume|$volume_id|Not encrypted")
        log "WARNING" "Volume $volume_id is not encrypted"
    else
        compliant+=("Volume|$volume_id|Encrypted")
        log "SUCCESS" "Volume $volume_id is encrypted"
    fi
}

# Function to check if an EBS volume is part of a backup plan
ensure_backup_plan() {
    local volume_id=$1
    log "INFO" "Checking if volume $volume_id is in a backup plan..."
    
    if ! validate_resource "$volume_id" "volume"; then
        not_found+=("Volume|$volume_id")
        log "ERROR" "Volume $volume_id not found"
        return 1
    fi

    local backup_resources
    backup_resources=$(aws backup list-protected-resources \
        --query "ResourceArns[?contains(@, '$volume_id')]" \
        --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check backup plan"
        return 1
    fi

    if [[ -z "$backup_resources" ]]; then
        need_fix+=("Volume|$volume_id|No backup plan")
        log "WARNING" "Volume $volume_id is not in a backup plan"
    else
        compliant+=("Volume|$volume_id|In backup plan")
        log "SUCCESS" "Volume $volume_id is in a backup plan"
    fi
}

# Function to check EBS encryption by default
ensure_ebs_encryption_default() {
    log "INFO" "Checking EBS encryption by default..."
    local status
    status=$(aws ec2 get-ebs-encryption-by-default --query 'EbsEncryptionByDefault' --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check EBS encryption by default"
        return 1
    fi

    if [[ "$status" == "false" ]]; then
        need_fix+=("Account|$ACCOUNT_ID|EBS encryption by default disabled")
        log "WARNING" "EBS encryption by default is not enabled"
    else
        compliant+=("Account|$ACCOUNT_ID|EBS encryption by default enabled")
        log "SUCCESS" "EBS encryption by default is enabled"
    fi
}

# Function to ensure volumes are attached
ensure_ebs_attached() {
    local volume_id=$1
    log "INFO" "Checking if volume $volume_id is attached..."
    
    if ! validate_resource "$volume_id" "volume"; then
        not_found+=("Volume|$volume_id")
        log "ERROR" "Volume $volume_id not found"
        return 1
    fi

    local state
    state=$(aws ec2 describe-volumes \
        --volume-ids "$volume_id" \
        --query "Volumes[0].State" \
        --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check volume attachment"
        return 1
    fi

    if [[ "$state" != "in-use" ]]; then
        need_fix+=("Volume|$volume_id|Not attached")
        log "WARNING" "Volume $volume_id is not attached"
    else
        compliant+=("Volume|$volume_id|Attached")
        log "SUCCESS" "Volume $volume_id is attached"
    fi
}

# Function to ensure snapshots are encrypted
ensure_snapshot_encryption() {
    local snapshot_id=$1
    log "INFO" "Checking encryption for snapshot: $snapshot_id"
    
    if ! validate_resource "$snapshot_id" "snapshot"; then
        not_found+=("Snapshot|$snapshot_id")
        log "ERROR" "Snapshot $snapshot_id not found"
        return 1
    fi

    local status
    status=$(aws ec2 describe-snapshots \
        --snapshot-ids "$snapshot_id" \
        --query "Snapshots[0].Encrypted" \
        --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check snapshot encryption"
        return 1
    fi

    if [[ "$status" == "false" ]]; then
        need_fix+=("Snapshot|$snapshot_id|Not encrypted")
        log "WARNING" "Snapshot $snapshot_id is not encrypted"
    else
        compliant+=("Snapshot|$snapshot_id|Encrypted")
        log "SUCCESS" "Snapshot $snapshot_id is encrypted"
    fi
}

# Function to ensure volumes have snapshots
ensure_snapshots_exist() {
    local volume_id=$1
    log "INFO" "Checking if volume $volume_id has snapshots..."
    
    if ! validate_resource "$volume_id" "volume"; then
        not_found+=("Volume|$volume_id")
        log "ERROR" "Volume $volume_id not found"
        return 1
    fi

    local snapshots
    snapshots=$(aws ec2 describe-snapshots \
        --filters Name=volume-id,Values="$volume_id" \
        --query "Snapshots[*].[SnapshotId]" \
        --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check volume snapshots"
        return 1
    fi

    if [[ -z "$snapshots" ]]; then
        need_fix+=("Volume|$volume_id|No snapshots")
        log "WARNING" "Volume $volume_id has no snapshots"
    else
        compliant+=("Volume|$volume_id|Has snapshots")
        log "SUCCESS" "Volume $volume_id has snapshots"
    fi
}

# Function to ensure DeleteOnTermination is enabled
ensure_delete_on_termination() {
    local volume_id=$1
    log "INFO" "Checking DeleteOnTermination for volume: $volume_id"
    
    if ! validate_resource "$volume_id" "volume"; then
        not_found+=("Volume|$volume_id")
        log "ERROR" "Volume $volume_id not found"
        return 1
    fi

    local attachment_info
    attachment_info=$(aws ec2 describe-volumes \
        --volume-ids "$volume_id" \
        --query "Volumes[0].Attachments[0].[InstanceId,DeleteOnTermination]" \
        --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to check DeleteOnTermination setting"
        return 1
    fi

    local instance_id=$(echo "$attachment_info" | cut -f1)
    local delete_on_termination=$(echo "$attachment_info" | cut -f2)

    if [[ -z "$instance_id" ]]; then
        need_fix+=("Volume|$volume_id|Not attached")
        log "WARNING" "Volume $volume_id is not attached to any instance"
        return 1
    fi

    if [[ "$delete_on_termination" == "false" ]]; then
        need_fix+=("Volume|$volume_id|DeleteOnTermination disabled")
        log "WARNING" "Volume $volume_id does not have DeleteOnTermination enabled"
    else
        compliant+=("Volume|$volume_id|DeleteOnTermination enabled")
        log "SUCCESS" "Volume $volume_id has DeleteOnTermination enabled"
    fi
}

# Function to process CSV input
process_csv() {
    local csv_file=$1
    shift
    local selected_controls=("$@")
    while IFS=, read -r _ _ _ _ control _ _ _ resource _; do
        [[ " ${selected_controls[@]} " =~ " ${control} " ]] || continue
        log "INFO" "Processing control: $control"
        function_name=$(yq eval ".controls.[\"$control\"].function" control_mappings.yaml)
        [[ -z "$function_name" ]] && continue
        resource_id=$(echo $resource | grep -oE 'vol-[a-zA-Z0-9]+|snap-[a-zA-Z0-9]+')
        [[ -n "$resource_id" ]] && $function_name "$resource_id"
    done < <(tail -n +2 "$csv_file")
}

# Main function
main() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <csv_file> <control1> [control2 ...]"
        exit 1
    fi
    check_aws_configuration
    process_csv "$@"
    log "INFO" "Final Summary: ${#need_fix[@]} need fixes, ${#compliant[@]} compliant, ${#not_found[@]} not found."
}

main "$@"
