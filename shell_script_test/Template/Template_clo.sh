#!/bin/bash

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
    }
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    REGION=$(aws configure get region)
    log "SUCCESS" "AWS CLI configured (Account: $ACCOUNT_ID, Region: $REGION)"
}

# Function to validate AWS resources
validate_resource() {
    local resource_id=$1
    local resource_type=$2
    local service=$3
    
    log "INFO" "Validating $service resource: $resource_id ($resource_type)"
    
    case "$service" in
        "EBS")
            case "$resource_type" in
                "volume") 
                    aws ec2 describe-volumes --volume-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                "snapshot")
                    aws ec2 describe-snapshots --snapshot-ids "$resource_id" --owner-ids "$ACCOUNT_ID" &>/dev/null
                    return $?
                    ;;
            esac
            ;;
        "EC2")
            case "$resource_type" in
                "instance")
                    aws ec2 describe-instances --instance-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
            esac
            ;;
        *)
            log "ERROR" "Unsupported service: $service"
            return 1
            ;;
    esac
}

# Function to process CSV input
process_csv() {
    local csv_file=$1
    shift
    local selected_controls=("$@")
    
    # Check if CSV file exists
    if [[ ! -f "$csv_file" ]]; then
        log "ERROR" "CSV file not found: $csv_file"
        exit 1
    }
    
    # Check if YAML config exists
    if [[ ! -f "control_mappings.yaml" ]]; then
        log "ERROR" "control_mappings.yaml not found"
        exit 1
    }
    
    log "INFO" "Processing CSV file: $csv_file"
    log "INFO" "Selected controls: ${selected_controls[*]}"
    
    # Process CSV line by line
    while IFS=, read -r service control_name _ _ _ _ _ resource _; do
        # Skip if control not selected
        if [[ ! " ${selected_controls[@]} " =~ " ${control_name} " ]]; then
            continue
        }
        
        # Get control information from YAML
        function_name=$(yq eval ".controls.[\"$control_name\"].function" control_mappings.yaml)
        service_name=$(yq eval ".controls.[\"$control_name\"].service" control_mappings.yaml)
        resource_type=$(yq eval ".controls.[\"$control_name\"].resource_type" control_mappings.yaml)
        resource_pattern=$(yq eval ".controls.[\"$control_name\"].resource_pattern" control_mappings.yaml)
        
        # Skip if control not found in YAML
        if [[ -z "$function_name" ]]; then
            log "WARNING" "Control '$control_name' not found in YAML configuration"
            continue
        }
        
        log "INFO" "Processing control: $control_name"
        
        # Extract resource ID using pattern from YAML
        resource_id=$(echo "$resource" | grep -oE "$resource_pattern" || true)
        
        if [[ -z "$resource_id" ]]; then
            log "WARNING" "No valid resource ID found in: $resource"
            continue
        }
        
        # Validate resource before executing control
        if validate_resource "$resource_id" "$resource_type" "$service_name"; then
            log "INFO" "Executing $function_name for $resource_id"
            $function_name "$resource_id"
        else
            not_found+=("$service_name|$resource_id")
            log "ERROR" "Resource validation failed: $resource_id"
        }
    done < <(tail -n +2 "$csv_file")
}

# Call your control function here (example)
ensure_delete_on_termination() {
    local resource_id=$1
    # Your control function implementation here
    # Use need_fix and compliant arrays to track status
}

# Main function
main() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <csv_file> <control1> [control2 ...]"
        exit 1
    }
    
    local csv_file=$1
    shift
    local controls=("$@")
    
    check_aws_configuration
    process_csv "$csv_file" "${controls[@]}"
    
    # Print final summary
    log "INFO" "=== Final Summary ==="
    log "INFO" "Resources needing fixes: ${#need_fix[@]}"
    log "INFO" "Compliant resources: ${#compliant[@]}"
    log "INFO" "Resources not found: ${#not_found[@]}"
}

main "$@"
