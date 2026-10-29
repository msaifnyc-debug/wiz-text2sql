# GuardDuty: the DETECTIVE control for runtime threats. Picks up the attack
# simulation (SSH brute force against the public-SSH VM, anomalous use of the VM's
# admin role, recon against the account).
resource "aws_guardduty_detector" "main" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
  }

  tags = { Name = "${local.name}-guardduty" }
}
