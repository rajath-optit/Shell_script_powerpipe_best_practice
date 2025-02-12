This is how the script is works.
script is a Bash-based automation tool that checks compliance for various AWS EBS-related security controls. It reads a CSV file containing resource information and validates whether the listed resources comply with specific security policies.

screenshots:
./ebs_security_automation.sh ebs_findings.csv "EBS snapshots should not be publicly restorable" "EBS volumes should be protected by a backup plan"

need this all nessesary file
control_mappings.yaml  ebs_findings.csv [should contain id and control statement]

-file, in order for script to work.

error handling
![image](https://github.com/user-attachments/assets/c016e229-e0bf-4448-8aa3-b09c1ac5b27c)

after succussfull fix.
![image](https://github.com/user-attachments/assets/d22519e2-b0b6-404a-9f3e-82e73b39c6f0)
