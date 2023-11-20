# AWS Host Setup

## Orchestrator Node
- We use unbuntu 22.04 OS on a t2.micro instance.
- You need to setup a private key for your host to support SSH.
- IAM access allows the node to spin up relay nodes on the command line via `aws ec2 run-instances`
- Security group opens port 4000 to private IP from replay Nodes
- Security group opens port 4000 and SSH to administrator IPs (Your IP)
- The User Data setup script may be found under [`scripts/orchestrator-bootstrap.sh`](../scripts/orchestrator-bootstrap.sh)

## Replay Nodes
- We use unbuntu 22.04 OS on a TBD instance.
- Mount an additional 32Gb SSD EC2 Storage Instance (mounted as /data by `replay-node-bootstrap.sh`)
- You need to setup a private key for your host to support SSH.
- IAM access allows the node to access S3 bucket (example `aws s3 ls`)
- Security group opens port SSH to orchestrator node, and administrator IPs (Your IP)
- The User Data setup script may be found under [`scripts/replay-node-bootstrap.sh`](../scripts/replay-node-bootstrap.sh)