# Local secrets mount

Place the Apple APNs auth key here as `AuthKey_XXXXXXXXXX.p8` for local Docker Compose.
The directory is mounted read-only at `/run/secrets/collog`; `*.p8` files are ignored by Git and the
Docker build context. Never add key contents to this README.
