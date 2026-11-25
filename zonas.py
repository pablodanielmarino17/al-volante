import json, io, zipfile, urllib.request, urllib.parse, os, sys

LOG = []
def log(*a):
    s = " ".join(str(x) for x in a)
    LOG.append(s)
    print("[zonas]", s)

def get(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 al-volante-build"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def ckan_resources(base, ids, query):
    res = []
    for pid in ids:
        try:
            d = json.loads(get(base + "/api/3/action/package_show?id=" + pid))
            if d.get("success"):
                res += d["result"].get("resources", [])
                log("paquete", base, pid, len(d["result"].get("resources", [])), "recursos")
        except Exception as e:
            log("falla package_show", base, pid, repr(e)[:120])
    if not res and query:
        try:
            d = json.loads(get(base + "/api/3/action/package_search?rows=5&q=" + urllib.parse.quote(query)))
            for p in d.get("result", {}).get("results", []):
                log("encontrado por busqueda", base, p.get("name"))
                res += p.get("resources", [])
        except Exception as e:
