# Applications

Sample microservices that give the platform realistic workloads to operate, measure and break. Each service owns its source, Dockerfile, tests and Helm values reference.

| Service | Role |
| --- | --- |
| `gateway` | Public entry point and request routing |
| `orders` | Order lifecycle and persistence |
| `payments` | Payment processing, a deliberately critical dependency |
| `notifier` | Asynchronous notifications driven by events |

The services are intentionally simple; their purpose is to produce meaningful SLIs and failure modes.
