# Production Incident Scenario

Current time: 15:30.

Payment API error rate increased from 0.1% to 37%.

Timeline:

```text
15:10  payment-api v2.8.3 deployed
15:15  Kafka consumer lag starts rising
15:20  Redis memory reaches 92%
15:25  MongoDB latency rises sharply
15:28  payment-api pod restarts increase
15:30  customer payment failures reach 37%
```

You are the incident commander.

Explain what you do now.

Be prepared to discuss:

- impact assessment
- change freeze
- incident roles
- evidence collection
- rollback vs roll-forward
- customer / stakeholder communication
- verification of recovery
- post-incident actions
- SDLC controls that would reduce recurrence
