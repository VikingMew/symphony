---
title: Deploying Symphony Behind a Reverse Proxy
genre: guide
domain: [deployment, operations]
status: current
language: en
updated: 2026-08-07
---

# Deploying Symphony Behind a Reverse Proxy

Symphony is an internal Phoenix service. Nginx, Kubernetes Ingress, or the platform edge should own public TLS, domain routing, and certificate renewal.

## Runtime Settings

Forwarded headers are ignored by default. Enable them only when Symphony is reachable through a trusted proxy boundary.

| Setting | Purpose |
| --- | --- |
| `SYMPHONY_TRUST_X_FORWARDED_HEADERS=true` | Trust `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-Port`, and `X-Forwarded-Prefix`. |
| `SYMPHONY_PUBLIC_URL=https://example.com/symphony` | Optional fixed external URL when headers are not enough. |

Health probes:

- `GET /health/live`: process is serving HTTP.
- `GET /health/ready`: web process is serving and the configured persistence layer is reachable.

Readiness reports workflow setup as `configured` or `setup_required`; setup-required does not expose secrets and does not prevent the Settings UI from loading.

## Nginx Example

```nginx
map $http_upgrade $connection_upgrade {
  default upgrade;
  '' close;
}

server {
  listen 443 ssl http2;
  server_name symphony.example.com;

  location / {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
  }
}
```

For subpath hosting, set the prefix and route the matching path:

```nginx
location /symphony/ {
  proxy_pass http://127.0.0.1:4000/;
  proxy_set_header X-Forwarded-Prefix /symphony;
  proxy_set_header X-Forwarded-Host $host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
}
```

## Kubernetes Sketch

```yaml
apiVersion: v1
kind: Service
metadata:
  name: symphony
spec:
  selector:
    app: symphony
  ports:
    - name: http
      port: 80
      targetPort: 4000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: symphony
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  rules:
    - host: symphony.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: symphony
                port:
                  number: 80
```

Pod probes:

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: 4000
readinessProbe:
  httpGet:
    path: /health/ready
    port: 4000
```

Run the container or process with:

```sh
SYMPHONY_TRUST_X_FORWARDED_HEADERS=true ./bin/symphony --port 4000
```
