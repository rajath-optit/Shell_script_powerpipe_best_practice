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

# Function to check EBS encryption by default
ensure_ebs_encryption_default() {
    log "INFO" "Checking EBS encryption by default..."
    local status=$(aws ec2 get-ebs-encryption-by-default --query 'EbsEncryptionByDefault' --output text)
    if [[ "$status" == "false" ]]; then
        need_fix+=("Account|$ACCOUNT_ID|EBS encryption by default disabled")
        log "WARNING" "EBS encryption by default is not enabled"
    else
        compliant+=("Account|$ACCOUNT_ID|EBS encryption by default enabled")
        log "SUCCESS" "EBS encryption by default is enabled"
    fi
}

# Function to check if EBS volumes are encrypted
ensure_encrypted_volumes() {
    local volume_id=$1
    log "INFO" "Checking encryption for volume: $volume_id"
    validate_resource "$volume_id" "volume" || { not_found+=("Volume|$volume_id"); return 1; }
    local status=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query "Volumes[0].Encrypted" --output text)
    [[ "$status" == "false" ]] && need_fix+=("Volume|$volume_id|Not encrypted") && log "WARNING" "Volume $volume_id is not encrypted" || compliant+=("Volume|$volume_id|Encrypted") && log "SUCCESS" "Volume $volume_id is encrypted"
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
    [[ $# -lt 2 ]] && { echo "Usage: $0 <csv_file> <control1> [control2 ...]"; exit 1; }
    check_aws_configuration
    process_csv "$@"
    log "INFO" "Final Summary: ${#need_fix[@]} need fixes, ${#compliant[@]} compliant, ${#not_found[@]} not found."
}

main "$@"
