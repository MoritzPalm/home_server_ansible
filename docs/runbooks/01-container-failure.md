# F1 — One container broken, or a bad update

**Symptoms:** a hostname returns 404, or an app is unreachable, while everything
else works and Traefik's log shows nothing wrong.

---

## Stop and check this first

> **Traefik silently skips unhealthy containers.** It logs no routing error —
> the router simply does not exist and the request falls through to a 404. From
> outside, an unhealthy container and a missing Traefik label are identical.
>
> This has already caused four incidents here: Tandoor (ALLOWED_HOSTS rejected
> `localhost`, so its healthcheck failed), and Overseerr, Stash and
> AudiobookRequest (healthchecks calling `curl`, which those images do not ship).

```bash
docker ps -a --filter name=<app> --format '{{.Names}}\t{{.Status}}'
docker inspect <app> --format '{{.State.Health.Status}}'
```

`unhealthy` or `starting` explains the 404 on its own. Go straight to the logs:

```bash
docker logs --tail 50 <app>
docker inspect <app> --format '{{json .State.Health}}' | python3 -m json.tool
```

The last healthcheck's output is in there and usually names the cause.

---

## Diagnose

```bash
# Is the container even running?
docker ps -a --filter name=<app>

# Does Traefik know about it?
docker exec traefik wget -qO- http://127.0.0.1:8080/metrics | grep '<app>'

# Does the app answer directly, bypassing Traefik?
docker exec <app> curl -sI http://127.0.0.1:<port>/ | head -1
```

If the app answers directly but the hostname 404s, it is Traefik-side: health,
labels, or the container not being on the `external` network.

---

## Recover

### A bad image from Renovate

```bash
cd compose_stacks
git log --oneline -5 -- <stack>/<stack>.yml     # find the digest bump
git revert <sha>                                 # or edit the digest back
git push
```

Then re-deploy. **The `docker` tag is mandatory** — the clone task is tagged
`docker`, and without it the host keeps its stale compose files while the run
reports success:

```bash
ansible-playbook playbooks/site.yml \
  --tags docker,<stack> -e compose_branch=<branch>
```

### A bad templated config

Fix the template under `roles/<role>/templates/`, then re-run that role's tag.
Ansible changes take effect from your working copy — no push needed, unlike
compose.

### A healthcheck using a binary the image lacks

Several images ship no `curl`. Check before writing one:

```bash
docker exec <app> sh -c 'command -v curl wget || echo NEITHER'
```

Use `wget --spider`, or the app's own CLI, or drop the healthcheck rather than
leave a permanently unhealthy container that Traefik refuses to route to.

### A bind-mount source that did not exist

> **Docker creates a missing bind-mount source as a directory**, and the
> container's view is then permanently wrong. This has happened twice here —
> Vikunja's `config.yml` and Immich's `config.json` both became directories, and
> the app silently fell back to defaults with OIDC disabled.

A restart does **not** fix it:

```bash
docker rm -f <app>
sudo rm -rf /srv/data/configs/<app>/<the-path-that-should-be-a-file>
ansible-playbook playbooks/site.yml --tags <stack>
```

The roles for vikunja, immich and paperless already detect and remove this case,
but only for the paths they know about.

---

## Verify

```bash
docker inspect <app> --format '{{.State.Health.Status}}'    # healthy
curl -s -o /dev/null -w '%{http_code}\n' https://<host>.moritzpalm.com
```

Expect 200 or 3xx — the public apps redirect to a login. A 404 means Traefik
still has no router for it. Uptime Kuma on the Pi should go green within a
minute.
