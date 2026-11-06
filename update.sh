#!/bin/bash
# loop over every folder containing a docker-compose file
for folder in */; do
    [ -f "$folder/docker-compose.yml" ] || [ -f "$folder/docker-compose.yaml" ] || continue
    echo "=== $folder ==="
    (cd "$folder" && docker compose pull && docker compose up -d)
done
