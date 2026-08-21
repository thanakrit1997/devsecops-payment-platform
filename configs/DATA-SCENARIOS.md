# Data Service Scenarios

## MongoDB

Production latency changes from 20 ms to 900 ms.

```text
Application CPU: 30%
MongoDB CPU:     42%
Disk I/O:        95%
Connections:     78% of configured maximum
```

Explain:

1. your first hypotheses
2. evidence you would gather
3. how you distinguish query/index problems from storage problems
4. immediate mitigation options
5. longer-term corrective actions

---

## Redis

```text
used_memory:   15GB
maxmemory:     16GB
evicted_keys:  2,300,000
hit_rate:      falling
```

Explain what may be happening and how you would investigate:

- TTL behavior
- eviction policy
- hot keys
- big keys
- cache stampede
- persistence / replication implications

---

## Kafka

Consumer lag:

```text
payment-events
partition 0: 10
partition 1: 15
partition 2: 892331
partition 3: 13
```

Answer:

1. What do you suspect first?
2. What evidence do you collect?
3. Would increasing consumers from 4 to 20 solve the problem? Why or why not?
4. What could cause one partition to behave differently from the others?
