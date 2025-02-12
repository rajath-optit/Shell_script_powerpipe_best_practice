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
  "EBS volume encryption at rest should be enabled":
    function: "ensure_encrypted_volumes"
    description: "Ensures EBS volumes have encryption at rest enabled"
  "EBS snapshots should be encrypted":
    function: "ensure_encrypted_snapshots"
    description: "Ensures EBS snapshots are encrypted"
  "EBS encryption by default should be enabled":
    function: "ensure_ebs_encryption_default"
    description: "Ensures EBS encryption by default is enabled"
  "EBS volumes should be attached to EC2 instances":
    function: "ensure_ebs_attached"
    description: "Ensures EBS volumes are attached to EC2 instances"
  "EBS volume snapshots should exist":
    function: "ensure_snapshots_exist"
    description: "Ensures EBS volumes have snapshots"
  "EBS volumes should be in a backup plan":
    function: "ensure_ebs_in_backup_plan"
    description: "Ensures EBS volumes are in backup plans"
  "Attached EBS volumes should have delete on termination enabled":
    function: "ensure_delete_on_termination"
    description: "Ensures attached EBS volumes have delete on termination enabled"
EOF

# Function to log messages with timestamp
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to extract volume ID from ARN
extract_volume_id() {
    local arn=$1
    echo $arn | grep -o 'vol-[a-zA-Z0-9]\+'
}

# Function to extract snapshot ID from ARN
extract_snapshot_id() {
    local arn=$1
    echo $arn | grep -o 'snap-[a-zA-Z0-9]\+'
}

# Include all the individual control functions
source_control_functions() {
    # Function to ensure EBS snapshots are not publicly restorable
    ensure_private_snapshots() {
        local snapshot_id=$1
        log "🔍 Checking public access for snapshot: $snapshot_id"
        
        public_permission=$(aws ec2 describe-snapshot-attribute \
            --snapshot-id "$snapshot_id" \
            --attribute createVolumePermission \
            --query "CreateVolumePermissions[?Group=='all']" \
            --output text)
        
        if [[ -n "$public_permission" ]]; then
            log "❌ Snapshot $snapshot_id is publicly accessible. Making it private..."
            aws ec2 modify-snapshot-attribute --snapshot-id "$snapshot_id" --create-volume-permission "Remove=[{Group=all}]"
            log "✅ Snapshot $snapshot_id is now private"
            return 0
        else
            log "✅ Snapshot $snapshot_id is already private"
            return 0
        fi
    }

    # Function to ensure EBS volumes are encrypted
    ensure_encrypted_volumes() {
        local volume_id=$1
        log "🔍 Checking encryption for volume: $volume_id"
        
        encryption_status=$(aws ec2 describe-volumes \
            --volume-ids "$volume_id" \
            --query "Volumes[0].Encrypted" \
            --output text)
        
        if [[ "$encryption_status" == "false" ]]; then
            log "❌ Volume $volume_id is not encrypted. Creating encrypted copy..."
            
            # Create snapshot
            snapshot_id=$(aws ec2 create-snapshot \
                --volume-id "$volume_id" \
                --description "Temporary snapshot for encryption" \
                --query "SnapshotId" \
                --output text)
            
            # Wait for snapshot to complete
            aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id"
            
            # Create encrypted volume
            new_volume_id=$(aws ec2 create-volume \
                --snapshot-id "$snapshot_id" \
                --encrypted \
                --volume-type gp3 \
                --query "VolumeId" \
                --output text)
            
            log "✅ Created encrypted volume $new_volume_id from $volume_id"
            return 0
        else
            log "✅ Volume $volume_id is already encrypted"
            return 0
        fi
    }

    # Function to ensure volumes are protected by backup plan
    ensure_backup_plan() {
        local volume_id=$1
        log "🔍 Checking backup plan for volume: $volume_id"
        
        # Get AWS account ID
        account_id=$(aws sts get-caller-identity --query Account --output text)
        region=$(aws configure get region)
        
        backup_plan_check=$(aws backup list-protected-resources \
            --resource-arn "arn:aws:ec2:${region}:${account_id}:volume/${volume_id}" \
            --query "Results[0]" \
            --output text)
            
        if [[ -z "$backup_plan_check" ]]; then
            log "❌ Volume $volume_id is not protected by a backup plan. Adding to backup plan..."
            
            # Create a backup selection for the volume
            aws backup create-backup-selection \
                --backup-plan-id $(aws backup list-backup-plans --query "BackupPlansList[0].BackupPlanId" --output text) \
                --selection-name "Volume-${volume_id}" \
                --iam-role-arn "arn:aws:iam::${account_id}:role/service-role/AWSBackupDefaultServiceRole" \
                --resources "arn:aws:ec2:${region}:${account_id}:volume/${volume_id}"
                
            log "✅ Volume $volume_id is now protected by backup plan"
            return 0
        else
            log "✅ Volume $volume_id is already protected by backup plan"
            return 0
        fi
    }

    # Function to ensure snapshots are encrypted
    ensure_encrypted_snapshots() {
        local snapshot_id=$1
        log "🔍 Checking encryption for snapshot: $snapshot_id"
        
        encryption_status=$(aws ec2 describe-snapshots \
            --snapshot-ids "$snapshot_id" \
            --query "Snapshots[0].Encrypted" \
            --output text)
            
        if [[ "$encryption_status" == "false" ]]; then
            log "❌ Snapshot $snapshot_id is not encrypted. Creating encrypted copy..."
            
            # Create encrypted copy
            new_snapshot_id=$(aws ec2 copy-snapshot \
                --source-snapshot-id "$snapshot_id" \
                --encrypted \
                --query "SnapshotId" \
                --output text)
                
            log "✅ Created encrypted snapshot $new_snapshot_id from $snapshot_id"
            return 0
        else
            log "✅ Snapshot $snapshot_id is already encrypted"
            return 0
        fi
    }

    # Function to ensure EBS encryption by default is enabled
    ensure_ebs_encryption_default() {
        log "🔍 Checking EBS encryption by default setting"
        
        encryption_status=$(aws ec2 get-ebs-encryption-by-default \
            --query "EbsEncryptionByDefault" \
            --output text)
            
        if [[ "$encryption_status" == "false" ]]; then
            log "❌ EBS encryption by default is not enabled. Enabling now..."
            
            aws ec2 enable-ebs-encryption-by-default
            
            log "✅ EBS encryption by default is now enabled"
            return 0
        else
            log "✅ EBS encryption by default is already enabled"
            return 0
        fi
    }

    # Function to ensure volumes are attached to EC2 instances
    ensure_ebs_attached() {
        local volume_id=$1
        log "🔍 Checking attachment status for volume: $volume_id"
        
        attachment_status=$(aws ec2 describe-volumes \
            --volume-ids "$volume_id" \
            --query "Volumes[0].Attachments[0].State" \
            --output text)
            
        if [[ "$attachment_status" == "None" || -z "$attachment_status" ]]; then
            log "❌ Volume $volume_id is not attached to any instance"
            # Note: We can't automatically attach volumes as it requires instance selection
            log "⚠️ Manual action required: Attach volume to an appropriate EC2 instance"
            return 1
        else
            log "✅ Volume $volume_id is attached to an instance"
            return 0
        fi
    }

    # Function to ensure volume snapshots exist
    ensure_snapshots_exist() {
        local volume_id=$1
        log "🔍 Checking snapshots for volume: $volume_id"
        
        snapshots=$(aws ec2 describe-snapshots \
            --filters "Name=volume-id,Values=$volume_id" \
            --query "Snapshots[0].SnapshotId" \
            --output text)
            
        if [[ -z "$snapshots" || "$snapshots" == "None" ]]; then
            log "❌ No snapshots found for volume $volume_id. Creating snapshot..."
            
            new_snapshot_id=$(aws ec2 create-snapshot \
                --volume-id "$volume_id" \
                --description "Automated snapshot creation" \
                --query "SnapshotId" \
                --output text)
                
            log "✅ Created snapshot $new_snapshot_id for volume $volume_id"
            return 0
        else
            log "✅ Volume $volume_id has existing snapshots"
            return 0
        fi
    }

    # Function to ensure volumes have delete on termination enabled
    ensure_delete_on_termination() {
        local volume_id=$1
        log "🔍 Checking delete on termination for volume: $volume_id"
        
        # Get instance ID and device name
        attachment_info=$(aws ec2 describe-volumes \
            --volume-ids "$volume_id" \
            --query "Volumes[0].Attachments[0].[InstanceId,Device]" \
            --output text)
            
        read -r instance_id device_name <<< "$attachment_info"
        
        if [[ -n "$instance_id" && -n "$device_name" ]]; then
            delete_on_term=$(aws ec2 describe-instance-attribute \
                --instance-id "$instance_id" \
                --attribute blockDeviceMapping \
                --query "BlockDeviceMappings[?DeviceName=='$device_name'].DeleteOnTermination" \
                --output text)
                
            if [[ "$delete_on_term" == "false" ]]; then
                log "❌ Delete on termination is not enabled for volume $volume_id. Enabling..."
                
                aws ec2 modify-instance-attribute \
                    --instance-id "$instance_id" \
                    --block-device-mappings "[{\"DeviceName\": \"$device_name\",\"Ebs\":{\"DeleteOnTermination\":true}}]"
                    
                log "✅ Delete on termination enabled for volume $volume_id"
                return 0
            else
                log "✅ Delete on termination is already enabled for volume $volume_id"
                return 0
            fi
        else
            log "⚠️ Volume $volume_id is not attached to an instance"
            return 1
        fi
    }
}

# Function to process CSV and execute controls
process_csv() {
    local csv_file=$1
    local selected_controls=$2
    
    # Skip header line and process CSV
    tail -n +2 "$csv_file" | while IFS=, read -r line; do
        # Extract control and resource from CSV line
        control=$(echo "$line" | cut -d',' -f5)  # Adjust field number based on your CSV
        resource=$(echo "$line" | cut -d',' -f9)  # Adjust field number based on your CSV
        status=$(echo "$line" | cut -d',' -f10)   # Adjust field number based on your CSV
        
        # Check if this control is selected for execution
        if [[ " ${selected_controls[@]} " =~ " ${control} " ]]; then
            log "Processing control: $control"
            log "Resource: $resource"
            log "Current status: $status"
            
            # Get function name from mapping
            function_name=$(yq eval ".controls.[\"$control\"].function" control_mappings.yaml)
            
            if [[ -n "$function_name" ]]; then
                # Extract appropriate ID based on resource type
                if [[ $resource == *":volume/"* ]]; then
                    resource_id=$(extract_volume_id "$resource")
                elif [[ $resource == *":snapshot/"* ]]; then
                    resource_id=$(extract_snapshot_id "$resource")
                fi
                
                if [[ -n "$resource_id" ]]; then
                    # Execute the control function
                    $function_name "$resource_id"
                    
                    # Verify fix
                    if [[ $? -eq 0 ]]; then
                        log "✅ Successfully fixed: $control for $resource_id"
                    else
                        log "❌ Failed to fix: $control for $resource_id"
                    fi
                fi
            fi
        fi
    done
}

# Main execution
main() {
    local csv_file=$1
    shift
    local selected_controls=("$@")
    
    # Source all control functions
    source_control_functions
    
    # Process CSV with selected controls
    process_csv "$csv_file" "${selected_controls[@]}"
}

# Check for required parameters
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <csv_file> <control1> [control2 ...]"
    echo "Example: $0 findings.csv 'EBS snapshots should be encrypted' 'EBS volumes should be attached to EC2 instances'"
    exit 1
fi

# Execute main function
main "$@"
