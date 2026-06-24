Producer Lambda sends messages to SQS.

SQS decouples the producer from the consumer.

Consumer Lambda scales independently.

Failed messages are routed to a DLQ.

Benefits:
- Reliability
- Scalability
- Fault isolation
- Asynchronous processing