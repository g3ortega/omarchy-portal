"""Attach local Docker publish metadata to socket rows without granting ownership."""
import http.client
import ipaddress
import json
import os
import signal
import socket
import stat
import sys

MAX_RESPONSE = 1024 * 1024
DEADLINE = 0.5
SOCKET_PATHS = (f"/run/user/{os.getuid()}/docker.sock", "/run/docker.sock")


class DeadlineExpired(Exception):
    pass


def expired(signum, frame):
    raise DeadlineExpired("Docker metadata deadline")


def containers():
    # Fixed local sockets deliberately ignore Docker contexts and DOCKER_HOST.
    records = []
    remaining = MAX_RESPONSE
    for path in SOCKET_PATHS:
        try:
            info = os.stat(path, follow_symlinks=False)
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid not in (0, os.getuid()):
                continue
        except OSError:
            continue
        connection = http.client.HTTPConnection("localhost", timeout=DEADLINE)
        try:
            connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.sock.settimeout(DEADLINE)
            connection.sock.connect(path)
            connection.request("GET", "/containers/json")
            response = connection.getresponse()
            if response.status != 200:
                continue
            body = response.read(remaining + 1)
            if len(body) > remaining:
                return records
            remaining -= len(body)
            data = json.loads(body)
            if isinstance(data, list):
                records.extend(data)
        except DeadlineExpired:
            return records
        except (OSError, ValueError, RecursionError, http.client.HTTPException):
            continue
        finally:
            connection.close()
    return records


def address(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = ipaddress.ip_address(value)
        return str(parsed.ipv4_mapped or parsed) if parsed.version == 6 else str(parsed)
    except (ValueError, TypeError):
        return None


def text(value, limit):
    return value if isinstance(value, str) and 0 < len(value) <= limit and all(
        ord(char) >= 32 and ord(char) != 127 for char in value
    ) else None


def enrich(document, records):
    bindings = {}
    for identity, record in enumerate(records):
        if not isinstance(record, dict) or record.get("State") != "running":
            continue
        names = record.get("Names")
        name = text(names[0].lstrip("/"), 256) if isinstance(names, list) and names and isinstance(names[0], str) else None
        image = text(record.get("Image"), 512)
        ports = record.get("Ports")
        if not name or not image or not isinstance(ports, list):
            continue
        for mapping in ports:
            if not isinstance(mapping, dict) or mapping.get("Type") != "tcp":
                continue
            port = mapping.get("PublicPort")
            host = address(mapping.get("IP", ""))
            if type(port) is not int or not 1 <= port <= 65535 or host is None:
                continue
            bindings.setdefault(port, []).append((host, identity, name, image))
    for row in document["ports"]:
        if row["pid"] is not None and row["comm"] not in ("docker-proxy", "rootlesskit", "rootlessport", "slirp4netns"):
            continue
        candidates = set()
        hosts = {address(host) for host in row["addresses"]}
        wildcard = "*" in row["addresses"]
        for host, identity, name, image in bindings.get(row["port"], []):
            family_hosts = {item for item in hosts if item is not None and (":" in item) == (":" in host)}
            any_host = "::" if ":" in host else "0.0.0.0"
            if wildcard or host in family_hosts or (family_hosts and (host == any_host or any_host in family_hosts)):
                candidates.add((identity, name, image))
        if len(candidates) == 1:
            _, name, image = candidates.pop()
            row["container"] = {"name": name, "image": image}
            row.update(pid=None, start=None, cpuTicks=None, rssKb=None, upSec=None,
                       comm="", cwd="", projectRoot="", projectName="", procState="",
                       argv=[], cmdline="", argvTruncated=False, markers=[], deps=[],
                       exclusiveOwner=False)
    return document


def main():
    document = json.load(sys.stdin)
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, DEADLINE)
    try:
        records = containers()
    except DeadlineExpired:
        records = []
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    json.dump(enrich(document, records), sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
