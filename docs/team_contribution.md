# Team Contribution Summary

This section summarizes each team member’s primary responsibilities and completed contributions for the Lottery Verification Platform on AWS.

### Contribution Percentage

| Student | Role | Contribution % |
|---|---|---:|
| Nishtha Gupta | Infrastructure and Networking Lead | 25% |
| Rozan Sonnadara | Application and Portal Lead | 25% |
| Bala Sreerangam | Database and Security Lead | 25% |
| Simran Mohapatra | Logging, Monitoring, Testing, and Documentation Lead | 25% |
| **Total** |  | **100%** |

---

## 1. Infrastructure and Networking Lead - Nishtha Gupta (UID - 122031197)

**Primary Responsibility:** Core AWS infrastructure, networking, load balancing, and service reachability.

### Contributions

- Designed and implemented the AWS VPC architecture across multiple Availability Zones.
- Created public and private subnet layout.
- Configured route tables, Internet Gateway, and NAT Gateway for private subnet outbound access.
- Containerized the Flask application services for ECS deployment.
- Implemented security groups for ALB, ECS/Fargate services, and RDS access control.
- Deployed the Application Load Balancer.
- Configured HTTPS listener and routing rules.
- Created target groups for:
  - `verification-service`
  - `claims-service`
- Validated ALB-to-ECS connectivity.
- Verified that ECS services are reachable through the ALB.
- Helped validate target group health and service availability.

---

## 2. Application and Portal Lead - Rozan Sonnadara (UID - 122359826)

**Primary Responsibility:** Lottery verification and claim registration application functionality with database design.

### Contributions

- Developed the customer service portal UI.
- Implemented authentication/login functionality.
- Built ticket verification workflow using ticket number and draw date.
- Displayed ticket status including:
  - Winning ticket
  - Losing ticket
  - Already registered ticket
  - Ticket not found
- Implemented claim registration flow for eligible winning tickets.
- Captured claimant details such as name, email, phone, and address.
- Generated claim confirmation and QR code after successful registration.
- Implemented claim search by claimant name, ticket number, or claim ID.
- Added health check endpoints for service monitoring and ALB target group validation.

---

## 3. Database and Security Lead - Bala Sreerangam (UID - 121976987)

**Primary Responsibility:** Database layer, secure storage, secrets, and platform security controls.

### Contributions

- Deployed Amazon RDS PostgreSQL as the backend database.
- Configured RDS in private subnets.
- Enabled encryption at rest for RDS.
- Stored database credentials securely in AWS Secrets Manager.
- Configured ECS task access to Secrets Manager.
- Helped enforce least-privilege access between ECS and RDS.
- Configured RDS security group to allow PostgreSQL traffic only from ECS/Fargate services.
- Added duplicate claim prevention using database constraints and application validation.
- Documented Amazon Shield Standard as DDoS protection for AWS-managed services such as ALB.
- Supported HTTPS/TLS security validation through the Application Load Balancer.


---

## 4. Logging, Monitoring, Testing, and Documentation Lead - Simran Mohapatra (UID - 121957467)

**Primary Responsibility:** Observability, logging, monitoring, testing evidence, operational documentation, and final delivery support.

### Contributions

- Added centralized application logging using CloudWatch Logs.
- Verified ECS application log groups:
  - `/ecs/verification-service`
  - `/ecs/claims-service`
- Added VPC Flow Logs for network traffic visibility.
- Added CloudTrail for AWS API activity logging.
- Configured CloudTrail log delivery to S3.
- Added ALB access logging to S3.
- Created CloudWatch dashboard: `lottery-platform-operations`.
- Added CloudWatch alarms for:
  - Verification service CPU utilization
  - Claims service CPU utilization
  - Verification service memory utilization
  - Claims service memory utilization
  - ALB 5XX errors
  - Verification unhealthy targets
  - Claims unhealthy targets
  - RDS CPU utilization
  - Login failure spike detection, when metric filters are enabled
- Added SNS alarm topic support for email notifications.
- Added optional CloudWatch log metric filters for:
  - `LOGIN_FAIL`
  - `CLAIM_REGISTERED`
  - `DUPLICATE_CLAIM_ATTEMPT`
- Created monitoring and logging documentation.
- Created evidence checklist for screenshots.
- Created known issues documentation.
- Created cost considerations documentation.
- Created runbook and troubleshooting guidance.
- Created/updated README deployment instructions.
- Prepared architecture diagram aligned with ECS Fargate, ALB, RDS, CloudWatch, CloudTrail, VPC Flow Logs, ALB logs, S3, and SNS.
- Coordinated final evidence collection for monitoring and deployment screenshots.


