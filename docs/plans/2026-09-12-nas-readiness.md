# NAS Redis Readiness

Observed failure: NAS Redis starts around 98 seconds after the container, exceeding the old 30 x 2 second loop. Subsequent healthchecks pass. Repeated updates force-recreate the container and repeat permission preparation.

Decision: share a monotonic, 600-second Redis PONG wait across install/update/repair. Bound individual Docker calls to 5 seconds, report progress every 30 seconds, fail early for exited/dead containers, preserve real timeout errors. Allow XBOARD_REDIS_WAIT_SECONDS=1..3600 without treating a socket alone as healthy.

Pull candidate images using the existing Compose files excluding only the old image-lock override. Resolve immutable candidate IDs and write locks only after both pulls succeed. Remove --force-recreate from application updates so unchanged image/configuration can reuse containers. Still run post-update steps: a previous partial update may need completion even if its image is current.

No-backup default remains unchanged. Do not alter live NAS data, bypass ownership, kill chown, or weaken database/HTTP checks. Test 98-second simulated startup, permanently absent Redis, hanging probe, exited container, unchanged candidate IDs and failed pulls. Run real Docker/Xboard CI before delivery.
